#!/usr/bin/env bash
# scenarios/delivery-relay-rln — the peers meet at a relay.
#
# n1 and n2 are host daemons with on-chain memberships. r1 is a CONTAINER
# running the same delivery_module, and it is the only address either peer is
# given: neither ever learns the other's multiaddr, so "they never dial each
# other" is structural rather than asserted. A message from n1 reaches n2 only
# by being forwarded.
#
# What this adds over delivery-rln, which wires the two peers directly:
#   1. a real network hop — the relay is another process on another host stack,
#      reached over a published port, not a second thread on loopback.
#   2. the bring-up a deployed relay actually does: the container provisions
#      its own wallet from LEZ_RLN_PAYER_KEY (nothing mounts a storage.json
#      into it, which would make a second writer of a module-owned file) and
#      reaches the chain by name, since 127.0.0.1 inside a container is the
#      container.
#   3. with E2E_RELAY_RLN=1, a relay that VALIDATES every proof it forwards —
#      a third membership on the same registry, under the same rln_identifier.
#
# E2E_RELAY_RLN=0 keeps the topology and drops the validation, which is the
# control: it separates "the relay dropped it" from "the receiver rejected it".
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100         registration rate limit (a register_membership
#                              option; the conf carries no rln-* key)
#   E2E_RELAY_RLN=1            relay validates what it forwards (0 = blind)
#   E2E_RELAY_IMAGE            relay image (tools/build-e2e-image.sh)
#   E2E_RELAY_PORT=61890       relay libp2p port, published on 127.0.0.1
#   E2E_PEER_PORT=61895        host peer ports are PORT+1, PORT+2
#   E2E_EVENT_TIMEOUT_S=30     per-event wait budget
#   E2E_MESH_WAIT_S=12         gossipsub stabilisation before the send
#   E2E_RECV_WAIT_S=20         receive wait per attempt
#   E2E_SEND_ATTEMPTS=3        a fresh-root window can cost the first send
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain relay; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
PEER_PORT="${E2E_PEER_PORT:-61895}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-20}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
TOPIC="/logos-rln-e2e/1/delivery-relay/proto"
CLUSTER_ID="198"
PEERS="n1 n2"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC E2E_PAYER; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_FUNDING" = faucet ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — registrations here are faucet-paid"
docker image inspect "${E2E_RELAY_IMAGE:-logos-rln-e2e:relay}" >/dev/null 2>&1 \
    || die "no relay image ${E2E_RELAY_IMAGE:-logos-rln-e2e:relay} — build it: bash tools/build-e2e-image.sh"

polls() { local n=$(( $1 / $2 )); [ "$n" -ge 1 ] || n=1; printf '%s' "$n"; }

NODES_UP=0
_orig_die=$(declare -f die)
cleanup() {
    [ "$NODES_UP" = 1 ] || return 0
    relay_down r1 2>/dev/null || true
    daemon_stop_all 2>/dev/null || true
}
trap cleanup EXIT

must_call() {
    local node="$1" method="$2" label="$3"; shift 3
    local res
    res=$(node_call "$node" delivery_module "$method" "$@" | jres) || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" | jval ;;
        *) die_node "$node" "$label failed: ${res:-<empty>}" ;;
    esac
}

# ---------- scope ------------------------------------------------------------
CONFIG_HEX=$(python3 - "$E2E_CONFIG_ACCOUNT" <<'EOF'
import sys
A="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n=0
for c in sys.argv[1]:
    n = n*58 + A.index(c)
b = n.to_bytes(32, "big")
print(b.hex())
EOF
) || die "cannot decode config account '$E2E_CONFIG_ACCOUNT'"
REGISTRY_ID="logos:${E2E_TARGET}:$CONFIG_HEX"
# ONE identifier for every node, relay included: rln_identifier scopes the
# APPLICATION, not the member (docs/contract.md). A per-node value rejects
# every message in a way that reads like a product fault.
RLN_ID=$(openssl rand -hex 32)
say "registry: $REGISTRY_ID (rate $RATE_LIMIT, relay-rln=${E2E_RELAY_RLN:-1})"

# ---------- host peers -------------------------------------------------------
section "host peers"
for n in $PEERS; do
    daemon_start "$n" || die "daemon_start $n failed"
    NODES_UP=1
done
for n in $PEERS; do
    daemon_load_modules "$n" liblogos_lez_rln_module liblogos_rln_module delivery_module \
        || die "$n: load-module failed"
done
for n in $PEERS; do
    wallet_ready "$n" || die "$n: wallet never became ready"
done

# ---------- registration (peers, then the relay) -----------------------------
# Sequential, always: every daemon declares the SAME LEZ_RLN_PAYER, and two
# fee-paying transactions from one account race its nonce.
section "registration"
BOUNDS=$(node_call n1 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in registry bounds: ${BOUNDS:-<empty>}"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))

register_node() {
    local node="$1" holding state _t
    holding=$(wallet_fresh_holding "$node") \
        || die_node "$node" "no unused holding account (walk exhausted)"
    # The amount goes over bare: "str:" would force it to a string and the
    # faucet silently credits nothing.
    local claim_res
    claim_res=$(node_call "$node" liblogos_lez_rln_module claim_tokens \
        "$(argfile "cfg_$node" "$E2E_CONFIG_ACCOUNT")" \
        "$(argfile "hold_$node" "$holding")" "$CLAIM" | jres) || claim_res=""
    [ -n "$claim_res" ] || die_node "$node" "claim_tokens failed"
    # wait_balance PRINTS the balance it saw; that belongs in the failure, not
    # in the middle of the scenario's output.
    wait_balance "$node" "$holding" "$CLAIM" >/dev/null \
        || die_node "$node" "faucet claim never landed (want $CLAIM, holding $holding)"
    node_call "$node" liblogos_rln_module start \
        "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" >/dev/null \
        || die_node "$node" "rln module start failed"
    local options="[{\"key\":\"rate_limit\",\"value\":\"$RATE_LIMIT\"},{\"key\":\"funding_holding_account_id\",\"value\":\"$holding\"}]"
    node_call "$node" liblogos_rln_module register_membership \
        "$REGISTRY_ID" "$(argfile "reg_$node" "$RLN_ID")" "$options" >/dev/null \
        || die_node "$node" "register_membership failed"
    for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        state=$(node_call "$node" liblogos_rln_module get_membership_state \
            "$REGISTRY_ID" "$(argfile "st_$node" "$RLN_ID")" | jres | jfield state) || state=""
        case "$state" in
            active|grace_period) say "$node: membership $state"; return 0 ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    die_node "$node" "membership never reached active (last state: ${state:-<none>})"
}
# Strictly sequential: every daemon declares the same LEZ_RLN_PAYER and two
# fee-paying transactions from one account race its nonce — and derivation is
# deterministic, so each node must claim before the next derives or they land
# on the same "fresh" holding.
for n in $PEERS; do register_node "$n"; done

# ---------- the relay --------------------------------------------------------
section "relay (container)"
relay_up r1
daemon_load_modules r1 liblogos_lez_rln_module liblogos_rln_module delivery_module \
    || die "r1: load-module failed"
if [ "${E2E_RELAY_RLN:-1}" = 1 ]; then
    wallet_ready r1 || die "r1: relay wallet never became ready"
    register_node r1
fi

# ---------- bring-up ---------------------------------------------------------
# The conf carries NO rln-* key: those exist only on a logos-delivery fork.
# configureRln is the upstream door and must precede createNode.
section "delivery bring-up"
configure_rln() {
    local node="$1" cfg res
    cfg=$(printf '{"registry-id":"%s","rln-identifier":"%s","epoch-size-sec":%s}' \
        "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC")
    res=$(node_call "$node" delivery_module configureRln "$(argfile "rlncfg_$node" "$cfg")" | jres) || res=""
    case "$res" in
        *'"servedInProcess":true'*) say "$node: configureRln — rln served in-process"; return 0 ;;
        *'"servedInProcess":false'*) die_node "$node" "configureRln came up WITHOUT the bridge" ;;
    esac
    local _t
    for _t in $(seq 1 "$(polls "${E2E_CONFIGURE_RLN_TIMEOUT_S:-180}" 5)"); do
        node_logs "$node" 200 | grep -q "rln served in-process" && { say "$node: configureRln (via log)"; return 0; }
        sleep 5
    done
    die_node "$node" "configureRln never reported 'rln served in-process'"
}

# listenAddress 0.0.0.0, not loopback: the relay must be able to dial a peer
# back after a drop, and from a container 127.0.0.1 is the container.
delivery_cfg() {
    local port="$1" peers="$2"
    printf '{"logLevel":"INFO","listenAddress":"0.0.0.0","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true%s}' \
        "$port" "$CLUSTER_ID" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

[ "${E2E_RELAY_RLN:-1}" = 1 ] && configure_rln r1
must_call r1 createNode "r1 createNode" \
    "$(argfile cfg_r1 "$(delivery_cfg "$E2E_RELAY_PORT" "")")" >/dev/null
must_call r1 start "r1 start" >/dev/null
RELAY_MADDR=$(relay_maddr r1)
say "relay listening at $RELAY_MADDR"

i=0
for n in $PEERS; do
    i=$(( i + 1 ))
    node_watch_start "$n" delivery_module
    configure_rln "$n"
    # Each peer is given the RELAY and nothing else — neither ever holds the
    # other's address, which is what makes the hop structural.
    must_call "$n" createNode "$n createNode" \
        "$(argfile "cfg_$n" "$(delivery_cfg "$(( PEER_PORT + i ))" "$RELAY_MADDR")")" >/dev/null
    must_call "$n" start "$n start" >/dev/null
    node_wait_event "$n" delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
        || die_node "$n" "no nodeStarted within ${EVT_TIMEOUT}s"
    say "$n: delivery up on 0.0.0.0:$(( PEER_PORT + i )), peering only with the relay"
done

# ---------- mesh + send ------------------------------------------------------
section "relay the message"
for n in $PEERS; do must_call "$n" subscribe "$n subscribe" "$TOPIC" >/dev/null; done
[ "${E2E_RELAY_RLN:-1}" = 1 ] && must_call r1 subscribe "r1 subscribe" "$TOPIC" >/dev/null
say "mesh stabilisation: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"

# n2 must be able to read the registry before it can validate anything.
ROOTS_BUDGET="${E2E_ROOTS_WARM_BUDGET_S:-300}"
for _t in $(seq 1 "$(polls "$ROOTS_BUDGET" 5)"); do
    R=$(node_call n2 liblogos_rln_module get_valid_roots "$REGISTRY_ID" 2>/dev/null | jres) || R=""
    case "$R" in *'"valid_roots"'*|\[*) break ;; esac
    sleep 5
done
say "n2 registry read path warm"

QUOTA_BEFORE=$(node_call n1 liblogos_rln_module get_epoch_quota \
    "$REGISTRY_ID" "$(argfile q1 "$RLN_ID")" "str:$(date +%s)" | jres | jval | jfield remaining) || QUOTA_BEFORE=""
[ -n "$QUOTA_BEFORE" ] || die "could not read n1's epoch quota before the send"
say "n1 quota before the send: $QUOTA_BEFORE"

RECEIVED=0
for ATTEMPT in $(seq 1 "$SEND_ATTEMPTS"); do
    PAYLOAD="relayed ping $ATTEMPT from n1"
    REQID=$(must_call n1 send "n1 send" "$TOPIC" "$(argfile "pay_$ATTEMPT" "$PAYLOAD")")
    PROP=$(node_wait_event n1 delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") \
        || die "n1: message never propagated (attempt $ATTEMPT)"
    MSGHASH=$(printf '%s' "$PROP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
    say "attempt $ATTEMPT: propagated (hash ${MSGHASH:0:18}…)"
    if node_wait_event n2 delivery_module messageReceived "$RECV_WAIT_S" "$MSGHASH" >/dev/null; then
        RECEIVED=1
        say "attempt $ATTEMPT: n2 received it — forwarded by the relay, never peer-to-peer"
        break
    fi
    say "attempt $ATTEMPT: not received (fresh-root window?) — retrying"
    sleep 3
done
[ "$RECEIVED" = 1 ] || die "n2 never received a relayed message in $SEND_ATTEMPTS attempts"

QUOTA_AFTER=$(node_call n1 liblogos_rln_module get_epoch_quota \
    "$REGISTRY_ID" "$(argfile q2 "$RLN_ID")" "str:$(date +%s)" | jres | jval | jfield remaining) || QUOTA_AFTER=""
[ -n "$QUOTA_AFTER" ] || die "could not read n1's epoch quota after the send"
if [ "$QUOTA_AFTER" -lt "$QUOTA_BEFORE" ]; then
    say "n1 quota $QUOTA_BEFORE -> $QUOTA_AFTER: the send spent real slots"
else
    # An epoch roll resets the counter; that is not a failure, just unprovable.
    say "n1 quota $QUOTA_BEFORE -> $QUOTA_AFTER (epoch rolled — spend not assertable this run)"
fi

echo
echo "e2e: PASS — delivery-relay-rln (target $E2E_TARGET)"
echo "e2e:   topology  n1 and n2 peered ONLY with the container relay; neither holds the other's address"
echo "e2e:   relay     $RELAY_MADDR (rln=${E2E_RELAY_RLN:-1}$([ "${E2E_RELAY_RLN:-1}" = 1 ] && echo ", own membership, validates what it forwards"))"
echo "e2e:   bring-up  configureRln + a conf with NO rln-* key — upstream delivery, no fork"
echo "e2e:   wallet    the relay provisioned its own from LEZ_RLN_PAYER_KEY; nothing mounted a storage.json into it"
echo "e2e:   message   n1 -> relay -> n2 on $TOPIC (attempt $ATTEMPT/$SEND_ATTEMPTS)"
echo "e2e:   quota     $QUOTA_BEFORE -> $QUOTA_AFTER"
