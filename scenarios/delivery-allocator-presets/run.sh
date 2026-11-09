#!/usr/bin/env bash
# scenarios/delivery-allocator-presets — the membership allocation protocol is
# how a delivery node gets its memberships BY DEFAULT, through libp2p
# service discovery, with the funded registration as the fallback.
#
# Topology:
#   b        a bootstrap peer: libp2p_module alone with service discovery
#            mounted — the registrar the allocator's advertisement lands on
#            and the delivery nodes' lookups ask.
#   g        the allocator: liblogos_lez_rln_module + libp2p_module +
#            rln_gifter_module + rln_auth_module, its own funded payer,
#            serving the delivery registry D and the mix registry M with
#            the peer-any verifier (any libp2p peer, once per registry),
#            bootstrapped to b and advertising what it serves.
#   n1, n2   delivery nodes, never funded: the RLN stack (which brings
#            libp2p_module + rln_gifter_module) + delivery_module, on plugin
#            kademlia discovery bootstrapped to b. Their preset names the
#            two registries and NO allocator: createNode alone discovers g
#            and gets each a membership on D and on M through it, and n1
#            sends a proof-gated message n2 receives.
#   n3       never funded, NO plugin kademlia discovery and no
#            kadBootstrapNodes in its conf; its preset names no allocator
#            but carries allocator-bootstrap-nodes (b): the delivery module
#            brings libp2p_module up with service discovery on those peers,
#            and n3 discovers g.
#   n4       the fallback: no bootstrap peers, no plugin discovery, a preset
#            naming an allocator address nobody listens on, and a FUNDED
#            payer: provisioning records why no allocator delivered and
#            registers from n4's own wallet.
#
# What it proves:
#   1. with discovery on the node the delivery module brings its
#      libp2p_module up on the node's discovery config and the RLN module's
#      provisioning asks the discovered allocator first (provisioning.step
#      "delegating"), for both registries;
#   2. n1 and n2 hold active memberships on D and M that the ALLOCATOR paid
#      for (their payers never move), and n1 -> n2 relay is proof-gated;
#   3. n3, with the preset's allocator-bootstrap-nodes alone (no plugin
#      kademlia, no conf kad list), gets both memberships from the
#      discovered allocator (its payer never moves);
#   4. n4 has nothing to discover with and cannot reach its configured
#      allocator: provisioning reports the reason
#      (provisioning.fallback_reason) and falls back to a funded registration
#      that lands (n4's payer paid);
#   5. rlnState reports the allocator path (discovery; the configured peer).
#
# Required: DELIVERY_LGX | DELIVERY_MODULE_CHECKOUT (>= 0.3.7: discovery
#   without pluginKadDiscovery), LIBP2P_LGX |
#   LIBP2P_MODULE_CHECKOUT (>= 1.1.0), GIFTER_LGX + AUTH_LGX | GIFTER_CHECKOUT
#   (logos-rln-gifter refactor/auth-vector-pipeline, rln_gifter_module >=
#   0.5.0), liblogos_rln_module >= 0.15.0 (the allocator block discovers).
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100  E2E_MIX_RATE_LIMIT=20  E2E_DELIVERY_RLN_PORT=61930
#   E2E_ALLOC_PORT=62300 (+8: the bootstrap peer, +9: the dead address)
#   E2E_EVENT_TIMEOUT_S=30  E2E_MESH_WAIT_S=12
#   E2E_SEND_ATTEMPTS=3  E2E_RECV_WAIT_S=12
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
BASE_PORT="${E2E_DELIVERY_RLN_PORT:-61930}"
GPORT="${E2E_ALLOC_PORT:-62300}"
GADDR="/ip4/127.0.0.1/tcp/$GPORT"
BADDR="/ip4/127.0.0.1/tcp/$(( GPORT + 8 ))"
DEAD_ADDR="/ip4/127.0.0.1/tcp/$(( GPORT + 9 ))"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-12}"
TOPIC="/logos-rln-e2e/1/delivery-allocator-presets/proto"
META_TOPIC="/mix/1/metadata/proto"
CLUSTER_ID="198"
NODES_ALL="b g n1 n2 n3 n4"

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
D_CFG=$(registry_config_account default) || exit 1
M_CFG=$(registry_config_account mix) || exit 1
[ "$D" != "$M" ] || die "the two registries resolve to one id: $D"
MIX_ID=6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000
RELAY_ID=$(delivery_rln_identifier)
say "D (delivery, ${D_EPOCH}s): $D"
say "M (mix, ${M_EPOCH}s/gap $M_GAP): $M"

# ---------- the bootstrap peer (b) -------------------------------------------
section "bootstrap peer (b)"
daemon_start b || die "daemon_start b failed"
NODES_UP=1
daemon_load_modules b libp2p_module || die "b: load-module failed"
node_call b libp2p_module createNode "{\"addrs\":[\"$BADDR\"],\"transport\":\"tcp\",\"mountServiceDiscovery\":true}" | jres >/dev/null \
    || die "b: libp2p createNode failed"
node_call b libp2p_module start | jres >/dev/null || die "b: libp2p start failed"
BPEER=$(node_call b libp2p_module peerInfo | jres | jval | jfield peerId) || BPEER=""
[ -n "$BPEER" ] || die "b: no peerId"
say "bootstrap peer $BPEER @ $BADDR"

# ---------- the allocator (g) ------------------------------------------------
section "allocator (g)"
daemon_self_paying g "$E2E_RUN_DIR/wallet-g"
daemon_start g || die "daemon_start g failed"
daemon_load_modules g liblogos_lez_rln_module libp2p_module rln_gifter_module rln_auth_module \
    || die "g: load-module failed"
wallet_open g || die "g: wallet open failed"
wallet_sync g >/dev/null || die "g: wallet sync failed"
PRICE=$(node_call g liblogos_lez_rln_module get_registry_bounds "$(argfile gcfg "$D_CFG")" | jres | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in the registry bounds"
GPAYER=$(wallet_payer g) || die "g published no payer"
wallet_fund g >/dev/null || die "funding the allocator's payer never landed"
gbal() { wallet_native_balance g "$GPAYER"; }
GBAL0=$(gbal)
node_call g libp2p_module createNode \
    "{\"addrs\":[\"$GADDR\"],\"transport\":\"tcp\",\"mountServiceDiscovery\":true,\"bootstrapNodes\":[{\"peerId\":\"$BPEER\",\"addrs\":[\"$BADDR\"]}]}" | jres >/dev/null \
    || die "g: libp2p createNode failed"
node_call g libp2p_module start | jres >/dev/null || die "g: libp2p start failed"
GPEER=$(node_call g libp2p_module peerInfo | jres | jval | jfield peerId) || GPEER=""
[ -n "$GPEER" ] || die "g: no peerId"
SERVE=$(jq -cn --arg d "$D_CFG" --arg m "$M_CFG" --arg w "$GPAYER" --arg n "$E2E_RUN_DIR/allocator-nullifiers" --argjson r "$RATE_LIMIT" \
    '{config:$d, registries:[{config:$m, maxRateLimit:$r}], wallet:$w, consumedNullifiersPath:$n, maxRateLimit:$r, advertise:true,
      authVerifiers:{"peer-any":{module:"rln_auth_module", config:{}}}}')
RES=$(node_call g rln_gifter_module serve "$SERVE" | jres) || RES=""
case "$RES" in
    *'"advertised":true'*'"mounted":true'*) say "g: serving D and M with peer-any, advertised: $RES" ;;
    *) die_node g "serve failed or did not advertise: ${RES:-<empty>}" ;;
esac
say "allocator peer $GPEER @ $GADDR, payer $GPAYER holds $GBAL0; price $PRICE per unit"

# Usage: assert_deps_loaded <node>
# load-module liblogos_rln_module brings the allocator client and libp2p
# with it (declared dependencies, loaded by logoscore): the CLI's reply in
# the node log names both under dependencies_loaded.
assert_deps_loaded() {
    local loaded name
    loaded=$(node_logs "$1" | grep -m1 '"module":"liblogos_rln_module"' | python3 -c '
import json, sys
line = sys.stdin.read().strip()
print(" ".join(sorted(json.loads(line).get("dependencies_loaded", []))) if line else "")') || loaded=""
    for name in rln_gifter_module libp2p_module; do
        case " $loaded " in
            *" $name "*) ;;
            *) die "$1: loading liblogos_rln_module did not bring $name along (dependencies_loaded: '$loaded')" ;;
        esac
    done
    say "$1: loading liblogos_rln_module loaded [$loaded]"
}

# ---------- delivery daemons -------------------------------------------------
section "delivery daemons"
# The preset names both registries and NO allocator: the RLN module asks
# the allocators discovery finds (the default) before anything else.
PRESETS_N12="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$PRESETS_N12" "$D" "$RELAY_ID" "$D_EPOCH" "" \
    "\"rate-limit\": $RATE_LIMIT, \"mix-registry-id\": \"$M\", \"mix-rate-limit\": $M_RATE_LIMIT, \"mix-metadata-topic\": \"$META_TOPIC\""
# n3's preset names no allocator and carries the DHT peers its allocator
# path bootstraps from.
PRESETS_N3="$E2E_RUN_DIR/rln-presets-bootstrap.json"
delivery_stage_rln_presets "$PRESETS_N3" "$D" "$RELAY_ID" "$D_EPOCH" "" \
    "\"rate-limit\": $RATE_LIMIT, \"mix-registry-id\": \"$M\", \"mix-rate-limit\": $M_RATE_LIMIT, \"mix-metadata-topic\": \"$META_TOPIC\", \"allocator-bootstrap-nodes\": [\"$BADDR/p2p/$BPEER\"]"
# n4's preset dials an address nobody listens on.
PRESETS_N4="$E2E_RUN_DIR/rln-presets-dead-allocator.json"
delivery_stage_rln_presets "$PRESETS_N4" "$D" "$RELAY_ID" "$D_EPOCH" "" \
    "\"rate-limit\": $RATE_LIMIT, \"mix-registry-id\": \"$M\", \"mix-rate-limit\": $M_RATE_LIMIT, \"mix-metadata-topic\": \"$META_TOPIC\", \"allocator-peer-id\": \"$GPEER\", \"allocator-multiaddr\": \"$DEAD_ADDR\""
DAEMON_ENV_BASE="${E2E_DAEMON_ENV:-}"
for n in n1 n2 n3 n4; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
done
for n in n1 n2 n3; do
    case "$n" in n3) presets="$PRESETS_N3" ;; *) presets="$PRESETS_N12" ;; esac
    E2E_DAEMON_ENV="$DAEMON_ENV_BASE $(delivery_rln_presets_env "$presets")"
    export E2E_DAEMON_ENV
    daemon_start "$n" || die "daemon_start $n failed"
    # The allocator client and libp2p are the RLN module's declared
    # dependencies: not loaded here, loaded by logoscore with it.
    daemon_load_modules "$n" liblogos_lez_rln_module liblogos_rln_module delivery_module \
        || die "$n: load-module failed"
done
E2E_DAEMON_ENV="$DAEMON_ENV_BASE $(delivery_rln_presets_env "$PRESETS_N4")"
export E2E_DAEMON_ENV
daemon_start n4 || die "daemon_start n4 failed"
daemon_load_modules n4 liblogos_lez_rln_module liblogos_rln_module delivery_module \
    || die "n4: load-module failed"
for n in n1 n2 n3 n4; do
    assert_deps_loaded "$n"
done

section "wallets"
for n in n1 n2 n3 n4; do
    wallet_open "$n" || die "$n: wallet open failed"
    wallet_sync "$n" >/dev/null || die "$n: wallet sync failed"
done
# n1, n2 and n3 are never funded: every membership they hold came from g.
for n in n1 n2 n3; do
    sv PAYER "$n" "$(wallet_payer "$n")"
    [ "$(wallet_native_balance "$n" "$(gv PAYER "$n")")" = "0" ] || die "$n's payer should start empty"
done
# n4 pays for itself once its allocator fails.
wallet_fund n4 >/dev/null || die_node n4 "funding its payer failed"
sv PAYER n4 "$(wallet_payer n4)"
N4BAL0=$(wallet_native_balance n4 "$(gv PAYER n4)")
say "n4: payer $(gv PAYER n4) holds $N4BAL0 native (the fallback's budget)"

# Usage: delivery_rln_state <node> -> the rlnState value (JSON object)
delivery_rln_state() { node_call "$1" delivery_module rlnState | jres | jval; }
# Usage: mix_conf <tcp_port> [static_peer_maddr] [boot] [plugin]
# [boot]: kadBootstrapNodes names b — the peers the delivery module brings
# libp2p_module up on, with service discovery mounted, which is what the RLN
# module's allocator discovery runs over. [plugin]: pluginKadDiscovery on.
mix_conf() {
    local port="$1" peers="${2:-}" boot="${3:-}" plugin="${4:-}"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"ip-colocation-limit":0,"mix":true,"maxPureLibp2pPeers":100%s%s%s}' \
        "$port" "$CLUSTER_ID" "${peers:+,\"staticnodes\":[\"$peers\"]}" \
        "${boot:+,\"kadBootstrapNodes\":[\"$BADDR/p2p/$BPEER\"]}" \
        "${plugin:+,\"pluginKadDiscovery\":true}"
}
for n in n1 n2 n3 n4; do
    node_watch_start "$n" delivery_module
done
# Usage: node_started_verdict <node>  -> "ok" or the failure the library reported
node_started_verdict() {
    grep -E '"event":"nodeStarted"' "$(gv NODEEVT "${1}_delivery_module")" | tail -1 | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}").get("data", {})
print("ok" if d.get("arg0") is True else (d.get("arg1") or "nodeStarted carried no reason"))'
}
# Usage: assert_allocator_named <node> <multiaddr or "">   "" = discovery alone
assert_allocator_named() {
    local n="$1" state
    state=$(delivery_rln_state "$n") || die "$n: rlnState failed"
    [ "$(printf '%s' "$state" | jfield allocatorDiscover)" = "True" ] \
        || die "$n: rlnState does not report allocator discovery: $state"
    if [ -n "$2" ]; then
        [ "$(printf '%s' "$state" | jfield allocatorPeerId)" = "$GPEER" ] \
            || die "$n: rlnState does not name the allocator: $state"
        [ "$(printf '%s' "$state" | jfield allocatorMultiaddr)" = "$2" ] \
            || die "$n: rlnState names another allocator address: $state"
    else
        [ -z "$(printf '%s' "$state" | jfield allocatorPeerId)" ] \
            || die "$n: rlnState names an allocator the preset did not: $state"
    fi
    [ "$(printf '%s' "$state" | jfield allocatorAuthType)" = "peer-any" ] \
        || die "$n: rlnState's allocator auth type is not peer-any: $state"
}
# Usage: await_both_memberships <node>
await_both_memberships() {
    local n="$1"
    delivery_await_provisioned "$n" "$D" "$RELAY_ID" "${n}_d"
    delivery_await_provisioned "$n" "$M" "$MIX_ID" "${n}_m"
    [ "$(gv MHASH "${n}_d")" != "$(gv MHASH "${n}_m")" ] \
        || die "$n: one membership answers both registries: $(gv MHASH "${n}_d")"
    say "$n: D leaf $(gv LEAF "${n}_d"), M leaf $(gv LEAF "${n}_m")"
}
# Usage: assert_gifted <node> <registry id>
# The RLN module's own line for a membership the DISCOVERED allocator
# granted. The provisioning pass notices the record going active on its own
# 5 s poll, after a state read may already have reported it, so this waits
# a little.
assert_gifted() {
    local _t
    for _t in $(seq 1 12); do
        node_logs "$1" | grep -q "provision $2: allocator $GPEER (discovered) registered a registry-wide membership" && return 0
        sleep 5
    done
    die "$1: no record of the allocator granting its membership on ${2:0:24}… (fell back to funding?)"
}

# ---------- n1, n2: memberships from the allocator ------------------------------
section "n1, n2: createNode alone, both memberships from the discovered allocator"
delivery_node_create n1 "$(mix_conf $(( BASE_PORT + 1 )) "" boot plugin)"
assert_allocator_named n1 ""
await_both_memberships n1
assert_gifted n1 "$D"
assert_gifted n1 "$M"
PEER1=$(delivery_node_start n1 "$EVT_TIMEOUT") || exit 1
[ "$(node_started_verdict n1)" = ok ] || die "n1: the library did not start: $(node_started_verdict n1)"
sv MADDR n1 "/ip4/127.0.0.1/tcp/$(( BASE_PORT + 1 ))/p2p/$PEER1"
delivery_node_create n2 "$(mix_conf $(( BASE_PORT + 2 )) "$(gv MADDR n1)" boot plugin)"
assert_allocator_named n2 ""
await_both_memberships n2
assert_gifted n2 "$D"
assert_gifted n2 "$M"
PEER2=$(delivery_node_start n2 "$EVT_TIMEOUT") || exit 1
[ "$(node_started_verdict n2)" = ok ] || die "n2: the library did not start: $(node_started_verdict n2)"

# ---------- n3: the preset's bootstrap peers, no plugin kademlia, still discovers
section "n3: preset allocator-bootstrap-nodes, no kad in the conf, both memberships from the discovered allocator"
delivery_node_create n3 "$(mix_conf $(( BASE_PORT + 3 )) "$(gv MADDR n1)")"
assert_allocator_named n3 ""
await_both_memberships n3
assert_gifted n3 "$D"
assert_gifted n3 "$M"
for n in n1 n2 n3; do
    [ "$(wallet_native_balance "$n" "$(gv PAYER "$n")")" = "0" ] || die "$n's payer moved: it paid for a membership"
done
PAID=$(( GBAL0 - $(gbal) ))
[ "$PAID" -ge $(( 3 * RATE_LIMIT * PRICE + 3 * M_RATE_LIMIT * PRICE )) ] \
    || die "the allocator paid $PAID, less than six memberships' price"
say "n1, n2 and n3 paid nothing; the allocator paid $PAID for their six memberships"

# ---------- n4: no discovery, the allocator is unreachable, funding is the fallback
section "n4: no bootstrap peers, dead allocator address, funded fallback"
delivery_node_create n4 "$(mix_conf $(( BASE_PORT + 4 )) "$(gv MADDR n1)")"
assert_allocator_named n4 "$DEAD_ADDR"
delivery_await_provisioned n4 "$D" "$RELAY_ID" n4_d
FALLBACK=$(gv FALLBACK n4_d)
[ -n "$FALLBACK" ] || FALLBACK=$(node_logs n4 | grep -m1 "falling back to a funded registration") || FALLBACK=""
[ -n "$FALLBACK" ] || die "n4: nothing recorded why the allocator failed (provisioning.fallback_reason / the module's log)"
case "$FALLBACK" in
    *"$GPEER"*) say "n4: fell back — $FALLBACK" ;;
    *) die "n4: the fallback reason does not name the allocator: $FALLBACK" ;;
esac
node_logs n4 | grep -q "provision $D: registered a registry-wide membership at rate $RATE_LIMIT" \
    || die "n4: no funded registration recorded after the fallback"
N4BAL1=$(wallet_native_balance n4 "$(gv PAYER n4)")
[ "$N4BAL1" -lt "$N4BAL0" ] || die "n4's payer did not pay for its own membership ($N4BAL0 -> $N4BAL1)"
say "n4: funded fallback landed at leaf $(gv LEAF n4_d); its payer paid $(( N4BAL0 - N4BAL1 ))"

# ---------- mesh + send leg (proof-gated Relay on D) ---------------------------
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
    PAYLOAD="allocator presets ping $ATTEMPT from n1"
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

echo
echo "e2e: PASS — the preset's allocator provisioned both memberships by default, funding stayed the fallback (target $E2E_TARGET)"
echo "e2e:   D $D: n1 leaf $(gv LEAF n1_d), n2 leaf $(gv LEAF n2_d), n3 leaf $(gv LEAF n3_d) (preset bootstrap), n4 leaf $(gv LEAF n4_d) (funded fallback)"
echo "e2e:   M $M: n1 leaf $(gv LEAF n1_m), n2 leaf $(gv LEAF n2_m), n3 leaf $(gv LEAF n3_m)"
echo "e2e:   allocator $GPEER paid $PAID; n4 paid $(( N4BAL0 - N4BAL1 ))"
