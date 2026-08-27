#!/usr/bin/env bash
# scenarios/consumer-gifter — delegated registration end-to-end:
#
#   n1 (gifter): RLN stack + libp2p_module + rln_gifter_module, a
#      faucet-funded holding, `rln_gifter_module.serve` with NO authVerifiers
#      (open gifter). The gifter needs funds but NO membership of its own.
#   n2 (client): RLN stack + libp2p + gifter(client half) + nim_rln_consumer,
#      NO funds — its wallet is a separate read-only copy of the seed, used
#      only for chain reads. registerMembership carries
#      {"delegated":"true","gifter_peer_id":…,"gifter_multiaddr":…}: the
#      client's rln module mints the credential, hands the commitment to the
#      co-located gifter client, which dials the gifter over libp2p; the
#      GIFTER pays and submits register_member; the client polls to active
#      and runs the proof round-trip.
#
# What this acceptance-tests beyond consumer-register: the delegated
# register options wire, the gifter protobuf protocol over libp2p's generic
# bridge, and that a consumer with zero funds can become a prover.
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100              registration rate limit
#   E2E_CONSUMER_OP_TIMEOUT_S=10    the consumer's per-op seam timeout
#                                   (delivery's hard rlnInvoke budget)
#   E2E_GIFTER_PORT=61871           the gifter's libp2p listen port
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
OP_TIMEOUT="${E2E_CONSUMER_OP_TIMEOUT_S:-10}"
GIFTER_PORT="${E2E_GIFTER_PORT:-61871}"
CONTENT_TOPIC="/logos-rln-e2e/1/consumer-gifter/proto"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
          E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_FUNDING" = "faucet" ] || die "the gifter funds itself from the faucet; pick a faucet deployment"

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODES_UP=""
DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ -n "$NODES_UP" ]; then
        DYING=1
        local n
        for n in $NODES_UP; do
            echo "---- node log tail ($n) ----" >&2
            node_logs "$n" 30 >&2 || true
        done
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving nodes up, state in $E2E_RUN_DIR"
        return
    fi
    daemon_stop_all
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

# ---------- n1: the gifter --------------------------------------------------
section "gifter node (n1)"
# The module default is full-lazy self-owned keystore custody; this
# scenario exercises MANUAL passwords — opt its daemons out.
export E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} LOGOS_RLN_DISABLE_AUTO_UNLOCK=1"
daemon_start n1 || die "daemon_start n1 failed"
NODES_UP="n1"
daemon_load_modules n1 lez_core liblogos_lez_rln_module liblogos_rln_module \
    libp2p_module rln_gifter_module || die "n1 load-module failed"

wallet_open n1 || die "n1 wallet open failed"
say "syncing gifter wallet"
wallet_sync n1 >/dev/null || die "n1 wallet sync failed"

GHOLD=$(wallet_fresh_holding n1) || GHOLD=""
[ -n "$GHOLD" ] || die "no unused holding account for the gifter"
BOUNDS=$(node_call n1 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile gcfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: ${BOUNDS:-<empty>}"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "gifter claiming $CLAIM RLNTOK into $GHOLD"
node_call n1 liblogos_lez_rln_module claim_tokens \
    "$(argfile gcfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile ghold "$GHOLD")" "$CLAIM" | jres >/dev/null \
    || die "gifter claim_tokens failed"
wait_balance n1 "$GHOLD" "$CLAIM" >/dev/null || die "gifter faucet credit never landed"

say "gifter libp2p node on 127.0.0.1:$GIFTER_PORT"
node_call n1 libp2p_module createNode "{\"addrs\":[\"/ip4/127.0.0.1/tcp/$GIFTER_PORT\"]}" | jres >/dev/null \
    || die "n1 libp2p createNode failed"
node_call n1 libp2p_module start | jres >/dev/null || die "n1 libp2p start failed"
PEERINFO=$(node_call n1 libp2p_module peerInfo | jres | jval) || PEERINFO=""
GPEER=$(printf '%s' "$PEERINFO" | jfield peerId)
[ -n "$GPEER" ] || die "no peerId in peerInfo: ${PEERINFO:-<empty>}"
GADDR="/ip4/127.0.0.1/tcp/$GIFTER_PORT"
say "gifter peer: $GPEER @ $GADDR"

# Open gifter: NO authVerifiers — any commitment gets a membership, paid by
# the gifter's wallet. NOTE: a Rust module's string param takes a bare JSON
# object from the CLI (the register scenario's options precedent); an
# @argfile object arrives brace-stripped.
SERVE=$(node_call n1 rln_gifter_module serve \
    "{\"config\":\"$E2E_CONFIG_ACCOUNT\",\"wallet\":\"$GHOLD\"}" | jres) || SERVE=""
case "$SERVE" in
    *error*) die "gifter serve failed: $SERVE" ;;
    '') die "gifter serve failed: <empty>" ;;
    *) say "gifter serving (open): $SERVE" ;;
esac

# ---------- n2: the fundless client -----------------------------------------
section "client node (n2)"
# A separate wallet-home COPY for the client: chain reads only, never funded,
# never shared with n1's mutable storage.json (truncate-in-place writes).
N2_HOME="$E2E_RUN_DIR/wallet-home-n2"
mkdir -p "$N2_HOME"
cp "$E2E_WALLET_HOME/wallet_config.json" "$N2_HOME/"
cp "$E2E_WALLET_HOME/storage.json.seed" "$N2_HOME/storage.json.seed"

daemon_start n2 || die "daemon_start n2 failed"
NODES_UP="n1 n2"
daemon_load_modules n2 lez_core liblogos_lez_rln_module liblogos_rln_module \
    libp2p_module rln_gifter_module nim_rln_consumer || die "n2 load-module failed"

wallet_open n2 "$N2_HOME" || die "n2 wallet open failed"
say "syncing client wallet (read-only use)"
wallet_sync n2 >/dev/null || die "n2 wallet sync failed"

# The client's libp2p node (the gifter client dials out through it).
node_call n2 libp2p_module createNode '{"addrs":["/ip4/127.0.0.1/tcp/0"]}' | jres >/dev/null \
    || die "n2 libp2p createNode failed"
node_call n2 libp2p_module start | jres >/dev/null || die "n2 libp2p start failed"

UNLOCK=$(node_call n2 liblogos_rln_module unlock_keystore e2e-test-password | jres) || UNLOCK=""
case "$UNLOCK" in
    *'"unlocked":true'*) say "client keystore unlocked" ;;
    *) die "n2 unlock_keystore failed: ${UNLOCK:-<empty>}" ;;
esac

RLN_ID=$(openssl rand -hex 32)
node_watch_start n2 nim_rln_consumer
CONSUMER_CFG=$(printf '{"registryId":"%s","rlnIdentifierHex":"%s","epochSizeSec":"%s","opTimeoutSec":"%s","pollIntervalSec":"%s","confirmBudgetSec":"%s"}' \
    "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC" "$OP_TIMEOUT" \
    "$E2E_POLL_INTERVAL_S" "$E2E_CONFIRM_TIMEOUT_S")
node_call n2 nim_rln_consumer createConsumer "$(argfile ccfg "$CONSUMER_CFG")" | jres | grep -q '"success":true' \
    || die "n2 createConsumer failed"
node_call n2 nim_rln_consumer subscribeEvents | jres | grep -q '"success":true' \
    || die "n2 subscribeEvents failed"
node_call n2 nim_rln_consumer startRln | jres | jval | grep -q '"started":true' \
    || die "n2 startRln failed"

# ---------- delegated registration (the gifter pays) -------------------------
section "delegated registration"
OPTIONS_JSON=$(printf '{"delegated":"true","gifter_peer_id":"%s","gifter_multiaddr":"%s"}' \
    "$GPEER" "$GADDR")
say "registerMembership(delegated, rate $RATE_LIMIT) via the open gifter"
REG=$(node_call n2 nim_rln_consumer registerMembership \
    "str:$RATE_LIMIT" "$(argfile opts "$OPTIONS_JSON")" | jres | jval) || REG=""
case "$REG" in
    *'"state":"pending"'*) say "pending (submitted through the gifter)" ;;
    *) die "delegated registerMembership failed: ${REG:-<empty>}" ;;
esac

STATE=""
STATE_JSON=""
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    STATE_JSON=$(node_call n2 nim_rln_consumer getMembershipState | jres | jval) || STATE_JSON=""
    STATE=$(printf '%s' "$STATE_JSON" | jfield state)
    say "  state poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed) die "delegated registration FAILED: $STATE_JSON" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
[ "$STATE" = "active" ] || [ "$STATE" = "grace_period" ] \
    || die "membership never became active (last: ${STATE:-<none>})"
LEAF=$(printf '%s' "$STATE_JSON" | jfield leaf_index)
say "ACTIVE at leaf $LEAF — paid by the gifter"

node_wait_event n2 nim_rln_consumer membership_state_changed 30 '"active"' \
    || die "membership_state_changed(active) never re-emitted"

# ---------- proofs on the fundless client ------------------------------------
section "proofs"
TS=$(date +%s)
PAYLOAD_HEX=$(printf 'gifted client payload' | to_hex)
GEN=$(node_call n2 nim_rln_consumer generateMessageProof \
    "$(argfile ph "$PAYLOAD_HEX")" "$CONTENT_TOPIC" "str:$TS" | jres | jval) || GEN=""
SIGNAL_HEX=$(printf '%s' "$GEN" | jfield signal_hex)
PROOF_JSON=$(printf '%s' "$GEN" | python3 -c \
    'import json,sys; print(json.dumps(json.load(sys.stdin)["proof"], separators=(",",":")))' 2>/dev/null) \
    || die "generateMessageProof failed: ${GEN:-<empty>}"

VALID=""
for _t in $(seq 1 "$(polls "$E2E_ROOT_WINDOW_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    VERIFY=$(node_call n2 nim_rln_consumer validateMessageProof \
        "$(argfile sig "$SIGNAL_HEX")" "str:$TS" "$(argfile proof "$PROOF_JSON")" | jres | jval) || VERIFY=""
    case "$VERIFY" in
        *'"verdict":"valid"'*) VALID=yes; break ;;
        # See consumer-register: a warm-but-stale root window answers
        # "invalid" until the post-registration refresh (~10s) lands.
        *'"verdict":"invalid"'*) say "  invalid — root window likely one refresh behind ($_t)"; sleep "$E2E_POLL_INTERVAL_S" ;;
        *'not_ready'*) say "  root window still cold ($_t)"; sleep "$E2E_POLL_INTERVAL_S" ;;
        *) die "validateMessageProof failed: ${VERIFY:-<empty>}" ;;
    esac
done
[ "$VALID" = "yes" ] || die "validateMessageProof never returned valid (last: ${VERIFY:-<empty>})"

echo
echo "e2e: PASS — fundless client registered via the open gifter and proved"
echo "e2e:   leaf_index $LEAF, gifter $GPEER paid from $GHOLD"
