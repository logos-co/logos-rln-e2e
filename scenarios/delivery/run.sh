#!/usr/bin/env bash
# scenarios/delivery — the RLN-gated-delivery scaffold. What it proves TODAY:
#
#   1. co-residency: three logoscore daemons each load the RLN module stack
#      (logos_execution_zone -> liblogos_lez_rln_module -> liblogos_rln_module)
#      AND delivery_module in one process. This is a real risk, not a
#      formality: delivery_module bundles its own librln (zerokit v2 via
#      liblogosdelivery) while liblogos_rln_module statically links zerokit
#      v3 — a load failure here means symbol/library collision.
#   2. relay: the three delivery nodes form a static-peer gossipsub mesh
#      (n2, n3 dial n1; gossipsub fills in the rest) and messages published
#      on one node arrive on the other two — asserted both directions
#      (n1 -> n2,n3 and n3 -> n1,n2), gated on messagePropagated at the
#      sender and messageReceived at the receivers.
#
# NOT yet here: any RLN <-> delivery coupling. When logos-core wires
# RLN-on-LEZ into delivery, this scenario grows registration + proof-gated
# send, and TARGETS grows local/testnet. The integration contract to hold:
# proofs cross module boundaries as DECOMPOSED fields (the protobuf shape),
# never as zerokit's canonical serialized blob — the stacks pin different
# zerokit major versions and only the decomposed shape is version-agnostic.
#
# Delivery facts this leans on (logos-delivery-module):
#   - peering is config-only (staticnodes multiaddrs); there is no dial RPC.
#   - createNode takes the FLAT WakuNodeConf JSON; the module injects port
#     defaults into it, and flat keys must not be mixed with the structured
#     config shape.
#   - completion is event-driven (nodeStarted/messagePropagated/
#     messageReceived) — there is no poll method; hence node_watch_start.
#   - messageReceived's payload-bytes serialization over the CLI is not yet
#     pinned upstream, so receivers assert on contentTopic, not payload.
#
# Env beyond docs/contract.md:
#   E2E_DELIVERY_BASE_PORT=61840  tcp ports are BASE+1..BASE+3
#   E2E_MESH_WAIT_S=12            gossipsub mesh stabilization pause
#   E2E_EVENT_TIMEOUT_S=30        per-event wait budget
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

BASE_PORT="${E2E_DELIVERY_BASE_PORT:-61840}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
TOPIC="/logos-rln-e2e/1/scaffold/proto"
CLUSTER_ID="198"
NODES_ALL="n1 n2 n3"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done

cleanup() { daemon_stop_all; }
trap cleanup EXIT

port_of() { case "$1" in n1) echo $((BASE_PORT + 1));; n2) echo $((BASE_PORT + 2));; n3) echo $((BASE_PORT + 3));; esac; }

# Flat WakuNodeConf: relay-only, single shard, discovery off — the proven
# local-mesh shape from delivery's own e2e suite. listenAddress is loopback
# (all daemons share this host), so the staticnode multiaddr we build from
# MyPeerId + the pinned port is directly dialable.
delivery_cfg() {
    local port="$1" peers="$2"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true%s}' \
        "$port" "$CLUSTER_ID" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

# call + insist on StdLogosResult success; prints the value.
must_call() {
    local node="$1" method="$2" label="$3"; shift 3
    local res
    res=$(node_call "$node" delivery_module "$method" "$@" | jres) || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" | jval ;;
        *) die_node "$node" "$label failed: ${res:-<empty>}" ;;
    esac
}

delivery_up() {
    local node="$1" peers="$2" port cfg peerid
    port=$(port_of "$node")
    cfg=$(delivery_cfg "$port" "$peers")
    must_call "$node" createNode "createNode" "$(argfile "cfg_$node" "$cfg")" >/dev/null
    must_call "$node" start "start" >/dev/null
    node_wait_event "$node" delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
        || die_node "$node" "no nodeStarted event within ${EVT_TIMEOUT}s"
    peerid=$(must_call "$node" getNodeInfo "getNodeInfo MyPeerId" MyPeerId)
    [ -n "$peerid" ] || die_node "$node" "empty MyPeerId"
    say "$node: delivery up on 127.0.0.1:$port (peer $peerid)"
    sv MADDR "$node" "/ip4/127.0.0.1/tcp/$port/p2p/$peerid"
}

# One relay round: publish on $1, expect arrival on the rest. Receiver waits
# key on the round's messageHash (propagated arg1 == received arg0), not the
# topic — both rounds share the topic, and a stale round-1 messageReceived
# line would satisfy a topic match instantly. The hash also sidesteps the
# unpinned payload-bytes serialization.
relay_round() {
    local sender="$1"; shift
    local payload="scaffold ping from $sender" reqid prop msghash rcv
    say "$sender: send on $TOPIC"
    reqid=$(must_call "$sender" send "send" "$TOPIC" "$(argfile "pay_$sender" "$payload")")
    [ -n "$reqid" ] || die_node "$sender" "send returned no requestId"
    prop=$(node_wait_event "$sender" delivery_module messagePropagated "$EVT_TIMEOUT" "$reqid") || {
        node_wait_event "$sender" delivery_module messageError 1 "$reqid" >/dev/null \
            && die_node "$sender" "messageError for requestId $reqid"
        die_node "$sender" "no messagePropagated for requestId $reqid within ${EVT_TIMEOUT}s"
    }
    msghash=$(printf '%s' "$prop" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
    [ -n "$msghash" ] || die_node "$sender" "messagePropagated carried no messageHash: $prop"
    say "$sender: propagated (requestId $reqid, hash ${msghash:0:18}…)"
    for rcv in "$@"; do
        node_wait_event "$rcv" delivery_module messageReceived "$EVT_TIMEOUT" "$msghash" >/dev/null \
            || die_node "$rcv" "$rcv never received $sender's message $msghash"
        say "$rcv: received"
    done
}

# ---------- daemons + module co-residency ------------------------------------
section "daemons: RLN stack + delivery_module on each"
for n in $NODES_ALL; do
    daemon_start "$n" || die "daemon_start $n failed"
    daemon_load_modules "$n" logos_execution_zone liblogos_lez_rln_module \
        liblogos_rln_module delivery_module
done
say "co-residency: all 4 modules loaded on 3 daemons"

# ---------- delivery mesh ----------------------------------------------------
section "delivery mesh (static peers, relay only)"
for n in $NODES_ALL; do node_watch_start "$n" delivery_module; done

delivery_up n1 ""
delivery_up n2 "$(gv MADDR n1)"
delivery_up n3 "$(gv MADDR n1)"

say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"

for n in $NODES_ALL; do
    must_call "$n" subscribe "subscribe" "$TOPIC" >/dev/null
done
say "all nodes subscribed to $TOPIC"
sleep 1

# ---------- relay ------------------------------------------------------------
section "relay: n1 -> {n2,n3}, then n3 -> {n1,n2}"
relay_round n1 n2 n3
relay_round n3 n1 n2

echo
echo "e2e: PASS — 3-node co-residency + relay mesh"
echo "e2e:   modules   logos_execution_zone liblogos_lez_rln_module liblogos_rln_module delivery_module"
echo "e2e:   mesh      n2,n3 -> n1 (static peers), gossipsub"
echo "e2e:   relay     n1->{n2,n3} and n3->{n1,n2} on $TOPIC"
