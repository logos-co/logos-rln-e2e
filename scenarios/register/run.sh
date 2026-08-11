#!/usr/bin/env bash
# scenarios/register — the single-node membership lifecycle over the real
# module stack (logos_execution_zone -> liblogos_lez_rln_module ->
# liblogos_rln_module). Drives a PAID registration through the membership
# module's spec surface — the faucet-funded Register instruction, NOT the
# gifter's RegisterFree path:
#
#   open wallet -> sync -> derive fresh holding -> claim_tokens (faucet)
#   -> unlock_keystore -> register (membership module GENERATES the credential
#      in-module) -> poll get_membership_state to "active" -> select_membership
#   -> get_merkle_proof -> cross-check via liblogos_lez_rln_module.get_membership
#   -> start (warm root window) -> generate_proof -> get_epoch_quota
#   -> verify_proof (verdict valid) -> verify_proof with a tampered signal
#      (verdict invalid)
#
# Besides the registration itself this is the acceptance for two open
# architecture risks:
#   R2 — lp_* calls INTO a Rust module (membership -> rln over the raw lp
#        client). A provider_failure on every membership call while direct
#        liblogos_lez_rln_module calls succeed means the lp transport to Rust
#        modules is broken -> fall back to the generated typed client.
#   R4 — the host stamping instance_persistence_path. unlock_keystore
#        failing with kind "internal" (no persistence path) means logoscore
#        does not provide one -> the module needs an explicit override.
#
# Target-agnostic: chain, deployment, funding mode and every poll budget
# arrive through the harness contract (docs/contract.md) — the target is a
# flag, and nothing here is derived locally.
#
# Cost: one registration at rate_limit=100 burns 100 x price_per_unit, taken
# from a fresh faucet claim; the run takes as long as the target's
# confirmation budget allows.
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100   registration rate limit
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
NODE=n1

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
          E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_POLL_INTERVAL_S" -ge 1 ] 2>/dev/null || die "E2E_POLL_INTERVAL_S must be a positive integer"
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — this scenario exercises the faucet-paid Register path (no gifter); pick a faucet deployment"

# Poll count for a contract budget, floor 1.
polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODE_UP=0
DYING=0
# The daemon's reply is usually the whole story on failure.
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
say "registry: $REGISTRY_ID (tree ${E2E_TREE_ID:0:8}…, sequencer $E2E_SEQUENCER)"

# ---------- node ------------------------------------------------------------
section "node"
daemon_start "$NODE" || die "daemon_start $NODE failed"
NODE_UP=1
daemon_load_modules "$NODE" logos_execution_zone liblogos_lez_rln_module liblogos_rln_module \
    || die "load-module failed"

# ---------- wallet: open + sync ---------------------------------------------
section "wallet"
wallet_open "$NODE" || die "wallet open failed"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "syncing wallet to chain head $CHAIN_HEAD"
wallet_sync "$NODE" "$CHAIN_HEAD"

# ---------- faucet funding (Register-instruction path, no gifter) -----------
say "deriving a fresh holding account"
HOLDING=$(wallet_fresh_holding "$NODE") || HOLDING=""
[ -n "$HOLDING" ] || die "no unused holding account"
say "holding: $HOLDING"

# rate_limit x price_per_unit, doubled for slack — read the live price from
# the v1.1 bounds method rather than hardcoding the deployment's tariff.
BOUNDS=$(node_call "$NODE" liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
[ -n "$BOUNDS" ] || die "get_registry_bounds failed (rln module up?)"
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: $BOUNDS"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "claiming $CLAIM RLNTOK from the faucet (rate $RATE_LIMIT x price $PRICE x2)"
CLAIM_RES=$(node_call "$NODE" liblogos_lez_rln_module claim_tokens \
    "$(argfile cfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile hold "$HOLDING")" "$CLAIM" | jres) || CLAIM_RES=""
[ -n "$CLAIM_RES" ] || die "claim_tokens failed"
wait_balance "$NODE" "$HOLDING" "$CLAIM" || die "faucet credit never landed (want $CLAIM)"

# ---------- scope (the identity is generated INSIDE the module) --------------
# The consumer supplies only the scope (registry_id + rln_identifier) and the
# rate limit; register mints and persists the credential in-module and the
# secret never crosses the wire.
RLN_ID=$(openssl rand -hex 32)

# ---------- the registration, through the membership module -----------------
section "registration"
UNLOCK=$(node_call "$NODE" liblogos_rln_module unlock_keystore e2e-test-password | jres) || UNLOCK=""
case "$UNLOCK" in
    *'"unlocked":true'*) say "keystore unlocked" ;;
    *'no persistence path'*|*'not initialized'*)
        die "R4 CONFIRMED: host provides no instance_persistence_path — unlock said: $UNLOCK" ;;
    *) die "unlock_keystore failed: ${UNLOCK:-<empty>}" ;;
esac

OPTIONS_JSON="{\"funding_holding_account_id\":\"$HOLDING\"}"
say "register($REGISTRY_ID, rate $RATE_LIMIT) via membership module"
REG=$(node_call "$NODE" liblogos_rln_module register \
    "$REGISTRY_ID" "$(argfile rlnid "$RLN_ID")" "$RATE_LIMIT" "$OPTIONS_JSON" | jres) || REG=""
case "$REG" in
    *'"state":"pending"'*) ;;
    *'provider_failure'*)
        die "R2 CONFIRMED?: membership->rln lp transport failed. Reply: $REG — check whether direct liblogos_lez_rln_module calls above succeeded (they did if you see this), which isolates the fault to lp calls INTO a Rust module. Fallback: generated typed client." ;;
    *) die "register failed: ${REG:-<empty>}" ;;
esac
MEMBERSHIP_HASH=$(printf '%s' "$REG" | jfield membership_hash)
# The commitment is public — the module surfaces it in the Membership view (no
# secret). Used only for the sibling cross-check below.
COMMITMENT=$(printf '%s' "$REG" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("credential",{}).get("identity_commitment",""))' 2>/dev/null || true)
say "pending membership: $MEMBERSHIP_HASH (commitment ${COMMITMENT:0:16}…)"

say "polling get_membership_state to active (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
STATE=""
STATE_JSON=""
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    STATE_JSON=$(node_call "$NODE" liblogos_rln_module get_membership_state \
        "$REGISTRY_ID" "$(argfile rlnid "$RLN_ID")" | jres) || STATE_JSON=""
    STATE=$(printf '%s' "$STATE_JSON" | jfield state)
    say "  state poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed) die "registration FAILED: $(node_call "$NODE" liblogos_rln_module get_memberships "$REGISTRY_ID" | jres)" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
[ "$STATE" = "active" ] || [ "$STATE" = "grace_period" ] \
    || die "membership never became active (last state: ${STATE:-<none>})"
LEAF=$(printf '%s' "$STATE_JSON" | jfield leaf_index)
say "ACTIVE at leaf $LEAF"

# ---------- post-registration surface ----------------------------------------
# select_membership returns the PUBLIC view only (the secret never leaves the
# module); assert the membership_hash rather than a released credential.
SELECTED=$(node_call "$NODE" liblogos_rln_module select_membership \
    "$REGISTRY_ID" "$(argfile rlnid "$RLN_ID")" "" | jres) || SELECTED=""
case "$SELECTED" in
    *"$MEMBERSHIP_HASH"*) say "select_membership returned the public membership" ;;
    *) die "select_membership did not return the membership: ${SELECTED:-<empty>}" ;;
esac

PROOF=$(node_call "$NODE" liblogos_rln_module get_merkle_proof "$REGISTRY_ID" "$LEAF" | jres) || PROOF=""
case "$PROOF" in
    *'"valid_roots"'*) say "get_merkle_proof returned a rooted proof" ;;
    *) die "get_merkle_proof failed: ${PROOF:-<empty>}" ;;
esac

CROSS=$(node_call "$NODE" liblogos_lez_rln_module get_membership \
    "$(argfile cfg3 "$E2E_CONFIG_ACCOUNT")" "$(argfile commit2 "$COMMITMENT")" | jres) || CROSS=""
case "$CROSS" in
    *'"registered":true'*) say "cross-check: rln module sees the membership ($(printf '%s' "$CROSS" | jfield state))" ;;
    *) die "cross-check get_membership failed: ${CROSS:-<empty>}" ;;
esac

# ---------- rate-limit proofs (the spec's rate-limiting portion) --------------
# start() warms the registry's valid-root window; generate_proof spends a
# message_id slot and proves in-module (the secret never crosses the wire);
# verify_proof serves from the local window only — it is expected to answer
# not_ready until the warm-up read lands, so poll that away first.
section "rate-limit proofs"
say "start(registries=[$REGISTRY_ID]) to warm the root window"
# epoch_size: verify_proof binds proofs to the current epoch (±1), and the
# window warm-up polling below can span tens of seconds — a 1s default epoch
# would expire the proof before verification. The target sizes it to its own
# confirmation speed.
START=$(node_call "$NODE" liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || START=""
case "$START" in
    *'"started":true'*) ;;
    *) die "start failed: ${START:-<empty>}" ;;
esac

SIGNAL_HEX=$(printf 'logos e2e signal' | to_hex)
say "generate_proof over the registered membership"
# timestamp: the consumer's Unix-seconds clock — the module derives the proof's
# epoch from it (not its own clock). `date +%s` == now, so the epoch lands in
# the start()'d window.
# str: forces a literal string — a bare or @file numeric arg is coerced to a
# JSON number by the CLI, which the tstr dispatch then reads as "".
PROOF_JSON=$(node_call "$NODE" liblogos_rln_module generate_proof \
    "$REGISTRY_ID" "$(argfile rlnid2 "$RLN_ID")" "$(argfile sig "$SIGNAL_HEX")" "str:$(date +%s)" | jres | jval) || PROOF_JSON=""
case "$PROOF_JSON" in
    *'"proof"'*'"nullifier"'*|*'"nullifier"'*'"proof"'*) ;;
    *) die "generate_proof failed: ${PROOF_JSON:-<empty>}" ;;
esac
MESSAGE_ID=$(printf '%s' "$PROOF_JSON" | jfield message_id)
say "proof issued (message_id ${MESSAGE_ID:-?}, epoch $(printf '%s' "$PROOF_JSON" | jfield epoch))"

# The quota snapshot (logos-delivery's QuotaProvider shape): numeric
# epoch_index + rate_limit + remaining, decremented by the proof above —
# asserted strictly only when the epoch didn't roll in between.
QUOTA=$(node_call "$NODE" liblogos_rln_module get_epoch_quota \
    "$REGISTRY_ID" "$(argfile rlnid5 "$RLN_ID")" | jres | jval) || QUOTA=""
case "$QUOTA" in
    *'"epoch_index"'*'"remaining"'*) ;;
    *) die "get_epoch_quota failed: ${QUOTA:-<empty>}" ;;
esac
REMAINING=$(printf '%s' "$QUOTA" | jfield remaining)
Q_EPOCH=$(printf '%s' "$QUOTA" | jfield epoch_index)
PROOF_EPOCH=$(printf '%s' "$PROOF_JSON" | jfield epoch)
if [ "$Q_EPOCH" = "$PROOF_EPOCH" ]; then
    [ "$REMAINING" = "$((RATE_LIMIT - 1))" ] \
        || die "quota remaining $REMAINING != $((RATE_LIMIT - 1)) after one proof"
    say "epoch quota: remaining $REMAINING/$RATE_LIMIT in epoch $Q_EPOCH"
else
    say "epoch rolled between proof and quota (proof $PROOF_EPOCH, quota $Q_EPOCH) — remaining $REMAINING"
fi

say "verify_proof from the local root window (polling not_ready away)…"
VALID=""
for _t in $(seq 1 "$(polls "$E2E_ROOT_WINDOW_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    VERIFY=$(node_call "$NODE" liblogos_rln_module verify_proof \
        "$REGISTRY_ID" "$(argfile rlnid3 "$RLN_ID")" "$(argfile sig2 "$SIGNAL_HEX")" \
        "$(argfile proof "$PROOF_JSON")" | jres | jval) || VERIFY=""
    case "$VERIFY" in
        *'"verdict":"valid"'*)   VALID=yes; break ;;
        *'"verdict":"invalid"'*) die "verify_proof rejected our own fresh proof: $VERIFY" ;;
        *'not_ready'*)     say "  root window still cold ($_t)"; sleep "$E2E_POLL_INTERVAL_S" ;;
        *) die "verify_proof failed: ${VERIFY:-<empty>}" ;;
    esac
done
[ "$VALID" = "yes" ] || die "verify_proof never left not_ready (root window warm-up)"
say "verify_proof: valid"

# A different signal against the same proof MUST be invalid — not an error.
TAMPER_HEX=$(printf 'tampered signal' | to_hex)
TVERIFY=$(node_call "$NODE" liblogos_rln_module verify_proof \
    "$REGISTRY_ID" "$(argfile rlnid4 "$RLN_ID")" "$(argfile sig3 "$TAMPER_HEX")" \
    "$(argfile proof2 "$PROOF_JSON")" | jres | jval) || TVERIFY=""
case "$TVERIFY" in
    *'"verdict":"invalid"'*) say "tampered signal correctly invalid" ;;
    *) die "tampered signal was not rejected: ${TVERIFY:-<empty>}" ;;
esac

echo
echo "e2e: PASS — registered on $REGISTRY_ID"
echo "e2e:   membership_hash $MEMBERSHIP_HASH"
echo "e2e:   leaf_index      $LEAF"
echo "e2e:   funded by       $HOLDING (faucet claim, no gifter)"
