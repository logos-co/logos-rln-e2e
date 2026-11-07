#!/usr/bin/env bash
# scenarios/delivery-two-registries-selfstart — the delivery module in front
# of one liblogos_rln_module serving TWO registries at two epochs, with the
# module owning the backend: Relay RLN on the delivery tree D (600 s) and
# native Mix RLN on the mix tree M (10 s, the LIP LOGOS-MIXNET profile), both
# named by the preset and started by delivery in ONE start().
#
# The sibling scenarios/delivery-two-registries drives the host-owned shape
# (`manage-backend: false`, the harness starts the backend). This one drives
# what logos-delivery-module 0.3.4 adds:
#
#   presets: D / relay scope / 600 s / rate 100, plus mix-registry-id M,
#            mix-rate-limit 20, mix-metadata-topic (manage-backend default)
#   -> createNode with `"mix": true` and NO mix-rln-* keys: the module writes
#      mix-rln-registry-id / -identifier-hex / -metadata-topic from the preset,
#      starts the backend as {600, rate 100, [D, {M, 10, 3, rate 20}]} and
#      reports Ready naming D and M (rlnState.mixRegistryId); it asked for the
#      start itself (rlnStartRequest)
#   -> the module registers a membership on BOTH registries from one payer,
#      each at its registry's rate, and each goes active
#   -> delivery start succeeds (the Mix plugin accepted M at 10 s)
#   -> a Relay message n1 -> n2 is proof-gated on D and delivered
#   -> n1's module reports a usable membership on both scopes; D's quota was
#      spent by the sends
#   -> n3, whose preset puts M at 600 s (mix-epoch-size-sec), has its backend
#      started that way by delivery and fails delivery start on the Mix
#      profile mismatch: the preset's mix epoch is what reaches the backend
#
# Env beyond docs/contract.md: as scenarios/delivery-two-registries
#   E2E_DELIVERY_EPOCH_SIZE_SEC=600  E2E_MIX_EPOCH_SIZE_SEC=10  E2E_MIX_MAX_EPOCH_GAP=3
#   E2E_RATE_LIMIT=100  E2E_MIX_RATE_LIMIT=20  E2E_DELIVERY_RLN_PORT=61890
#   E2E_EVENT_TIMEOUT_S=30  E2E_MESH_WAIT_S=12  E2E_SEND_ATTEMPTS=3  E2E_RECV_WAIT_S=12
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain registry delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
M_RATE_LIMIT="${E2E_MIX_RATE_LIMIT:-20}"
D_EPOCH="${E2E_DELIVERY_EPOCH_SIZE_SEC:-600}"
M_EPOCH="${E2E_MIX_EPOCH_SIZE_SEC:-10}"
M_GAP="${E2E_MIX_MAX_EPOCH_GAP:-3}"
BASE_PORT="${E2E_DELIVERY_RLN_PORT:-61890}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-12}"
TOPIC="/logos-rln-e2e/1/delivery-two-registries-selfstart/proto"
META_TOPIC="/mix/1/metadata/proto"
CLUSTER_ID="198"
NODES_ALL="n1 n2 n3"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_PAYER E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
          E2E_REGISTRIES; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
case " $E2E_REGISTRIES " in
    *" mix "*) ;;
    *) die "the target provisioned no 'mix' registry (E2E_REGISTRIES=$E2E_REGISTRIES)" ;;
esac

NODES_UP=0
DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ "$NODES_UP" = 1 ]; then
        DYING=1
        local n
        for n in $NODES_ALL; do
            echo "---- $n log tail ----" >&2
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
    [ "$NODES_UP" = 1 ] && daemon_stop_all
}
trap cleanup EXIT

# ---------- the two registries -----------------------------------------------
D=$(delivery_registry_id default) || die "no default registry id"
M=$(delivery_registry_id mix) || die "no mix registry id"
[ "$D" != "$M" ] || die "the two registries resolve to one id: $D"
MIX_ID=6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000
RELAY_ID=$(delivery_rln_identifier)
say "D (delivery, ${D_EPOCH}s): $D"
say "M (mix, ${M_EPOCH}s/gap $M_GAP): $M"

# ---------- daemons -----------------------------------------------------------
section "daemons"
# The preset names both registries and leaves manage-backend at its default:
# delivery starts the backend itself, D at the preset's epoch and rate, M at
# the Mix profile's epoch and its own rate.
PRESETS_N12="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$PRESETS_N12" "$D" "$RELAY_ID" "$D_EPOCH" "" \
    "\"rate-limit\": $RATE_LIMIT, \"mix-registry-id\": \"$M\", \"mix-rate-limit\": $M_RATE_LIMIT, \"mix-metadata-topic\": \"$META_TOPIC\""
# The control's preset puts M at the instance default epoch.
PRESETS_N3="$E2E_RUN_DIR/rln-presets-control.json"
delivery_stage_rln_presets "$PRESETS_N3" "$D" "$RELAY_ID" "$D_EPOCH" "" \
    "\"rate-limit\": $RATE_LIMIT, \"mix-registry-id\": \"$M\", \"mix-rate-limit\": $M_RATE_LIMIT, \"mix-metadata-topic\": \"$META_TOPIC\", \"mix-epoch-size-sec\": $D_EPOCH"
DAEMON_ENV_BASE="${E2E_DAEMON_ENV:-}"
for n in $NODES_ALL; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
done
for n in n1 n2; do
    E2E_DAEMON_ENV="$DAEMON_ENV_BASE $(delivery_rln_presets_env "$PRESETS_N12")"
    export E2E_DAEMON_ENV
    daemon_start "$n" || die "daemon_start $n failed"
    daemon_load_modules "$n" liblogos_lez_rln_module liblogos_rln_module delivery_module \
        || die "$n: load-module failed"
done
E2E_DAEMON_ENV="$DAEMON_ENV_BASE $(delivery_rln_presets_env "$PRESETS_N3")"
export E2E_DAEMON_ENV
daemon_start n3 || die "daemon_start n3 failed"
daemon_load_modules n3 liblogos_lez_rln_module liblogos_rln_module delivery_module \
    || die "n3: load-module failed"
NODES_UP=1

section "wallets"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "syncing wallets to chain head $CHAIN_HEAD"
for n in n1 n2; do
    wallet_open "$n" || die "$n: wallet open failed"
    wallet_sync "$n" >/dev/null || die "$n: wallet sync failed"
    wallet_fund "$n" >/dev/null || die_node "$n" "funding its payer failed"
    say "$n: payer $(wallet_payer "$n") holds $(wallet_native_balance "$n") native (two registrations ahead)"
done
# The control registers nothing (unfunded: its provisioning waits for funds
# that never come); its wallet only serves the registry reads.
wallet_open n3 || die "n3: wallet open failed"
wallet_sync n3 >/dev/null || die "n3: wallet sync failed"

# Usage: rln_on <node> <method> [args…]  -> the value of a liblogos_rln_module call
rln_on() { local n="$1"; shift; node_call "$n" liblogos_rln_module "$@" | jres | jval; }
# Usage: delivery_rln_state <node> -> the rlnState value (JSON object)
delivery_rln_state() { node_call "$1" delivery_module rlnState | jres | jval; }

# ---------- delivery nodes: the module starts the backend for both ----------
section "delivery nodes (createNode starts the backend: D and M, two epochs)"
# Usage: mix_conf <tcp_port> [static_peer_maddr]
# The flat Relay conf plus `mix: true` and nothing else about mix: the
# registry, scope and metadata topic are the preset's and the module supplies
# them.
mix_conf() {
    local port="$1" peers="${2:-}"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"ip-colocation-limit":0,"mix":true,"maxPureLibp2pPeers":100%s}' \
        "$port" "$CLUSTER_ID" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}
for n in $NODES_ALL; do
    node_watch_start "$n" delivery_module
done
# Usage: node_started_verdict <node>  -> "ok" or the failure the library reported
node_started_verdict() {
    grep -E '"event":"nodeStarted"' "$(gv NODEEVT "${1}_delivery_module")" | tail -1 | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}").get("data", {})
print("ok" if d.get("arg0") is True else (d.get("arg1") or "nodeStarted carried no reason"))'
}
# Usage: assert_backend_shape <node> <mix-epoch>
# After createNode: nothing but delivery's own start() has touched this
# node's backend, so M reporting the preset's mix epoch (and D the relay
# epoch) is the proof that one start named both registries; rlnState names
# both too.
assert_backend_shape() {
    local n="$1" want_m_epoch="$2" state params
    state=$(delivery_rln_state "$n") || die "$n: rlnState failed"
    [ "$(printf '%s' "$state" | jfield mixRegistryId)" = "$M" ] \
        || die "$n: rlnState does not name M as the mix registry: $state"
    [ "$(printf '%s' "$state" | jfield mixEpochSizeSec)" = "$want_m_epoch" ] \
        || die "$n: rlnState reports mix epoch $(printf '%s' "$state" | jfield mixEpochSizeSec), want $want_m_epoch: $state"
    params=$(rln_on "$n" get_registry_parameters "$M" "$(argfile "p_$n" "$MIX_ID")") || params=""
    [ "$(printf '%s' "$params" | jfield epoch_size_sec)" = "$want_m_epoch" ] \
        || die "$n: the backend reports M at epoch $(printf '%s' "$params" | jfield epoch_size_sec), want $want_m_epoch: $params"
    params=$(rln_on "$n" get_registry_parameters "$D" "$(argfile "pd_$n" "$RELAY_ID")") || params=""
    [ "$(printf '%s' "$params" | jfield epoch_size_sec)" = "$D_EPOCH" ] \
        || die "$n: the backend reports D at epoch $(printf '%s' "$params" | jfield epoch_size_sec), want $D_EPOCH: $params"
}
# Usage: await_both_memberships <node>
# createNode started the backend with provisioning on: the module registers
# on both registries from the payer the harness funded, each at its rate.
await_both_memberships() {
    local n="$1"
    delivery_await_provisioned "$n" "$D" "$RELAY_ID" "${n}_d"
    delivery_await_provisioned "$n" "$M" "$MIX_ID" "${n}_m"
    [ "$(gv MHASH "${n}_d")" != "$(gv MHASH "${n}_m")" ] \
        || die "$n: one membership answers both registries: $(gv MHASH "${n}_d")"
    say "$n: D leaf $(gv LEAF "${n}_d"), M leaf $(gv LEAF "${n}_m")"
}
# Usage: assert_started <node>
assert_started() {
    local n="$1" V FAILED
    V=$(node_started_verdict "$n")
    [ "$V" = ok ] || die "$n: the library did not start: $V"
    node_logs "$n" | grep -q "Mounting mix protocol" || die "$n: Mix was not mounted (mix:true ignored?)"
    FAILED=$(node_logs "$n" | grep -m1 "Failed to start Mix RLN plugin\|failed to create Mix RLN adapter\|failed to start RLN module") || FAILED=""
    [ -z "$FAILED" ] || die "$n: Mix/RLN bring-up failed in the library: $FAILED"
}
delivery_node_create n1 "$(mix_conf $(( BASE_PORT + 1 )))"
assert_backend_shape n1 "$M_EPOCH"
say "n1: delivery started the backend; D at ${D_EPOCH}s, M at ${M_EPOCH}s"
await_both_memberships n1
PEER1=$(delivery_node_start n1 "$EVT_TIMEOUT") || exit 1
assert_started n1
sv MADDR n1 "/ip4/127.0.0.1/tcp/$(( BASE_PORT + 1 ))/p2p/$PEER1"
# n2 dials n1 through its conf, so it is created once n1's peer id is known.
delivery_node_create n2 "$(mix_conf $(( BASE_PORT + 2 )) "$(gv MADDR n1)")"
assert_backend_shape n2 "$M_EPOCH"
await_both_memberships n2
PEER2=$(delivery_node_start n2 "$EVT_TIMEOUT") || exit 1
assert_started n2
say "n1 ($PEER1) and n2 ($PEER2): started with Mix mounted on the preset's registry"

# ---------- the control: the preset puts M at the wrong epoch -----------------
section "control: n3's preset puts M at ${D_EPOCH}s"
delivery_node_create n3 "$(mix_conf $(( BASE_PORT + 3 )) "$(gv MADDR n1)")"
assert_backend_shape n3 "$D_EPOCH"
delivery_must_call n3 start "start (dispatch)" >/dev/null
node_wait_event n3 delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
    || die "n3: no nodeStarted (success or failure) within ${EVT_TIMEOUT}s"
V=$(node_started_verdict n3)
case "$V" in
    ok) die "n3 started with Mix on M at ${D_EPOCH}s — the Mix profile check did not fire" ;;
    *"Mix profile"*) say "n3: start refused — $V" ;;
    *) die "n3's start failed for another reason than the Mix profile: $V" ;;
esac

# ---------- mesh + send leg (proof-gated Relay on D) --------------------------
section "send leg (proof-gated relay, n1 -> n2)"
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
for n in n1 n2; do
    delivery_must_call "$n" subscribe "subscribe" "$TOPIC" >/dev/null
done
delivery_wait_roots_warm n2 "$D"
RECEIVED=0
ATTEMPT=0
while [ "$ATTEMPT" -lt "$SEND_ATTEMPTS" ]; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    PAYLOAD="two-registries selfstart ping $ATTEMPT from n1"
    REQID=$(delivery_must_call n1 send "send (attempt $ATTEMPT)" "$TOPIC" "$(argfile "pay_$ATTEMPT" "$PAYLOAD")")
    [ -n "$REQID" ] || die "send returned no requestId"
    PROP=$(node_wait_event n1 delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") || {
        node_wait_event n1 delivery_module messageError 1 "$REQID" >/dev/null \
            && die "messageError for requestId $REQID — library: $(node_logs n1 | grep -m1 'usable RLN membership\|Failed to verify RLN membership\|Failed to attach RLN proof' || echo 'see n1 daemon log')"
        die "no messagePropagated for requestId $REQID within ${EVT_TIMEOUT}s"
    }
    MSGHASH=$(printf '%s' "$PROP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
    [ -n "$MSGHASH" ] || die "messagePropagated carried no messageHash: $PROP"
    if node_wait_event n2 delivery_module messageReceived "$RECV_WAIT_S" "$MSGHASH" >/dev/null; then
        RECEIVED=1
        say "attempt $ATTEMPT: n2 received the proof-gated message"
        break
    fi
    say "attempt $ATTEMPT: not received on n2 (fresh-root window?) — retrying with a fresh message"
    sleep 3
done
[ "$RECEIVED" = 1 ] || die "n2 never received a proof-gated message in $SEND_ATTEMPTS attempts"

# ---------- both scopes usable on one backend --------------------------------
section "quotas"
QD=$(delivery_quota n1 "$D" "$RELAY_ID" n1d)
QM=$(delivery_quota n1 "$M" "$MIX_ID" n1m)
[ "$(printf '%s' "$QD" | jfield rate_limit)" = "$RATE_LIMIT" ] || die "n1: no usable membership on D: $QD"
[ "$(printf '%s' "$QM" | jfield rate_limit)" = "$M_RATE_LIMIT" ] || die "n1: no usable membership on M at rate $M_RATE_LIMIT: $QM"
[ "$(printf '%s' "$QD" | jfield remaining)" -lt "$RATE_LIMIT" ] || die "n1: the sends spent nothing on D: $QD"
say "n1: D remaining $(printf '%s' "$QD" | jfield remaining)/$RATE_LIMIT after $ATTEMPT send(s); M $(printf '%s' "$QM" | jfield remaining)/$M_RATE_LIMIT (epoch ${M_EPOCH}s)"

echo
echo "e2e: PASS — delivery started one backend for two registries from its preset (target $E2E_TARGET)"
echo "e2e:   D $D (${D_EPOCH}s): n1 leaf $(gv LEAF n1_d), n2 leaf $(gv LEAF n2_d)"
echo "e2e:   M $M (${M_EPOCH}s/gap $M_GAP): n1 leaf $(gv LEAF n1_m), n2 leaf $(gv LEAF n2_m)"
echo "e2e:   n3 refused to start Mix with its preset's M at ${D_EPOCH}s"
