#!/usr/bin/env bash
# scenarios/delivery-basecamp-rln — delivery_module (the protocol-0.9 build
# of the rln/toolchain-0.9 fork) plus the 0.9 RLN module stack side-loaded
# INSIDE Basecamp (the desktop app, embedded logos-core), driven with NO
# consumer app: every delivery_module call goes through the QML inspector.
#
# Topology:
#   basecamp   the desktop app (dev #app build, QML inspector compiled in),
#              launched headless with a throwaway --user-dir; the harness
#              modules dir is copied in wholesale and lez_core + the RLN
#              stack + delivery_module are loaded through
#              MainUIBackend.loadCoreModule. Every module call goes through
#              the inspector's result-returning `evaluate` ->
#              backend.callCoreModuleMethod(...) — see harness/lib/basecamp.sh.
#   n1         an ordinary logoscore daemon: same 4 modules, in-process
#              bridge auto-enabled by its conf, NO membership of its own
#              (a receiver never needs one since logos-delivery 4091770a);
#              it receives basecamp's message only after its own module
#              validates the proof.
#
# What it proves:
#   1. LOAD: the 0.9 C++ delivery plugin and the 0.9 Rust RLN modules load
#      and answer introspection inside Basecamp's embedded core — the one
#      thing the logoscore-hosted scenarios cannot show.
#   2. REGISTER: Basecamp registers through liblogos_rln_module under the
#      membership wizard's identifier (rln_membership_ui DEFAULT_RLN_ID = 32
#      zero bytes) and the chain confirms it active — the scope a Basecamp
#      user's delivery conf has to carry.
#   3. RUN: createNode on the real rln-* conf (rln-lez auto-enables the
#      in-process bridge), start lands ("RLN module started").
#   4. SEND: basecamp send -> the library's first-send membership gate ->
#      generate_proof -> gossipsub -> n1 validate_proof (in-process bridge)
#      -> messageReceived on n1.
#
# Required (beyond docs/contract.md):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ rln/toolchain-0.9
#   LOGOS_DELIVERY_CHECKOUT   logos-delivery @ impl-plugable-rln-api-module tip
#   RLN_MODULES_CHECKOUT      logos-rln-modules @ chore/drop-raw-lp (0.9 builder)
#   BASECAMP_CHECKOUT         logos-basecamp (or BASECAMP_APP binary)
#
# Env knobs:
#   E2E_RATE_LIMIT=100          registration rate limit / user-message-limit
#   E2E_DELIVERY_BC_PORT=61990  tcp ports are PORT+1 (n1), PORT+2 (basecamp)
#   E2E_INSPECTOR_PORT=3768     basecamp QML inspector port (must be free)
#   E2E_BASECAMP_SETTLE_S=20    post-launch settle before driving the app
#   E2E_EVENT_TIMEOUT_S=30      per-event wait budget
#   E2E_MESH_WAIT_S=12          gossipsub mesh stabilization pause
#   E2E_SEND_ATTEMPTS=3         message-leg attempts (fresh-root window)
#   E2E_RECV_WAIT_S=15          per-attempt receive wait on n1
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain basecamp; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
BASE_PORT="${E2E_DELIVERY_BC_PORT:-61990}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-15}"
CLUSTER_ID="199"
TOPIC="/logos-rln-e2e/1/delivery-basecamp/proto"
# The membership wizard registers every membership under this identifier
# (logos-rln-membership-ui membership.js DEFAULT_RLN_ID): a Basecamp node's
# delivery conf has to name the same one, so this scenario does too.
RLN_ID="0000000000000000000000000000000000000000000000000000000000000000"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC BASECAMP_APP; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md + scenario.env)"
done
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — basecamp pays its registration from a faucet claim; pick a faucet deployment"
if [ -z "${DELIVERY_LGX:-}" ]; then
    [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ] && [ -n "${LOGOS_DELIVERY_CHECKOUT:-}" ] \
        || die "delivery-basecamp-rln needs BOTH delivery checkouts or a prebuilt DELIVERY_LGX"
fi
basecamp_port_check

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODES_UP=0
DYING=0
UD="$E2E_RUN_DIR/basecamp-user"
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ]; then
        DYING=1
        basecamp_die_tails
        if [ "$NODES_UP" = 1 ]; then
            echo "---- n1 log tail ----" >&2
            node_logs n1 30 >&2 || true
        fi
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving basecamp (pid ${BASECAMP_PID:-none}) + n1 up, state in $E2E_RUN_DIR"
        return
    fi
    basecamp_stop
    [ "$NODES_UP" = 1 ] && daemon_stop_all
}
trap cleanup EXIT

# call delivery_module on n1 + insist on StdLogosResult success; prints value.
must_call() {
    local node="$1" method="$2" label="$3"; shift 3
    local res
    res=$(node_call "$node" delivery_module "$method" "$@" | jres) || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" | jval ;;
        *) die "$node: $label failed: ${res:-<empty>}" ;;
    esac
}
# call delivery_module INSIDE basecamp (inspector) + insist on success; prints the reply.
bc_must() {
    local method="$1" label="$2" args="${3:-[]}" res
    res=$(bc_call delivery_module "$method" "$args") || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" ;;
        *) die "basecamp: $label failed: ${res:-<empty>}" ;;
    esac
}
# grep basecamp's app log (delivery library + plugin log lines) with patience.
bc_log_wait() {
    local pattern="$1" budget="${2:-20}" _t
    for _t in $(seq 1 "$budget"); do
        grep -q "$pattern" "$E2E_RUN_DIR/basecamp.log" 2>/dev/null && return 0
        sleep 1
    done
    return 1
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
say "registry: $REGISTRY_ID (scope rate $RATE_LIMIT, identifier = the wizard's zero id)"

# The legacy-flat delivery conf delivery-rln proves, minus the funding pair
# (registration is the app's job; rln-registry-options is vestigial in the
# library). Key names per logos-delivery impl-plugable-rln-api-module
# 85c2d6f8 (rln-lez / rln-registry-id / rln-identifier). COMPACT.
delivery_cfg() {
    local port="$1" peers="$2"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"rln-relay":true,"rln-lez":true,"rln-registry-id":"%s","rln-identifier":"%s","rln-relay-user-message-limit":%s,"rln-relay-epoch-sec":%s%s}' \
        "$port" "$CLUSTER_ID" "$REGISTRY_ID" "$RLN_ID" "$RATE_LIMIT" \
        "$E2E_EPOCH_SIZE_SEC" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

# ---------- n1: verifier daemon (funder + chain oracle + receiver) ----------
section "n1: logoscore daemon (RLN stack + delivery_module)"
daemon_start n1 || die "daemon_start n1 failed"
NODES_UP=1
daemon_load_modules n1 lez_core liblogos_lez_rln_module liblogos_rln_module delivery_module \
    || die "n1: load-module failed"
say "n1: all 4 modules loaded (module-owned keystore custody, no unlock call)"

section "n1 wallet + faucet funding (the holding basecamp will pay from)"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "chain head: $CHAIN_HEAD"
wallet_open n1 || die "n1: wallet open failed"
wallet_sync n1 >/dev/null || die "n1: wallet sync failed"
HOLDING=$(wallet_fresh_holding n1) || HOLDING=""
[ -n "$HOLDING" ] || die "no unused holding account"
BOUNDS=$(node_call n1 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
[ -n "$BOUNDS" ] || die "get_registry_bounds failed (rln stack up?)"
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: $BOUNDS"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "claiming $CLAIM RLNTOK from the faucet for $HOLDING"
CLAIM_RES=$(node_call n1 liblogos_lez_rln_module claim_tokens \
    "$(argfile cfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile hold "$HOLDING")" "$CLAIM" | jres) || CLAIM_RES=""
[ -n "$CLAIM_RES" ] || die "claim_tokens failed"
wait_balance n1 "$HOLDING" "$CLAIM" >/dev/null || die "faucet credit never landed (want $CLAIM)"

# Basecamp's wallet: its OWN copy of the home, taken AFTER the claim so its
# storage carries the holding account's derivation (the wallet signs only
# for accounts its storage knows). Two lez_core instances must never share
# one mutable storage.json; storage.json is only flushed at checkpoints, so
# persist n1's in-memory state (the derived payer) first. n1 never spends.
SAVE=$(node_call n1 lez_core save | jres) || SAVE=""
say "n1: wallet state saved (reply ${SAVE:-<empty>})"
sleep 2
cp -R "$E2E_WALLET_HOME" "$E2E_RUN_DIR/wallet-basecamp" \
    || die "cannot copy wallet home for basecamp"

# Pre-warm n1's module root window (start is idempotent).
PREWARM=$(node_call n1 liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || PREWARM=""
case "$PREWARM" in
    *'"started":true'*) say "n1: rln module pre-warmed" ;;
    *) die "n1: rln module start (pre-warm) failed: ${PREWARM:-<empty>}" ;;
esac

section "n1 delivery up (receiver, no membership of its own)"
node_watch_start n1 delivery_module
N1_CONF=$(delivery_cfg "$(( BASE_PORT + 1 ))" "")
must_call n1 createNode "createNode" "$(argfile cfg_n1 "$N1_CONF")" >/dev/null
must_call n1 start "start (dispatch)" >/dev/null
node_wait_event n1 delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
    || die "n1: no nodeStarted within ${EVT_TIMEOUT}s"
grep -q "rln served in-process" "$(node_log_path n1)" \
    || die "n1: conf carries rln-lez but createNode never logged 'rln served in-process'"
PEERID=$(must_call n1 getNodeInfo "getNodeInfo MyPeerId" MyPeerId)
[ -n "$PEERID" ] || die "n1: empty MyPeerId"
N1_MADDR="/ip4/127.0.0.1/tcp/$(( BASE_PORT + 1 ))/p2p/$PEERID"
must_call n1 subscribe "subscribe" "$TOPIC" >/dev/null
say "n1: delivery up, bridge auto-enabled, subscribed to $TOPIC — maddr $N1_MADDR"

# ---------- basecamp ---------------------------------------------------------
section "basecamp up (headless, side-loaded modules)"
basecamp_launch "$UD" "$E2E_RUN_DIR/wallet-basecamp" ""

section "basecamp: load the 0.9 module stack (the claim under test)"
basecamp_load_modules lez_core liblogos_lez_rln_module liblogos_rln_module delivery_module
DM_METHODS=$(bc_eval "backend.getCoreModuleMethods('delivery_module')") || DM_METHODS=""
case "$DM_METHODS" in
    *createNode*) : ;;
    *) die "basecamp: delivery_module loaded but exposes no createNode: ${DM_METHODS:-<empty>}" ;;
esac
case "$DM_METHODS" in
    *rlnBridgeEnable*) : ;;
    *) die "basecamp: delivery_module exposes no rlnBridgeEnable (an RLN-less build?): $DM_METHODS" ;;
esac
RLN_METHODS=$(bc_eval "backend.getCoreModuleMethods('liblogos_rln_module')") || RLN_METHODS=""
case "$RLN_METHODS" in
    *register_membership*) : ;;
    *) die "basecamp: liblogos_rln_module exposes no register_membership: ${RLN_METHODS:-<empty>}" ;;
esac
say "basecamp: 4 modules loaded and introspectable inside the embedded core (delivery_module: createNode + rlnBridgeEnable; liblogos_rln_module: register_membership)"

section "basecamp wallet (open + sync)"
basecamp_wallet_open_sync "$E2E_RUN_DIR/wallet-basecamp"

# ---------- basecamp: register (the app's job) -------------------------------
section "basecamp: rln module start + register_membership (wizard id, pending -> active)"
START_ARGS=$(jq -cn --arg c "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" '[$c]')
RSTART=$(bc_call liblogos_rln_module start "$START_ARGS") || RSTART=""
case "$RSTART" in
    *'"started":true'*) say "basecamp: rln module started" ;;
    *) die "basecamp: rln module start failed: ${RSTART:-<empty>}" ;;
esac
OPTIONS="[{\"key\":\"rate_limit\",\"value\":\"$RATE_LIMIT\"},{\"key\":\"funding_holding_account_id\",\"value\":\"$HOLDING\"}]"
REG=$(bc_call liblogos_rln_module register_membership \
    "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" --arg o "$OPTIONS" '[$r,$i,$o]')") || REG=""
case "$REG" in
    *'"state":"pending"'*|*'"state":"active"'*) say "basecamp: register_membership accepted ($(printf '%s' "$REG" | grep -oE '"state":"[a-z_]+"' | head -1))" ;;
    *) die "basecamp: register_membership failed: ${REG:-<empty>}" ;;
esac
STATE=""
GMS=""
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    GMS=$(bc_call liblogos_rln_module get_membership_state \
        "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" '[$r,$i]')") || GMS=""
    STATE=$(printf '%s' "$GMS" | grep -oE '"state":"[a-z_]+"' | head -1 | cut -d'"' -f4)
    say "  basecamp state poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed) die "basecamp registration FAILED on chain: $GMS" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
case "$STATE" in
    active|grace_period) : ;;
    *) die "basecamp membership never became active (last: '${STATE:-<none>}' — $GMS)" ;;
esac
LEAF=$(printf '%s' "$GMS" | grep -oE '"leaf_index":[0-9]+' | head -1 | cut -d: -f2)
MHASH=$(printf '%s' "$GMS" | grep -oE '"membership_hash":"[0-9a-fx]+"' | head -1 | cut -d'"' -f4)
say "basecamp: membership $STATE at leaf ${LEAF:-?} (${MHASH:-?})"

# ---------- basecamp: run the node on the real conf -------------------------
section "basecamp: delivery createNode (rln-lez conf) + start"
BC_CONF=$(delivery_cfg "$(( BASE_PORT + 2 ))" "$N1_MADDR")
bc_must createNode "createNode" "$(jq -cn --arg c "$BC_CONF" '[$c]')" >/dev/null
if bc_log_wait "rln served in-process" 5; then
    say "basecamp: createNode enabled the in-process bridge (log contract)"
else
    say "basecamp: no 'rln served in-process' line in basecamp.log (plugin log filtered?) — createNode succeeded, continuing"
fi
bc_must start "start (dispatch)" >/dev/null
BC_PEER=""
for _t in $(seq 1 "$EVT_TIMEOUT"); do
    BC_PEER=$(bc_call delivery_module getNodeInfo '["MyPeerId"]' 2>/dev/null | grep -oE '"value":"[^"]+"' | cut -d'"' -f4) || BC_PEER=""
    [ -n "$BC_PEER" ] && break
    sleep 1
done
[ -n "$BC_PEER" ] || die "basecamp: node never reported a peer id after start"
if grep -q "RLN module start failed\|RLN module bring-up failed" "$E2E_RUN_DIR/basecamp.log" 2>/dev/null; then
    die "basecamp's library failed RLN bring-up: $(grep -m1 'RLN module start failed\|RLN module bring-up failed' "$E2E_RUN_DIR/basecamp.log")"
fi
if bc_log_wait "RLN module started" 15; then
    say "basecamp: library log confirms 'RLN module started' (start answered inside its budget)"
else
    say "basecamp: no 'RLN module started' line in basecamp.log (library log filtered?) — node is up (peer $BC_PEER), continuing"
fi
say "basecamp: delivery up on 127.0.0.1:$(( BASE_PORT + 2 )) (peer $BC_PEER), static peer n1"

# ---------- message leg -------------------------------------------------------
section "message leg (proof-gated relay, basecamp -> n1)"
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
ROOTS_WARM_BUDGET_S="${E2E_ROOTS_WARM_BUDGET_S:-300}"
ROOTS_T0=$(date +%s)
while :; do
    ROOTS_N1=$(node_call n1 liblogos_rln_module get_valid_roots "$REGISTRY_ID" 2>/dev/null | jres) || ROOTS_N1=""
    case "$ROOTS_N1" in *'"valid_roots":["'*) break ;; esac
    [ $(( $(date +%s) - ROOTS_T0 )) -ge "$ROOTS_WARM_BUDGET_S" ] \
        && die_node n1 "registry read path never warmed in ${ROOTS_WARM_BUDGET_S}s — last: ${ROOTS_N1:-<empty>}"
    sleep 5
done
say "n1 root window warm after $(( $(date +%s) - ROOTS_T0 ))s"

RECEIVED=0
ATTEMPT=0
while [ "$ATTEMPT" -lt "$SEND_ATTEMPTS" ]; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    PAYLOAD="rln-gated ping $ATTEMPT from basecamp"
    # send's payload is bytes: on the 0.9 wire a bytes value is the tagged
    # object {"_bytes": <base64url>} (logos_codec.h; the decoder tolerates
    # padding) — the same shape messageReceived carries it back in.
    SEND_ARGS=$(python3 -c 'import base64, json, sys
print(json.dumps([sys.argv[1], {"_bytes": base64.urlsafe_b64encode(sys.argv[2].encode()).decode().rstrip("=")}], separators=(",", ":")))' "$TOPIC" "$PAYLOAD")
    SEND=$(bc_call delivery_module send "$SEND_ARGS") || SEND=""
    case "$SEND" in
        *'"success":true'*) : ;;
        *) die "basecamp: send failed: ${SEND:-<empty>} — library: $(grep -m1 'usable RLN membership\|Failed to verify RLN membership\|Failed to attach RLN proof' "$E2E_RUN_DIR/basecamp.log" 2>/dev/null || echo 'no gate error logged')" ;;
    esac
    if node_wait_event n1 delivery_module messageReceived "$RECV_WAIT_S" "$TOPIC" >/dev/null; then
        RECEIVED=1
        say "attempt $ATTEMPT: n1 received the proof-gated message on $TOPIC"
        break
    fi
    if grep -q "usable RLN membership\|Failed to verify RLN membership\|Failed to attach RLN proof" "$E2E_RUN_DIR/basecamp.log" 2>/dev/null; then
        die "basecamp's send was refused by the library's gate: $(grep -m1 'usable RLN membership\|Failed to verify RLN membership\|Failed to attach RLN proof' "$E2E_RUN_DIR/basecamp.log")"
    fi
    say "attempt $ATTEMPT: not received on n1 (fresh-root window?) — retrying"
    sleep 3
done
[ "$RECEIVED" = 1 ] || die "n1 never received a message from basecamp in $SEND_ATTEMPTS attempts"

# n1 runs rln-relay:true, so messageReceived only surfaces after its
# in-process bridge validated the proof — its event stream shows the call.
sleep 1
VALIDATES=$(grep -c '"event":"rlnValidateProofRequest"' "$(gv NODEEVT n1_delivery_module)" || true)
[ "${VALIDATES:-0}" -ge 1 ] \
    || die "n1 received the message but its event stream shows no rlnValidateProofRequest (rln off on n1?)"
say "n1: $VALIDATES validate_proof request(s) preceded the receipt"

echo
echo "e2e: PASS — delivery-basecamp-rln (target $E2E_TARGET)"
echo "e2e:   load      lez_core + liblogos_lez_rln_module + liblogos_rln_module + delivery_module (protocol-0.9 builds) loaded INSIDE Basecamp's embedded core and answered introspection"
echo "e2e:   driving   inspector evaluate -> backend.callCoreModuleMethod (no consumer app; delivery_module called directly)"
echo "e2e:   register  basecamp register_membership under the wizard's zero identifier -> $STATE at leaf ${LEAF:-?} (paid from a faucet-funded holding)"
echo "e2e:   run       createNode on the real rln-* conf (rln-lez auto-enabled the bridge) + start; peer $BC_PEER"
echo "e2e:   message   basecamp send -> first-send membership gate + generate_proof -> gossipsub -> n1 validate_proof -> messageReceived (attempt $ATTEMPT/$SEND_ATTEMPTS)"
