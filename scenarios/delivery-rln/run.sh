#!/usr/bin/env bash
# scenarios/delivery-rln — acceptance for the delivery team's RLN seam
# (branch impl-plugable-rln-api-module on BOTH logos-delivery and
# logos-delivery-module) against the REAL RLN module stack.
#
# The seam under test is event-out/respond-in: liblogosdelivery's rlnInvoke
# fires a C callback into delivery_module, which re-emits it as an
# rln*Request logos event; whoever handles it answers via
# delivery_module.rlnRespond(reqId, resultJson). delivery_module never calls
# the RLN module itself — THIS SCRIPT is the responder, bridging each
# request to liblogos_rln_module and feeding the real reply back. (Because
# start() is dispatch-and-return, the single-concurrency module can serve
# rlnRespond while the library's start_node awaits — no concurrency:multi
# needed for this design, unlike an in-module lp bridge.)
#
# What it proves:
#   1. co-residency: the RLN stack + the RLN-enabled delivery_module load in
#      one daemon (delivery bundles zerokit-v2 librln, the RLN module pins
#      zerokit v3 — a symbol/library collision would show here).
#   2. the start chain: start() -> rlnStartRequest -> rlnRespond ->
#      rlnRegisterRequest -> rlnRespond -> nodeStarted, with each response
#      inside the library's hard 10s rlnInvoke window (the log-line
#      assertion distinguishes real completions from timeout fallbacks).
#   3. the bring-up payload crosses with REAL values: the fork commit makes
#      the library's placeholder scope env-configurable
#      (LOGOS_DELIVERY_RLN_REGISTRY_ID/_IDENTIFIER/_OPTIONS, injected via
#      E2E_DAEMON_ENV), and the rlnRegisterRequest fields are asserted
#      against what we configured.
#   4. the registration is REAL: the membership the responder registers on
#      delivery's behalf goes pending -> active on the target chain.
#
# Deliberately NOT here: answering get_membership_state / generate_proof /
# verify_proof — the library never issues them yet (only start +
# register_membership are wired on the branch). When the branch grows those
# calls, extend the responder with the consumer bridge's op->method mapping
# (nim-rln-consumer/src/rln_seam_bridge.cpp), incl. verify_proof ->
# validate_proof.
#
# Required checkouts (the fork branches have no flake pins):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ impl-plugable-rln-api-module
#                             (or its rln-acceptance fork branch)
#   LOGOS_DELIVERY_CHECKOUT   logos-delivery @ rln-acceptance — the fork
#                             branch with env-configurable bring-up;
#                             submodules checked out
#   RLN_MODULES_CHECKOUT      logos-rln-modules with the 0.6.0 stack (until
#                             the e2e flake pin bumps)
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100            registration rate limit (also becomes the
#                                 library's bring-up options value)
#   E2E_DELIVERY_RLN_PORT=61880   delivery node tcp port
#   E2E_EVENT_TIMEOUT_S=30        per-event wait budget
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
PORT="${E2E_DELIVERY_RLN_PORT:-61880}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
NODE=n1

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
          E2E_EPOCH_SIZE_SEC; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — the responder pays the registration from a faucet claim; pick a faucet deployment"
# Without the delivery override this runs against pinned delivery master,
# which has no RLN seam — fail with the pointer instead of a confusing hang.
[ -n "${DELIVERY_LGX:-}" ] || [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ] \
    || die "delivery-rln needs the impl branch: set DELIVERY_MODULE_CHECKOUT (+ LOGOS_DELIVERY_CHECKOUT for the env-configurable bring-up fork) or a prebuilt DELIVERY_LGX"

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

# call delivery_module + insist on StdLogosResult success; prints the value.
must_call() {
    local method="$1" label="$2"; shift 2
    local res
    res=$(node_call "$NODE" delivery_module "$method" "$@" | jres) || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" | jval ;;
        *) die "$label failed: ${res:-<empty>}" ;;
    esac
}

# arg<N> of a compact event JSON line.
evt_arg() {
    printf '%s' "$1" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["data"].get("arg"+sys.argv[1],""))' "$2"
}

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
RLN_ID=$(openssl rand -hex 32)
say "registry: $REGISTRY_ID (delivery bring-up scope, rate $RATE_LIMIT)"

# ---------- node (bring-up scope injected into the daemon env) ---------------
# daemon_start scrubs the environment (env -i); E2E_DAEMON_ENV is the pass-
# through. Values must be space-free — registry id, hex id and the compact
# options JSON all are.
section "node"
BRINGUP_OPTS="[{\"key\":\"rate_limit\",\"value\":\"$RATE_LIMIT\"}]"
export E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} LOGOS_DELIVERY_RLN_REGISTRY_ID=$REGISTRY_ID LOGOS_DELIVERY_RLN_IDENTIFIER=$RLN_ID LOGOS_DELIVERY_RLN_OPTIONS=$BRINGUP_OPTS"
daemon_start "$NODE" || die "daemon_start $NODE failed"
NODE_UP=1
daemon_load_modules "$NODE" lez_core liblogos_lez_rln_module liblogos_rln_module \
    delivery_module || die "load-module failed"
say "co-residency: RLN stack + RLN-enabled delivery_module loaded"

# ---------- wallet + keystore (the responder pays; delivery stays fundless) --
section "wallet"
wallet_open "$NODE" || die "wallet open failed"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "syncing wallet to chain head $CHAIN_HEAD"
wallet_sync "$NODE" >/dev/null || die "wallet sync failed"
HOLDING=$(wallet_fresh_holding "$NODE") || HOLDING=""
[ -n "$HOLDING" ] || die "no unused holding account"
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

# Pre-warm the module's root window: the responder's in-band start call must
# answer inside the library's 10s rlnInvoke budget, and a cold start's
# registry read can eat most of that on a slow target. start is idempotent.
PREWARM=$(node_call "$NODE" liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || PREWARM=""
case "$PREWARM" in
    *'"started":true'*) say "rln module pre-warmed" ;;
    *) die "rln module start (pre-warm) failed: ${PREWARM:-<empty>}" ;;
esac

# ---------- delivery node up: the RLN start chain ----------------------------
section "delivery start chain (harness = RLN responder)"
node_watch_start "$NODE" delivery_module

# Their integration suite's proven RLN shape (kRlnConfig) + pinned loopback
# port. rln-relay-* are the signal that rlnRelayConf.isSome() — the values
# are dead weight (the external module is the only RLN path on the branch).
CFG="{\"logLevel\":\"INFO\",\"mode\":\"Edge\",\"relay\":true,\"numShardsInNetwork\":8,\"listenAddress\":\"127.0.0.1\",\"tcpPort\":$PORT,\"rln-relay\":true,\"rln-relay-dynamic\":false,\"rln-relay-chain-id\":1,\"rln-relay-eth-contract-address\":\"0x0000000000000000000000000000000000000000\"}"
must_call createNode "createNode" "$(argfile cfg_rln "$CFG")" >/dev/null
must_call start "start (dispatch)" >/dev/null
say "start dispatched — waiting for the library's RLN requests"

# Leg 1: start. The event carries (reqId, timestamp); the responder answers
# with the real module's start reply, wrapped in the reply envelope every
# responder must speak (delivery-module docs/rln.md): {"ok": <result>} |
# {"err":{"kind","message"}}. The library doesn't parse it yet — wrapping now
# keeps this acceptance ahead of the contract, not behind it.
EVT=$(node_wait_event "$NODE" delivery_module rlnStartRequest "$EVT_TIMEOUT") \
    || die "no rlnStartRequest within ${EVT_TIMEOUT}s (callbacks not registered, or rlnRelayConf not set)"
REQ_ID=$(evt_arg "$EVT" 0)
[ -n "$REQ_ID" ] || die "rlnStartRequest carried no reqId: $EVT"
START_RES=$(node_call "$NODE" liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || START_RES=""
case "$START_RES" in
    *'"started":true'*) ;;
    *) die "module start failed while answering rlnStartRequest: ${START_RES:-<empty>}" ;;
esac
must_call rlnRespond "rlnRespond(start, reqId $REQ_ID)" "$REQ_ID" \
    "$(argfile rsp_start "{\"ok\":$START_RES}")" >/dev/null
say "leg 1: start answered (reqId $REQ_ID)"

# Leg 2: register_membership. Assert the payload IS the configured scope
# (this is what the LD fork's env plumbing exists to prove), then register
# for real — the responder supplies the funding the seam has no field for.
EVT2=$(node_wait_event "$NODE" delivery_module rlnRegisterRequest "$EVT_TIMEOUT") \
    || die "no rlnRegisterRequest within ${EVT_TIMEOUT}s after the start response"
REQ_ID2=$(evt_arg "$EVT2" 0)
EV_REGISTRY=$(evt_arg "$EVT2" 1)
EV_RLNID=$(evt_arg "$EVT2" 2)
EV_OPTS=$(evt_arg "$EVT2" 3)
[ "$EV_REGISTRY" = "$REGISTRY_ID" ] \
    || die "rlnRegisterRequest registry mismatch: event '$EV_REGISTRY' != configured '$REGISTRY_ID' (env plumbing broken?) — $EVT2"
[ "$EV_RLNID" = "$RLN_ID" ] \
    || die "rlnRegisterRequest rln_identifier mismatch: event '$EV_RLNID' != configured '$RLN_ID' — $EVT2"
EV_RATE=$(printf '%s' "$EV_OPTS" | python3 -c '
import json, sys
kv = {o.get("key"): o.get("value") for o in json.load(sys.stdin) if isinstance(o, dict)}
print(kv.get("rate_limit", ""))' 2>/dev/null) || EV_RATE=""
[ "$EV_RATE" = "$RATE_LIMIT" ] \
    || die "rlnRegisterRequest rate_limit mismatch: options carried '$EV_RATE', want '$RATE_LIMIT' — options: $EV_OPTS"
say "leg 2: register request carries the configured scope (reqId $REQ_ID2)"

# The event's LIP RegistryOptions array IS the module wire (0.6.0) — the
# responder passes it through verbatim, appending only the funding pair the
# seam has no field for.
REG_OPTS=$(printf '%s' "$EV_OPTS" | python3 -c '
import json, sys
opts = json.load(sys.stdin)
opts.append({"key": "funding_holding_account_id", "value": sys.argv[1]})
print(json.dumps(opts, separators=(",", ":")))' "$HOLDING") \
    || die "cannot build register options from the event options: $EV_OPTS"
REG=$(node_call "$NODE" liblogos_rln_module register \
    "$EV_REGISTRY" "$(argfile rlnid "$EV_RLNID")" "$REG_OPTS" | jres) || REG=""
case "$REG" in
    *'"state":"pending"'*) ;;
    *) die "module register failed while answering rlnRegisterRequest: ${REG:-<empty>}" ;;
esac
MEMBERSHIP_HASH=$(printf '%s' "$REG" | jfield membership_hash)
# Same envelope contract as leg 1: ok wraps the module's pending membership.
must_call rlnRespond "rlnRespond(register, reqId $REQ_ID2)" "$REQ_ID2" \
    "$(argfile rsp_reg "{\"ok\":$REG}")" >/dev/null
say "leg 2: register answered — pending membership $MEMBERSHIP_HASH"

# The chain completes: nodeStarted only fires after start_node's future
# resolves, i.e. after both RLN legs.
node_wait_event "$NODE" delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
    || die "no nodeStarted within ${EVT_TIMEOUT}s after both RLN responses"
say "nodeStarted — the delivery node is up with the RLN chain behind it"

# Timeouts also resolve the library's awaits (best-effort bring-up), so
# nodeStarted alone doesn't prove the responses LANDED — the library's own
# log lines do.
REG_LOGGED=0
for _t in $(seq 1 15); do
    if node_logs "$NODE" | grep -q "RLN register_membership failed\|RLN module start failed"; then
        die "the library saw an RLN leg fail (10s rlnInvoke timeout?): $(node_logs "$NODE" | grep -m2 'RLN .* failed')"
    fi
    if node_logs "$NODE" | grep -q "RLN membership registered"; then
        REG_LOGGED=1
        break
    fi
    sleep 1
done
[ "$REG_LOGGED" = 1 ] || die "library never logged 'RLN membership registered' — responses may have raced the 10s window"
say "library log confirms: RLN module started + membership registered (inside the 10s windows)"

# ---------- the registration is real: pending -> active on chain -------------
section "confirmation (real chain)"
say "polling get_membership_state to active (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
STATE=""
STATE_JSON=""
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    STATE_JSON=$(node_call "$NODE" liblogos_rln_module get_membership_state \
        "$REGISTRY_ID" "$(argfile rlnid2 "$RLN_ID")" | jres) || STATE_JSON=""
    STATE=$(printf '%s' "$STATE_JSON" | jfield state)
    say "  state poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed) die "registration FAILED on chain: $STATE_JSON" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
[ "$STATE" = "active" ] || [ "$STATE" = "grace_period" ] \
    || die "membership never became active (last state: ${STATE:-<none>})"
LEAF=$(printf '%s' "$STATE_JSON" | jfield leaf_index)

echo
echo "e2e: PASS — delivery-rln (target $E2E_TARGET)"
echo "e2e:   seam      rlnStartRequest/rlnRegisterRequest -> rlnRespond (harness responder)"
echo "e2e:   scope     $REGISTRY_ID rate $RATE_LIMIT (env-configured bring-up)"
echo "e2e:   chain     start -> register(pending $MEMBERSHIP_HASH) -> nodeStarted -> ACTIVE at leaf $LEAF"
echo "e2e:   library   'RLN module started' + 'RLN membership registered' logged (no 10s timeout fallback)"
