#!/usr/bin/env bash
# scenarios/consumer-register — the register lifecycle driven through
# nim_rln_consumer, the Nim mock of logos-delivery. Every RLN operation
# crosses the full delivery sandwich (harness -> C++ plugin -> nim-ffi ->
# Nim RlnConsumer -> mirrored delivery seam -> lp wire ->
# liblogos_rln_module); chain funding and the keystore unlock stay direct
# module calls — they are harness domain, delivery never owned them.
#
#   open wallet -> sync -> fresh holding -> claim_tokens (faucet, direct)
#   -> unlock_keystore (direct) -> createConsumer -> startRln
#   -> registerMembership (ASYNC BY DESIGN: returns "pending" fast)
#   -> poll getMembershipState to "active"
#   -> assert the re-emitted membership_state_changed event
#   -> generateMessageProof (delivery-shaped signal) -> getEpochQuota
#   -> validateMessageProof (valid) -> tampered payload (invalid)
#   -> identical re-validate (duplicate — the module's nullifier log)
#
# The async-registration contract this acceptance-tests: no single consumer
# call blocks for the chain's confirmation latency. The registerMembership
# reply is the module's immediate view; activation arrives via polling and
# the event. The default op timeout IS logos-delivery's hard 10s rlnInvoke
# budget, so every leg proves it fits delivery's real constraint; raise it
# for slow targets (testnet reads can exceed 10s cold).
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100            registration rate limit
#   E2E_CONSUMER_OP_TIMEOUT_S=10  the consumer's per-op seam timeout
#                                 (delivery parity; set 30 for testnet)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
OP_TIMEOUT="${E2E_CONSUMER_OP_TIMEOUT_S:-10}"
NODE=n1
CONTENT_TOPIC="/logos-rln-e2e/1/consumer/proto"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
          E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_POLL_INTERVAL_S" -ge 1 ] 2>/dev/null || die "E2E_POLL_INTERVAL_S must be a positive integer"
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — this scenario exercises the faucet-paid direct path; pick a faucet deployment"

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODE_UP=0
DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ "$NODE_UP" = 1 ]; then
        DYING=1
        echo "---- node log tail ----" >&2
        node_logs "$NODE" 40 >&2 || true
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving node $NODE up, state in $E2E_RUN_DIR"
        return
    fi
    [ "$NODE_UP" = 1 ] && daemon_stop "$NODE"
}
trap cleanup EXIT

CONFIG_HEX=$(python3 - "$E2E_CONFIG_ACCOUNT" <<'EOF'
import sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + A.index(c)
print(n.to_bytes(32, "big").hex())
EOF
) || die "cannot decode config account '$E2E_CONFIG_ACCOUNT'"
REGISTRY_ID="logos:${E2E_TARGET}:$CONFIG_HEX"
say "registry: $REGISTRY_ID (consumer op timeout ${OP_TIMEOUT}s)"

# ---------- node ------------------------------------------------------------
section "node"
daemon_start "$NODE" || die "daemon_start $NODE failed"
NODE_UP=1
daemon_load_modules "$NODE" lez_core liblogos_lez_rln_module liblogos_rln_module \
    nim_rln_consumer || die "load-module failed"

# ---------- wallet + faucet funding (direct module calls: harness domain) ----
section "wallet"
wallet_open "$NODE" || die "wallet open failed"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "syncing wallet to chain head $CHAIN_HEAD"
wallet_sync "$NODE" >/dev/null || die "wallet sync failed"

HOLDING=$(wallet_fresh_holding "$NODE") || HOLDING=""
[ -n "$HOLDING" ] || die "no unused holding account"
say "holding: $HOLDING"

BOUNDS=$(node_call "$NODE" liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
[ -n "$BOUNDS" ] || die "get_registry_bounds failed (rln module up?)"
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: $BOUNDS"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "claiming $CLAIM RLNTOK from the faucet"
CLAIM_RES=$(node_call "$NODE" liblogos_lez_rln_module claim_tokens \
    "$(argfile cfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile hold "$HOLDING")" "$CLAIM" | jres) || CLAIM_RES=""
[ -n "$CLAIM_RES" ] || die "claim_tokens failed"
wait_balance "$NODE" "$HOLDING" "$CLAIM" >/dev/null || die "faucet credit never landed (want $CLAIM)"

UNLOCK=$(node_call "$NODE" liblogos_rln_module unlock_keystore e2e-test-password | jres) || UNLOCK=""
case "$UNLOCK" in
    *'"unlocked":true'*) say "keystore unlocked" ;;
    *) die "unlock_keystore failed: ${UNLOCK:-<empty>}" ;;
esac

# ---------- the consumer ------------------------------------------------------
section "consumer"
RLN_ID=$(openssl rand -hex 32)
node_watch_start "$NODE" nim_rln_consumer   # before the triggering calls

CONSUMER_CFG=$(printf '{"registryId":"%s","rlnIdentifierHex":"%s","epochSizeSec":"%s","opTimeoutSec":"%s","pollIntervalSec":"%s","confirmBudgetSec":"%s"}' \
    "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC" "$OP_TIMEOUT" \
    "$E2E_POLL_INTERVAL_S" "$E2E_CONFIRM_TIMEOUT_S")
OUT=$(node_call "$NODE" nim_rln_consumer createConsumer "$(argfile ccfg "$CONSUMER_CFG")" | jres) || OUT=""
case "$OUT" in
    *'"success":true'*) say "consumer created for the scope" ;;
    *) die "createConsumer failed: ${OUT:-<empty>}" ;;
esac

# Subscribe BEFORE the registration so the pending->active transition can't
# be missed (explicit method: the subscription acquisition needs the RLN
# module loaded — see nim-rln-consumer/README.md).
SUB=$(node_call "$NODE" nim_rln_consumer subscribeEvents | jres) || SUB=""
case "$SUB" in
    *'"success":true'*) say "membership_state_changed subscription up" ;;
    *) die "subscribeEvents failed: ${SUB:-<empty>}" ;;
esac

START_ENV=$(node_call "$NODE" nim_rln_consumer startRln | jres) || START_ENV=""
START=$(printf '%s' "$START_ENV" | jval)
case "$START" in
    *'"started":true'*) say "startRln OK (module epoch $E2E_EPOCH_SIZE_SEC, root window warming)" ;;
    *) die "startRln failed: ${START:-<empty>} (envelope: ${START_ENV:-<none>})" ;;
esac

# ---------- registration through the consumer (async by design) ---------------
section "registration"
OPTIONS_JSON="{\"funding_holding_account_id\":\"$HOLDING\"}"
say "registerMembership(rate $RATE_LIMIT) — expecting a FAST pending reply"
REG_T0=$(date +%s)
REG_ENV=$(node_call "$NODE" nim_rln_consumer registerMembership \
    "str:$RATE_LIMIT" "$(argfile opts "$OPTIONS_JSON")" | jres) || REG_ENV=""
REG_T1=$(date +%s)
REG=$(printf '%s' "${REG_ENV:-}" | jval)
case "$REG" in
    *'"state":"pending"'*) say "pending reply in $((REG_T1 - REG_T0))s (async contract holds)" ;;
    *) die "registerMembership failed: ${REG:-<empty>} (envelope: ${REG_ENV:-<none>})" ;;
esac
MEMBERSHIP_HASH=$(printf '%s' "$REG" | jfield membership_hash)

say "polling getMembershipState to active (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
STATE=""
STATE_JSON=""
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    STATE_JSON=$(node_call "$NODE" nim_rln_consumer getMembershipState | jres | jval) || STATE_JSON=""
    STATE=$(printf '%s' "$STATE_JSON" | jfield state)
    say "  state poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed) die "registration FAILED: $STATE_JSON" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
[ "$STATE" = "active" ] || [ "$STATE" = "grace_period" ] \
    || die "membership never became active (last state: ${STATE:-<none>})"
LEAF=$(printf '%s' "$STATE_JSON" | jfield leaf_index)
say "ACTIVE at leaf $LEAF"

# The event plumbing: module poller -> lp event -> plugin re-emit -> watch.
node_wait_event "$NODE" nim_rln_consumer membership_state_changed 30 '"active"' \
    || die "membership_state_changed(active) never re-emitted by the consumer"
say "membership_state_changed(active) observed through the consumer"

# ---------- proofs through the consumer ---------------------------------------
section "proofs"
PAYLOAD_HEX=$(printf 'consumer e2e payload' | to_hex)
TS=$(date +%s)
GEN=$(node_call "$NODE" nim_rln_consumer generateMessageProof \
    "$(argfile ph "$PAYLOAD_HEX")" "$CONTENT_TOPIC" "str:$TS" | jres | jval) || GEN=""
case "$GEN" in
    *'"signal_hex"'*'"proof"'*|*'"proof"'*'"signal_hex"'*) ;;
    *) die "generateMessageProof failed: ${GEN:-<empty>}" ;;
esac
SIGNAL_HEX=$(printf '%s' "$GEN" | jfield signal_hex)
PROOF_JSON=$(printf '%s' "$GEN" | python3 -c \
    'import json,sys; print(json.dumps(json.load(sys.stdin)["proof"], separators=(",",":")))') \
    || die "cannot extract proof from: $GEN"
say "proof issued (epoch $(printf '%s' "$PROOF_JSON" | jfield epoch_index))"

QUOTA=$(node_call "$NODE" nim_rln_consumer getEpochQuota "str:$TS" | jres | jval) || QUOTA=""
case "$QUOTA" in
    *'"epoch_index"'*'"remaining"'*) ;;
    *) die "getEpochQuota failed: ${QUOTA:-<empty>}" ;;
esac
REMAINING=$(printf '%s' "$QUOTA" | jfield remaining)
Q_EPOCH=$(printf '%s' "$QUOTA" | jfield epoch_index)
PROOF_EPOCH=$(printf '%s' "$PROOF_JSON" | jfield epoch_index)
if [ "$Q_EPOCH" = "$PROOF_EPOCH" ]; then
    [ "$REMAINING" = "$((RATE_LIMIT - 1))" ] \
        || die "quota remaining $REMAINING != $((RATE_LIMIT - 1)) after one proof"
    say "epoch quota: remaining $REMAINING/$RATE_LIMIT in epoch $Q_EPOCH"
else
    say "epoch rolled between proof and quota (proof $PROOF_EPOCH, quota $Q_EPOCH) — remaining $REMAINING"
fi

say "validateMessageProof (polling not_ready away while the root window warms)…"
VALID=""
for _t in $(seq 1 "$(polls "$E2E_ROOT_WINDOW_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    VERIFY=$(node_call "$NODE" nim_rln_consumer validateMessageProof \
        "$(argfile sig "$SIGNAL_HEX")" "str:$TS" "$(argfile proof "$PROOF_JSON")" | jres | jval) || VERIFY=""
    case "$VERIFY" in
        *'"verdict":"valid"'*)   VALID=yes; break ;;
        # A proof generated right after activation can be one root-refresh
        # (~10s) ahead of the validator's window: warm-but-stale windows
        # answer "invalid", not not_ready. Real consumer-facing behavior —
        # retry within the window budget. (The tampered check below still
        # expects invalid immediately, once a valid verdict proved freshness.)
        *'"verdict":"invalid"'*) say "  invalid — root window likely one refresh behind ($_t)"; sleep "$E2E_POLL_INTERVAL_S" ;;
        *'not_ready'*)           say "  root window still cold ($_t)"; sleep "$E2E_POLL_INTERVAL_S" ;;
        *) die "validateMessageProof failed: ${VERIFY:-<empty>}" ;;
    esac
done
[ "$VALID" = "yes" ] || die "validateMessageProof never returned valid (last: ${VERIFY:-<empty>})"
say "validateMessageProof: valid"

# A tampered payload produces a different signal — must be invalid, not an error.
TAMPER_SIGNAL=$(python3 - "$SIGNAL_HEX" <<'EOF'
import sys
s = bytearray.fromhex(sys.argv[1])
s[0] ^= 0xFF
print(s.hex())
EOF
)
TVERIFY=$(node_call "$NODE" nim_rln_consumer validateMessageProof \
    "$(argfile sig2 "$TAMPER_SIGNAL")" "str:$TS" "$(argfile proof2 "$PROOF_JSON")" | jres | jval) || TVERIFY=""
case "$TVERIFY" in
    *'"verdict":"invalid"'*) say "tampered signal correctly invalid" ;;
    *) die "tampered signal was not rejected: ${TVERIFY:-<empty>}" ;;
esac

# The identical proof again — the module's nullifier log calls retransmission.
DVERIFY=$(node_call "$NODE" nim_rln_consumer validateMessageProof \
    "$(argfile sig3 "$SIGNAL_HEX")" "str:$TS" "$(argfile proof3 "$PROOF_JSON")" | jres | jval) || DVERIFY=""
case "$DVERIFY" in
    *'"verdict":"duplicate"'*) say "identical re-validate correctly duplicate" ;;
    *) die "duplicate detection failed: ${DVERIFY:-<empty>}" ;;
esac

echo
echo "e2e: PASS — registered and proved on $REGISTRY_ID through nim_rln_consumer"
echo "e2e:   membership_hash $MEMBERSHIP_HASH"
echo "e2e:   leaf_index      $LEAF"
echo "e2e:   register reply  $((REG_T1 - REG_T0))s (async contract)"
