#!/usr/bin/env bash
# scenarios/delivery-flagship — the 0.4 release in one run: two registries at
# two epochs, memberships by allocation (pinned and discovered) and by paying,
# and RLN proofs generated and validated on Relay AND through the mixnet.
#
# Topology:
#   b        a bootstrap peer: libp2p_module alone with service discovery
#            mounted — the registrar the allocator's advertisement lands on.
#   g        the allocator: liblogos_lez_rln_module + libp2p_module +
#            rln_gifter_module + rln_auth_module, its own funded payer,
#            serving the delivery registry D and the mix registry M with the
#            peer-any verifier, advertising what it serves.
#   a        delivery node A, FUNDED, the host owns its backend
#            (`manage-backend: false`): D from the allocator (pinned), M paid
#            from its own payer (`allocator: null`). anonymityLevel Required.
#   bb       delivery node B, FUNDED, the mirror: D paid, M from the
#            allocator (pinned). anonymityLevel Required.
#   c1..c3   delivery nodes, never funded, the delivery module owns their
#            backend: the preset names both registries and no allocator, and
#            createNode alone discovers g for both memberships. Relay,
#            lightpush service and Mix mounted: the mix pool A and B need
#            (a path is three hops out of a pool of four others).
#
# What it proves:
#   1. one start names both registries with a per-registry allocator choice:
#      A's D and B's M are granted by g, A's M and B's D are paid by their
#      own payers (the module's provisioning lines, the allocator's spent
#      nullifiers, the payers' balances);
#   2. c1..c3 get both memberships from the discovered allocator and pay
#      nothing;
#   3. all five start with Mix mounted on M at the Mix profile's epoch;
#   4. Relay: c1 sends a proof-gated message A and B both receive (a proof
#      on D from an allocated membership, validated by both);
#   5. Mix: A sends to B and B sends to A with anonymityLevel Required, so
#      the message can only leave through the mixnet: the sender generates a
#      proof on M, every hop validates it and generates its own, and the
#      exit publishes the message — carrying the sender's proof on D — to
#      Relay, where the receiver validates it. Seen as: the receiver's
#      messageReceived, the mix counters (Entry on the sender, Intermediate
#      and Exit across the pool, no spam-proof error) and the sender's spent
#      quota on M;
#   6. A and B spent quota on D too.
#
# Required: DELIVERY_LGX | DELIVERY_MODULE_CHECKOUT (>= 0.3.7), LIBP2P_LGX |
#   LIBP2P_MODULE_CHECKOUT (>= 1.1.0), GIFTER_LGX + AUTH_LGX | GIFTER_CHECKOUT
#   (logos-rln-gifter refactor/auth-vector-pipeline), liblogos_rln_module >=
#   0.15.0 (a per-registry allocator in start).
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100  E2E_MIX_RATE_LIMIT=20  E2E_DELIVERY_RLN_PORT=62400
#   E2E_ALLOC_PORT=62500 (+1, +2: A's and B's libp2p; +8: the bootstrap peer)
#   E2E_EVENT_TIMEOUT_S=30  E2E_MESH_WAIT_S=15  E2E_SEND_ATTEMPTS=3
#   E2E_RECV_WAIT_S=12  E2E_MIX_SEND_ATTEMPTS=5  E2E_MIX_RECV_WAIT_S=25
#   E2E_MIX_READY_TIMEOUT_S=90
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
BASE_PORT="${E2E_DELIVERY_RLN_PORT:-62400}"
GPORT="${E2E_ALLOC_PORT:-62500}"
GADDR="/ip4/127.0.0.1/tcp/$GPORT"
BADDR="/ip4/127.0.0.1/tcp/$(( GPORT + 8 ))"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-15}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-12}"
MIX_SEND_ATTEMPTS="${E2E_MIX_SEND_ATTEMPTS:-5}"
MIX_RECV_WAIT_S="${E2E_MIX_RECV_WAIT_S:-25}"
MIX_READY_TIMEOUT_S="${E2E_MIX_READY_TIMEOUT_S:-90}"
TOPIC_RELAY="/logos-rln-e2e/1/delivery-flagship-relay/proto"
TOPIC_AB="/logos-rln-e2e/1/delivery-flagship-mix-ab/proto"
TOPIC_BA="/logos-rln-e2e/1/delivery-flagship-mix-ba/proto"
META_TOPIC="/mix/1/metadata/proto"
CLUSTER_ID="198"
HOSTED="a bb"
DISCO="c1 c2 c3"
DELIVERY_NODES="$HOSTED $DISCO"
NODES_ALL="b g $DELIVERY_NODES"

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

# Usage: node_port <node>  -> its delivery tcp port
node_port() {
    case "$1" in
        a) echo $(( BASE_PORT + 1 )) ;; bb) echo $(( BASE_PORT + 2 )) ;;
        c1) echo $(( BASE_PORT + 3 )) ;; c2) echo $(( BASE_PORT + 4 )) ;; c3) echo $(( BASE_PORT + 5 )) ;;
    esac
}

# ---------- the two registries -----------------------------------------------
D=$(delivery_registry_id default) || die "no default registry id"
M=$(delivery_registry_id mix) || die "no mix registry id"
D_CFG=$(registry_config_account default) || exit 1
M_CFG=$(registry_config_account mix) || exit 1
[ "$D" != "$M" ] || die "the two registries resolve to one id: $D"
D_HEX="${D##*:}"
M_HEX="${M##*:}"
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

# Usage: disco_node_config <listen multiaddr>  -> a libp2p_module config on b
disco_node_config() {
    printf '{"addrs":["%s"],"transport":"tcp","mountServiceDiscovery":true,"bootstrapNodes":[{"peerId":"%s","addrs":["%s"]}]}' \
        "$1" "$BPEER" "$BADDR"
}

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
# g pays eight registrations and must still hold the fee reserve for the last
# one: a hosted target's per-node amount (1e9) is one registration too short.
G_FUND="${E2E_ALLOCATOR_FUND_AMOUNT:-${E2E_FUND_AMOUNT:-5000000000}}"
[ "$G_FUND" -ge 2000000000 ] || G_FUND=2000000000
wallet_fund g "$G_FUND" >/dev/null || die "funding the allocator's payer never landed"
gbal() { wallet_native_balance g "$GPAYER"; }
GBAL0=$(gbal)
node_call g libp2p_module createNode "$(disco_node_config "$GADDR")" | jres >/dev/null \
    || die "g: libp2p createNode failed"
node_call g libp2p_module start | jres >/dev/null || die "g: libp2p start failed"
GPEER=$(node_call g libp2p_module peerInfo | jres | jval | jfield peerId) || GPEER=""
[ -n "$GPEER" ] || die "g: no peerId"
NULLIFIERS="$E2E_RUN_DIR/allocator-nullifiers"
SERVE=$(jq -cn --arg d "$D_CFG" --arg m "$M_CFG" --arg w "$GPAYER" --arg n "$NULLIFIERS" --argjson r "$RATE_LIMIT" \
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
# with it (declared dependencies, loaded by logoscore).
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
}

# ---------- delivery daemons -------------------------------------------------
section "delivery daemons"
# c1..c3: the preset names both registries and NO allocator; delivery starts
# the backend and the RLN module asks the allocator discovery finds.
PRESETS_DISCO="$E2E_RUN_DIR/rln-presets-disco.json"
delivery_stage_rln_presets "$PRESETS_DISCO" "$D" "$RELAY_ID" "$D_EPOCH" "" \
    "\"rate-limit\": $RATE_LIMIT, \"mix-registry-id\": \"$M\", \"mix-rate-limit\": $M_RATE_LIMIT, \"mix-metadata-topic\": \"$META_TOPIC\""
# A and B: the preset carries D only and hands the backend to the host, whose
# start is the one place a per-registry allocator can be named.
PRESETS_HOST="$E2E_RUN_DIR/rln-presets-host.json"
delivery_stage_rln_presets "$PRESETS_HOST" "$D" "$RELAY_ID" "$D_EPOCH" "" '"manage-backend": false'
DAEMON_ENV_BASE="${E2E_DAEMON_ENV:-}"
for n in $DELIVERY_NODES; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
done
for n in $DELIVERY_NODES; do
    case "$n" in a|bb) presets="$PRESETS_HOST" ;; *) presets="$PRESETS_DISCO" ;; esac
    E2E_DAEMON_ENV="$DAEMON_ENV_BASE $(delivery_rln_presets_env "$presets")"
    export E2E_DAEMON_ENV
    daemon_start "$n" || die "daemon_start $n failed"
    daemon_load_modules "$n" liblogos_lez_rln_module liblogos_rln_module delivery_module \
        || die "$n: load-module failed"
done
for n in $DELIVERY_NODES; do
    assert_deps_loaded "$n"
done

section "wallets"
for n in $DELIVERY_NODES; do
    wallet_open "$n" || die "$n: wallet open failed"
    wallet_sync "$n" >/dev/null || die "$n: wallet sync failed"
    sv PAYER "$n" "$(wallet_payer "$n")"
done
# Usage: payer_balance <node>
payer_balance() { wallet_native_balance "$1" "$(gv PAYER "$1")"; }
for n in $DISCO; do
    [ "$(payer_balance "$n")" = "0" ] || die "$n's payer should start empty"
done
for n in $HOSTED; do
    wallet_fund "$n" >/dev/null || die_node "$n" "funding its payer failed"
    sv BAL0 "$n" "$(payer_balance "$n")"
    say "$n: payer $(gv PAYER "$n") holds $(gv BAL0 "$n") native (one registration ahead)"
done

# Usage: rln_on <node> <method> [args…]  -> the value of a liblogos_rln_module call
rln_on() { local n="$1"; shift; node_call "$n" liblogos_rln_module "$@" | jres | jval; }
# Usage: peer_any_payload <rate>  -> the peer-any auth payload (02 ‖ rate u64 LE), hex
peer_any_payload() { python3 -c 'import struct,sys; print("02" + struct.pack("<Q", int(sys.argv[1])).hex())' "$1"; }
# Usage: pinned_allocator <rate>  -> the allocator block naming g, discovery off
pinned_allocator() {
    printf '{"discover":false,"peer_id":"%s","multiaddr":"%s","auth_type":"peer-any","auth_payload":"%s"}' \
        "$GPEER" "$GADDR" "$(peer_any_payload "$1")"
}
# Usage: host_start <D allocator json|null> <M allocator json|null>
host_start() {
    printf '{"epoch_size_sec":%s,"rate_limit":%s,"registries":[{"registry_id":"%s","allocator":%s},{"registry_id":"%s","epoch_size_sec":%s,"max_epoch_gap":%s,"rate_limit":%s,"allocator":%s}]}' \
        "$D_EPOCH" "$RATE_LIMIT" "$D" "$1" "$M" "$M_EPOCH" "$M_GAP" "$M_RATE_LIMIT" "$2"
}
# On a hosted chain a block takes about a minute and the allocator registers
# on one serialized worker, so requests that arrive together queue behind each
# other past the client's request timeout. There the nodes are provisioned one
# after another; a local chain (1 s blocks) keeps them concurrent.
case "${E2E_TARGET:-local}" in local) SEQUENTIAL="${E2E_SEQUENTIAL_PROVISIONING:-0}" ;; *) SEQUENTIAL="${E2E_SEQUENTIAL_PROVISIONING:-1}" ;; esac
# The module writes its "granted"/"paid" line on its own 5 s poll; the wait
# follows the chain's confirmation budget, never under a minute.
LINE_TRIES=$(( ${E2E_CONFIRM_TIMEOUT_S:-60} / 5 ))
[ "$LINE_TRIES" -ge 12 ] || LINE_TRIES=12
# Usage: await_both_memberships <node>
await_both_memberships() {
    local n="$1"
    delivery_await_provisioned "$n" "$D" "$RELAY_ID" "${n}_d"
    delivery_await_provisioned "$n" "$M" "$MIX_ID" "${n}_m"
    [ "$(gv MHASH "${n}_d")" != "$(gv MHASH "${n}_m")" ] \
        || die "$n: one membership answers both registries: $(gv MHASH "${n}_d")"
    say "$n: D leaf $(gv LEAF "${n}_d"), M leaf $(gv LEAF "${n}_m")"
}
# Usage: assert_granted <node> <registry id> <who>
# <who>: the text between "allocator " and " registered" in the RLN module's
# own line for a granted membership ("$GPEER" pinned, "$GPEER (discovered)").
# The provisioning pass writes it on its own 5 s poll, so this waits a little.
assert_granted() {
    local _t
    for _t in $(seq 1 "$LINE_TRIES"); do
        node_logs "$1" | grep -qF "provision $2: allocator $3 registered a registry-wide membership" && return 0
        sleep 5
    done
    die "$1: no record of the allocator granting its membership on ${2:0:24}… (paid for it instead?)"
}
# Usage: assert_paid <node> <registry id> <rate>
# The module's line for a registration from the node's own payer, and no
# allocator line for that registry.
assert_paid() {
    local _t ok=0
    for _t in $(seq 1 "$LINE_TRIES"); do
        node_logs "$1" | grep -qF "provision $2: registered a registry-wide membership at rate $3" && { ok=1; break; }
        sleep 5
    done
    [ "$ok" = 1 ] || die "$1: no funded registration recorded on ${2:0:24}…"
    node_logs "$1" | grep -qF "provision $2: allocator " \
        && die "$1: an allocator was asked for ${2:0:24}… although its start says allocator null"
    return 0
}

# ---------- A and B: one start, a per-registry allocator choice ----------------
section "A and B: the host starts the backend — one registry allocated, the other paid"
I=0
for n in $HOSTED; do
    I=$(( I + 1 ))
    node_call "$n" libp2p_module createNode "$(disco_node_config "/ip4/127.0.0.1/tcp/$(( GPORT + I ))")" | jres >/dev/null \
        || die "$n: libp2p createNode failed"
    node_call "$n" libp2p_module start | jres >/dev/null || die "$n: libp2p start failed"
done
delivery_prewarm a "$(host_start "$(pinned_allocator "$RATE_LIMIT")" null)"
[ "$SEQUENTIAL" = 1 ] && await_both_memberships a
delivery_prewarm bb "$(host_start null "$(pinned_allocator "$M_RATE_LIMIT")")"
[ "$SEQUENTIAL" = 1 ] && await_both_memberships bb
for n in $HOSTED; do
    PARAMS=$(rln_on "$n" get_registry_parameters "$M" "$(argfile "p_$n" "$MIX_ID")") || PARAMS=""
    [ "$(printf '%s' "$PARAMS" | jfield epoch_size_sec)" = "$M_EPOCH" ] \
        || die "$n: M reports epoch $(printf '%s' "$PARAMS" | jfield epoch_size_sec), want $M_EPOCH: $PARAMS"
done
for n in $HOSTED; do
    [ "$SEQUENTIAL" = 1 ] || await_both_memberships "$n"
done
assert_granted a "$D" "$GPEER"
assert_paid a "$M" "$M_RATE_LIMIT"
assert_paid bb "$D" "$RATE_LIMIT"
assert_granted bb "$M" "$GPEER"
for n in $HOSTED; do
    node_logs "$n" | grep -q "falling back to a funded registration" \
        && die "$n: a registration fell back from the allocator; the split is not the configured one"
    sv BAL1 "$n" "$(payer_balance "$n")"
    [ "$(gv BAL1 "$n")" -lt "$(gv BAL0 "$n")" ] || die "$n's payer did not pay for its own membership ($(gv BAL0 "$n") -> $(gv BAL1 "$n"))"
done
# The allocator spent one credential per registry so far: A's on D, B's on M.
SPENT_D=$(grep -ci "^$D_HEX:peer-any:" "$NULLIFIERS" 2>/dev/null) || SPENT_D=0
SPENT_M=$(grep -ci "^$M_HEX:peer-any:" "$NULLIFIERS" 2>/dev/null) || SPENT_M=0
[ "$SPENT_D" = 1 ] && [ "$SPENT_M" = 1 ] \
    || die "the allocator spent $SPENT_D credential(s) on D and $SPENT_M on M, want 1 and 1: $(cat "$NULLIFIERS" 2>/dev/null)"
PAID_AB=$(( GBAL0 - $(gbal) ))
[ "$PAID_AB" -ge $(( RATE_LIMIT * PRICE + M_RATE_LIMIT * PRICE )) ] \
    || die "the allocator paid $PAID_AB, less than A's D and B's M memberships' price"
say "A: D granted by g, M paid ($(( $(gv BAL0 a) - $(gv BAL1 a) ))); B: D paid ($(( $(gv BAL0 bb) - $(gv BAL1 bb) ))), M granted by g; g paid $PAID_AB"

# ---------- delivery nodes -----------------------------------------------------
# Usage: delivery_rln_state <node> -> the rlnState value (JSON object)
delivery_rln_state() { node_call "$1" delivery_module rlnState | jres | jval; }
# Usage: flag_conf <node> [static_peer_maddr]
# The flat conf (the layered shape mounts Mix without spam protection): Relay,
# the lightpush service a mix exit needs, Mix. A and B name the Mix scope
# themselves (their preset carries D only) and send through Mix alone;
# c1..c3 take the Mix scope from the preset and discover over b.
flag_conf() {
    local n="$1" peers="${2:-}" extra
    case "$n" in
        a|bb) extra=$(printf ',"anonymityLevel":"Required","mix-rln-registry-id":"%s","mix-rln-identifier-hex":"%s","mix-rln-metadata-topic":"%s"' "$M" "$MIX_ID" "$META_TOPIC") ;;
        *) extra=$(printf ',"kadBootstrapNodes":["%s/p2p/%s"],"pluginKadDiscovery":true' "$BADDR" "$BPEER") ;;
    esac
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":true,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"ip-colocation-limit":0,"mix":true,"maxPureLibp2pPeers":100%s%s}' \
        "$(node_port "$n")" "$CLUSTER_ID" "$extra" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}
for n in $DELIVERY_NODES; do
    node_watch_start "$n" delivery_module
done
# Usage: node_started_verdict <node>  -> "ok" or the failure the library reported
node_started_verdict() {
    grep -E '"event":"nodeStarted"' "$(gv NODEEVT "${1}_delivery_module")" | tail -1 | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}").get("data", {})
print("ok" if d.get("arg0") is True else (d.get("arg1") or "nodeStarted carried no reason"))'
}
# Usage: start_node <node>  -> sets MADDR <node>
start_node() {
    local n="$1" peer v
    peer=$(delivery_node_start "$n" "$EVT_TIMEOUT") || exit 1
    v=$(node_started_verdict "$n")
    [ "$v" = ok ] || die "$n: the library did not start: $v"
    node_logs "$n" | grep -q "Mounting mix protocol" || die "$n: Mix was not mounted (mix:true ignored?)"
    sv MADDR "$n" "/ip4/127.0.0.1/tcp/$(node_port "$n")/p2p/$peer"
    say "$n: started with Mix mounted, peer $peer"
}

section "A and B: delivery on the host's backend"
delivery_node_create a "$(flag_conf a)"
start_node a
delivery_node_create bb "$(flag_conf bb "$(gv MADDR a)")"
start_node bb
for n in $HOSTED; do
    if node_wait_event "$n" delivery_module "$(delivery_rln_evt rlnStartRequest)" 2 >/dev/null; then
        die "$n: delivery requested a backend start although the preset says manage-backend false"
    fi
done

section "c1..c3: createNode alone, both memberships from the discovered allocator"
for n in $DISCO; do
    delivery_node_create "$n" "$(flag_conf "$n" "$(gv MADDR a)")"
    STATE=$(delivery_rln_state "$n") || die "$n: rlnState failed"
    [ "$(printf '%s' "$STATE" | jfield mixRegistryId)" = "$M" ] || die "$n: rlnState does not name M as the mix registry: $STATE"
    [ -z "$(printf '%s' "$STATE" | jfield allocatorPeerId)" ] || die "$n: rlnState names an allocator the preset did not: $STATE"
    [ "$SEQUENTIAL" = 1 ] && await_both_memberships "$n"
done
for n in $DISCO; do
    [ "$SEQUENTIAL" = 1 ] || await_both_memberships "$n"
    assert_granted "$n" "$D" "$GPEER (discovered)"
    assert_granted "$n" "$M" "$GPEER (discovered)"
    [ "$(payer_balance "$n")" = "0" ] || die "$n's payer moved: it paid for a membership"
    start_node "$n"
done
PAID=$(( GBAL0 - $(gbal) ))
[ "$PAID" -ge $(( 4 * RATE_LIMIT * PRICE + 4 * M_RATE_LIMIT * PRICE )) ] \
    || die "the allocator paid $PAID, less than eight memberships' price"
say "c1, c2 and c3 paid nothing; the allocator paid $PAID for eight memberships in all"

# ---------- the mix pool --------------------------------------------------------
section "mix pool (every node learns the other four)"
for n in $DELIVERY_NODES; do
    REC=$(delivery_must_call "$n" getLocalMixPeerRecord "mix peer record") || exit 1
    [ -n "$REC" ] || die "$n: empty mix peer record"
    sv MIXREC "$n" "$(argfile "mixrec_$n" "$REC")"
done
for n in $DELIVERY_NODES; do
    for o in $DELIVERY_NODES; do
        [ "$n" = "$o" ] && continue
        delivery_must_call "$n" addMixPeer "addMixPeer $o" "$(gv MIXREC "$o")" >/dev/null
    done
done
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
for n in $DELIVERY_NODES; do
    for t in "$TOPIC_RELAY" "$TOPIC_AB" "$TOPIC_BA"; do
        delivery_must_call "$n" subscribe "subscribe" "$t" >/dev/null
    done
    delivery_wait_roots_warm "$n" "$D"
    delivery_wait_roots_warm "$n" "$M"
done
# anonymityLevel Required reports Disconnected until Mix is usable: the pool
# holds four nodes and a lightpush exit.
for n in $HOSTED; do
    STATUS=""
    for _t in $(seq 1 "$(polls "$MIX_READY_TIMEOUT_S" 3)"); do
        STATUS=$(node_call "$n" delivery_module getConnectionStatus | jres | jval) || STATUS=""
        case "$STATUS" in ""|*Disconnected*) sleep 3 ;; *) break ;; esac
    done
    case "$STATUS" in
        ""|*Disconnected*) die "$n: Mix never became usable (connection status: ${STATUS:-<none>})" ;;
    esac
    say "$n: connection status $STATUS"
done

# Usage: metric_sum <node> <extended regex on the series line>  -> integer sum
metric_sum() {
    node_call "$1" delivery_module getNodeInfo Metrics | jres | jval | python3 -c '
import re, sys
pat = re.compile(sys.argv[1])
total = 0.0
for line in sys.stdin.read().replace("\\n", "\n").splitlines():
    if line.startswith("#") or not pat.search(line):
        continue
    try:
        total += float(line.split()[-1] if not re.search(r"\s\d{10,}$", line) else line.split()[-2])
    except (ValueError, IndexError):
        pass
print(int(total))' "$2"
}
# Usage: pool_metric_sum <regex>  -> the sum over the five delivery nodes
pool_metric_sum() {
    local n total=0
    for n in $DELIVERY_NODES; do
        total=$(( total + $(metric_sum "$n" "$1") ))
    done
    echo "$total"
}
ENTRY='^mix_messages_forwarded(_total)?\{.*type="Entry"'
INTERMEDIATE='^mix_messages_forwarded(_total)?\{.*type="Intermediate"'
EXIT_RECVD='^mix_messages_recvd(_total)?\{.*type="Exit"'
SPAM_ERRORS='^mix_messages_error(_total)?\{.*error="SPAM_'

# ---------- relay leg -----------------------------------------------------------
section "relay leg (c1 -> A and B, proof-gated on D)"
RECEIVED=0
ATTEMPT=0
while [ "$ATTEMPT" -lt "$SEND_ATTEMPTS" ]; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    REQID=$(delivery_must_call c1 send "send (attempt $ATTEMPT)" "$TOPIC_RELAY" "$(argfile "relay_$ATTEMPT" "flagship relay ping $ATTEMPT from c1")")
    [ -n "$REQID" ] || die "send returned no requestId"
    PROP=$(node_wait_event c1 delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") || {
        node_wait_event c1 delivery_module messageError 1 "$REQID" >/dev/null \
            && die "messageError for requestId $REQID — library: $(node_logs c1 | grep -m1 'usable RLN membership\|Failed to verify RLN membership\|Failed to attach RLN proof' || echo 'see c1 daemon log')"
        die "no messagePropagated for requestId $REQID within ${EVT_TIMEOUT}s"
    }
    MSGHASH=$(printf '%s' "$PROP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
    [ -n "$MSGHASH" ] || die "messagePropagated carried no messageHash: $PROP"
    if node_wait_event a delivery_module messageReceived "$RECV_WAIT_S" "$MSGHASH" >/dev/null \
        && node_wait_event bb delivery_module messageReceived "$RECV_WAIT_S" "$MSGHASH" >/dev/null; then
        RECEIVED=1
        say "attempt $ATTEMPT: A and B received c1's proof-gated relay message"
        break
    fi
    say "attempt $ATTEMPT: not received on both (fresh-root window?) — retrying with a fresh message"
    sleep 3
done
[ "$RECEIVED" = 1 ] || die "A and B never both received a proof-gated relay message in $SEND_ATTEMPTS attempts"

# ---------- mix legs ------------------------------------------------------------
# Usage: mix_leg <sender> <receiver> <topic>
# The sender is anonymityLevel Required: the message leaves through Mix or not
# at all. The mixed round trip has a short reply budget, so the sender may
# report an error for a message the exit did publish: arrival is the verdict.
mix_leg() {
    local s="$1" r="$2" topic="$3" attempt=0 reqid ts q spent=0 entry0 inter0 exit0 entry inter exit_n errs
    entry0=$(metric_sum "$s" "$ENTRY")
    inter0=$(pool_metric_sum "$INTERMEDIATE")
    exit0=$(pool_metric_sum "$EXIT_RECVD")
    while :; do
        attempt=$(( attempt + 1 ))
        [ "$attempt" -le "$MIX_SEND_ATTEMPTS" ] \
            || die "$r never received a message $s sent through Mix in $MIX_SEND_ATTEMPTS attempts — $s: $(node_logs "$s" | grep -E 'Mix lightpush timed out|MixSendProcessor.sendImpl failed|fewer than 4 usable mix nodes|Spam protection' | tail -3)"
        ts=$(date +%s)
        reqid=$(delivery_must_call "$s" send "mix send (attempt $attempt)" "$topic" "$(argfile "mix_${s}_$attempt" "flagship mix ping $attempt from $s")")
        [ -n "$reqid" ] || die "send returned no requestId"
        if node_wait_event "$r" delivery_module messageReceived "$MIX_RECV_WAIT_S" "$topic" >/dev/null; then
            say "attempt $attempt: $r received the message $s sent through Mix"
            break
        fi
        say "attempt $attempt: nothing on $r within ${MIX_RECV_WAIT_S}s — retrying with a fresh message"
    done
    if node_wait_event "$s" delivery_module messagePropagated 8 "$reqid" >/dev/null; then
        say "$s: the exit's reply came back (messagePropagated for $reqid)"
    else
        say "$s: no reply from the exit within its budget for $reqid (the message arrived)"
    fi
    # The sender's proof on M counts against the epoch the send fell in.
    for q in "$ts" $(( ts + M_EPOCH )) $(( ts - M_EPOCH )); do
        [ "$(delivery_quota "$s" "$M" "$MIX_ID" "q_${s}_$q" "$q" | jfield remaining)" -lt "$M_RATE_LIMIT" ] && { spent=1; break; }
    done
    [ "$spent" = 1 ] || die "$s: no quota spent on M around the send (no proof generated on the mix tree?)"
    entry=$(( $(metric_sum "$s" "$ENTRY") - entry0 ))
    inter=$(( $(pool_metric_sum "$INTERMEDIATE") - inter0 ))
    exit_n=$(( $(pool_metric_sum "$EXIT_RECVD") - exit0 ))
    errs=$(pool_metric_sum "$SPAM_ERRORS")
    [ "$entry" -ge 1 ] || die "$s: no packet entered the mixnet (mix_messages_forwarded Entry +$entry)"
    [ "$inter" -ge 2 ] || die "fewer than two hops forwarded $s's packet (mix_messages_forwarded Intermediate +$inter): a hop's proof check did not pass"
    [ "$exit_n" -ge 1 ] || die "no exit accepted $s's packet (mix_messages_recvd Exit +$exit_n)"
    [ "$errs" = 0 ] || die "$errs spam-proof error(s) counted across the pool (mix_messages_error SPAM_*)"
    say "$s -> $r: entry +$entry, intermediate +$inter, exit +$exit_n, spam-proof errors 0; $s spent quota on M"
}
section "mix leg A -> B (a proof per hop on M, the message's proof on D)"
mix_leg a bb "$TOPIC_AB"
section "mix leg B -> A"
mix_leg bb a "$TOPIC_BA"
for n in $DELIVERY_NODES; do
    BAD=$(node_logs "$n" | grep -m1 "Spam protection verification failed\|Failed to generate spam protection proof") || BAD=""
    [ -z "$BAD" ] || die "$n: a mix proof failed: $BAD"
done

# ---------- quotas on D ---------------------------------------------------------
section "quotas"
# The proofs on D count against the epoch each send fell in. The sends above
# finished within the last D epoch, so the epoch before this one is read too:
# a read just after a boundary sees a fresh quota for the current epoch.
NOW=$(date +%s)
for n in $HOSTED; do
    QD=$(delivery_quota "$n" "$D" "$RELAY_ID" "${n}_qd" "$NOW")
    [ "$(printf '%s' "$QD" | jfield rate_limit)" = "$RATE_LIMIT" ] || die "$n: no usable membership on D: $QD"
    if [ "$(printf '%s' "$QD" | jfield remaining)" -ge "$RATE_LIMIT" ]; then
        QPREV=$(delivery_quota "$n" "$D" "$RELAY_ID" "${n}_qd_prev" "$(( NOW - D_EPOCH ))")
        [ "$(printf '%s' "$QPREV" | jfield remaining)" -lt "$RATE_LIMIT" ] \
            || die "$n: nothing spent on D in this epoch or the one before: $QD / $QPREV"
        QD="$QPREV"
    fi
    say "$n: D remaining $(printf '%s' "$QD" | jfield remaining)/$RATE_LIMIT"
done

echo
echo "e2e: PASS — memberships by allocation and by paying on two registries; proofs generated and validated on Relay and through Mix (target $E2E_TARGET)"
echo "e2e:   A: D leaf $(gv LEAF a_d) (allocated, pinned), M leaf $(gv LEAF a_m) (paid)"
echo "e2e:   B: D leaf $(gv LEAF bb_d) (paid), M leaf $(gv LEAF bb_m) (allocated, pinned)"
echo "e2e:   c1..c3: D leaves $(gv LEAF c1_d) $(gv LEAF c2_d) $(gv LEAF c3_d), M leaves $(gv LEAF c1_m) $(gv LEAF c2_m) $(gv LEAF c3_m) (allocated, discovered)"
echo "e2e:   allocator $GPEER paid $PAID; relay c1 -> A,B; mix A -> B and B -> A"
