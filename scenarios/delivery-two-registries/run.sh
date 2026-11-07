#!/usr/bin/env bash
# scenarios/delivery-two-registries — the delivery module in front of one
# liblogos_rln_module that serves TWO registries at two epochs: Relay RLN on
# the delivery tree D (600 s, resolved from the preset) and native Mix RLN on
# the mix tree M (10 s, the LIP LOGOS-MIXNET profile), in one process.
#
# The delivery module starts the backend with one registry and one epoch, and
# the Mix plugin refuses to start unless the backend reports M at exactly
# 10 s / gap 3 — so the shape 0.4 ships is the host owning the backend
# (`manage-backend: false` in the preset) and starting it once with both
# registries, M at its own epoch. This drives exactly that:
#
#   presets: D / relay scope / 600 s, manage-backend false
#   -> host start on every node: {600, [D, {M, 10, 3}]}, provisioning on
#      -> the module registers a membership on BOTH registries from one
#         payer, and each goes active
#   -> createNode with native Mix on M (mix-rln-registry-id); rlnState Ready
#      names D at 600 s; delivery start succeeds (the Mix plugin accepted M
#      at 10 s); delivery requested no backend start of its own
#   -> a Relay message n1 -> n2 is proof-gated on D and delivered
#   -> n1's module reports a usable membership on both scopes; D's quota was
#      spent by the sends
#   -> n3, whose backend was started with M at the instance default (600 s),
#      fails delivery start on the Mix profile mismatch: the check is live,
#      and the per-registry epoch is what makes n1 and n2 pass it
#
# Mix carries no traffic here — there are no intermediates — and that is the
# point: the one backend serving both scopes at their own epochs is what is
# under test, not the route (scenarios/mix-delivery-rln owns that).
#
# Env beyond docs/contract.md:
#   E2E_DELIVERY_EPOCH_SIZE_SEC=600  D's epoch; E2E_MIX_EPOCH_SIZE_SEC=10 and
#                                    E2E_MIX_MAX_EPOCH_GAP=3 are the Mix
#                                    profile's and are not knobs upstream
#   E2E_RATE_LIMIT=100               rate limit of the memberships provisioned on D
#   E2E_MIX_RATE_LIMIT=20            rate limit of the memberships provisioned on M
#                                    (M's range is 20..=100: profiles/local-default/
#                                    registry-mix.env; D's 100..=600)
#   E2E_DELIVERY_RLN_PORT=61890      tcp ports are PORT+1..3
#   E2E_EVENT_TIMEOUT_S=30           per-event wait budget
#   E2E_MESH_WAIT_S=12               gossipsub mesh stabilization pause
#   E2E_SEND_ATTEMPTS=3              send-leg attempts (fresh-root window)
#   E2E_RECV_WAIT_S=12               per-attempt receive wait on n2
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
TOPIC="/logos-rln-e2e/1/delivery-two-registries/proto"
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
# One start, both registries; the mix entry carries its own epoch AND its own
# provisioning rate (the mix tree accepts 20..=100, the delivery tree
# 100..=600, so one rate cannot serve both).
HOST_START="{\"epoch_size_sec\":$D_EPOCH,\"rate_limit\":$RATE_LIMIT,\"registries\":[\"$D\",{\"registry_id\":\"$M\",\"epoch_size_sec\":$M_EPOCH,\"max_epoch_gap\":$M_GAP,\"rate_limit\":$M_RATE_LIMIT}]}"
# The control's backend: both registries named, M at the instance default.
CONTROL_START="{\"epoch_size_sec\":$D_EPOCH,\"registries\":[\"$D\",\"$M\"],\"provision\":false}"

# ---------- daemons -----------------------------------------------------------
section "daemons"
# The preset carries D only, and hands the backend to the host: delivery
# installs its Relay bridge on it but calls neither start nor stop.
RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$D" "$RELAY_ID" "$D_EPOCH" "" '"manage-backend": false'
E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} $(delivery_rln_presets_env "$RLN_PRESETS_FILE")"
export E2E_DAEMON_ENV
for n in $NODES_ALL; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
done
for n in $NODES_ALL; do
    daemon_start "$n" || die "daemon_start $n failed"
    daemon_load_modules "$n" liblogos_lez_rln_module liblogos_rln_module delivery_module \
        || die "$n: load-module failed"
done
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
# The control registers nothing; its wallet only serves the registry reads.
wallet_open n3 || die "n3: wallet open failed"
wallet_sync n3 >/dev/null || die "n3: wallet sync failed"

# Usage: rln_on <node> <method> [args…]  -> the value of a liblogos_rln_module call
rln_on() { local n="$1"; shift; node_call "$n" liblogos_rln_module "$@" | jres | jval; }

# ---------- the host owns the backend -----------------------------------------
section "backend: one start per node, both registries, two epochs"
for n in n1 n2; do
    delivery_prewarm "$n" "$HOST_START"
done
delivery_prewarm n3 "$CONTROL_START"
for n in n1 n2; do
    PARAMS=$(rln_on "$n" get_registry_parameters "$M" "$(argfile "p_$n" "$MIX_ID")") || PARAMS=""
    [ "$(printf '%s' "$PARAMS" | jfield epoch_size_sec)" = "$M_EPOCH" ] \
        || die "$n: M reports epoch $(printf '%s' "$PARAMS" | jfield epoch_size_sec), want $M_EPOCH: $PARAMS"
done
PARAMS=$(rln_on n3 get_registry_parameters "$M" "$(argfile p_n3 "$MIX_ID")") || PARAMS=""
[ "$(printf '%s' "$PARAMS" | jfield epoch_size_sec)" = "$D_EPOCH" ] \
    || die "n3 (control): M reports epoch $(printf '%s' "$PARAMS" | jfield epoch_size_sec), want the instance default $D_EPOCH: $PARAMS"
say "n1, n2: M at ${M_EPOCH}s; n3 (control): M at ${D_EPOCH}s"

section "provisioning (the module registers on both registries; the harness only funded it)"
for n in n1 n2; do
    delivery_await_provisioned "$n" "$D" "$RELAY_ID" "${n}_d"
    delivery_await_provisioned "$n" "$M" "$MIX_ID" "${n}_m"
    [ "$(gv MHASH "${n}_d")" != "$(gv MHASH "${n}_m")" ] \
        || die "$n: one membership answers both registries: $(gv MHASH "${n}_d")"
    say "$n: D leaf $(gv LEAF "${n}_d"), M leaf $(gv LEAF "${n}_m")"
done

# ---------- delivery nodes: Relay on D from the preset, native Mix on M ------
section "delivery nodes (Relay RLN from the preset, native Mix RLN on M)"
# Usage: mix_conf <tcp_port> [static_peer_maddr]
# The flat Relay conf plus native Mix on M. The Mix scope's epoch is not a
# conf key — the plugin's profile fixes it, and the backend must agree.
mix_conf() {
    local port="$1" peers="${2:-}"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"ip-colocation-limit":0,"mix":true,"maxPureLibp2pPeers":100,"mix-rln-registry-id":"%s","mix-rln-identifier-hex":"%s","mix-rln-metadata-topic":"%s"%s}' \
        "$port" "$CLUSTER_ID" "$M" "$MIX_ID" "$META_TOPIC" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}
for n in $NODES_ALL; do
    node_watch_start "$n" delivery_module
done
# Usage: node_started_verdict <node>  -> "ok" or the failure the library reported
# nodeStarted carries (arg0: started?, arg1: why not): a Mix RLN plugin that
# refuses its backend fails the whole start here, with the reason.
node_started_verdict() {
    grep -E '"event":"nodeStarted"' "$(gv NODEEVT "${1}_delivery_module")" | tail -1 | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}").get("data", {})
print("ok" if d.get("arg0") is True else (d.get("arg1") or "nodeStarted carried no reason"))'
}
delivery_node_create n1 "$(mix_conf $(( BASE_PORT + 1 )))"
PEER1=$(delivery_node_start n1 "$EVT_TIMEOUT") || exit 1
sv MADDR n1 "/ip4/127.0.0.1/tcp/$(( BASE_PORT + 1 ))/p2p/$PEER1"
delivery_node_create n2 "$(mix_conf $(( BASE_PORT + 2 )) "$(gv MADDR n1)")"
PEER2=$(delivery_node_start n2 "$EVT_TIMEOUT") || exit 1
for n in n1 n2; do
    V=$(node_started_verdict "$n")
    [ "$V" = ok ] || die "$n: the library did not start: $V"
    node_logs "$n" | grep -q "Mounting mix protocol" || die "$n: Mix was not mounted (mix:true ignored?)"
done
say "n1 ($PEER1) and n2 ($PEER2): started with Mix mounted; rlnState Ready on D, Mix RLN on M accepted"

# manage-backend false: delivery must not have asked for a backend start.
for n in n1 n2; do
    if node_wait_event "$n" delivery_module "$(delivery_rln_evt rlnStartRequest)" 2 >/dev/null; then
        die "$n: delivery requested a backend start although the preset says manage-backend false"
    fi
    FAILED=$(node_logs "$n" | grep -m1 "Failed to start Mix RLN plugin\|failed to create Mix RLN adapter\|failed to start RLN module") || FAILED=""
    [ -z "$FAILED" ] || die "$n: Mix/RLN bring-up failed in the library: $FAILED"
done
say "n1, n2: the backend stayed the host's (no rlnStartRequest); no Mix bring-up failure logged"

# ---------- the control: M at the wrong epoch ---------------------------------
section "control: n3's backend has M at ${D_EPOCH}s"
delivery_node_create n3 "$(mix_conf $(( BASE_PORT + 3 )) "$(gv MADDR n1)")"
# start is dispatched: the wire reply is success either way, and the verdict
# arrives as nodeStarted (arg0 false + the reason) once the library gives up.
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
    PAYLOAD="two-registries ping $ATTEMPT from n1"
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
echo "e2e: PASS — delivery over one backend serving two registries (target $E2E_TARGET)"
echo "e2e:   D $D (${D_EPOCH}s): n1 leaf $(gv LEAF n1_d), n2 leaf $(gv LEAF n2_d)"
echo "e2e:   M $M (${M_EPOCH}s/gap $M_GAP): n1 leaf $(gv LEAF n1_m), n2 leaf $(gv LEAF n2_m)"
echo "e2e:   n3 refused to start Mix with M at ${D_EPOCH}s"
