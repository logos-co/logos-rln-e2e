#!/usr/bin/env bash
# scenarios/delivery — RLN-gated message delivery between two
# logos-delivery-module nodes, driven entirely through the Messaging API.
#
# Each node registers its own membership on the same registry through the RLN
# module (the `register` scenario's path, run twice), hands the delivery module
# that membership through `configureRln`, then comes up as a real node:
#
#   per node: open wallet -> sync -> fresh holding -> claim_tokens (faucet)
#     -> register -> poll get_membership_state to "active"
#     -> delivery_module.configureRln(registry-id, rln-identifier)
#     -> createNode -> start
#   then: B dials A (A's multiaddr as an entry node) -> both subscribe
#     -> warm both RLN root windows -> quota snapshot on A -> A.send
#     -> B sees messageReceived
#     -> quota snapshot on A again: remaining decremented by one
#
# What it proves that the producer repos' own suites cannot: the delivery
# library's RLN plugin, the module's bridge, and a real on-chain membership
# compose — a node whose membership is active mounts RLN, sends a message that
# a second RLN node accepts, and the send is billed against the sender's
# on-chain rate limit.
#
# Topology: both peers dial a logos-docker container and meet there, which is
# how they find each other on a fleet. The relay mounts RLN too and validates
# the proof on every message it forwards, so it registers a membership of its
# own on the same registry, under the same rln identifier — three memberships,
# three faucet claims. `entry-node` takes plain multiaddrs, which the conf
# builder turns into static nodes and dials at start (logos-delivery
# tools/confutils/cli_args.nim). E2E_BOOTSTRAP=none peers the two directly
# instead, the setup proven by logos-delivery-interop-tests (S06) and the
# delivery module's own e2e suite; E2E_BOOTSTRAP_RLN=0 keeps the relay blind,
# which separates "the relay dropped it" from "the receiver did".
#
# Config shape: the layered `{mode, preset, messagingOverrides}` shape, with an
# empty preset — the Messaging API on an arbitrary network rather than a named
# one. A bare top-level WakuNodeConf key (even `logLevel`) would drop the whole
# config into the legacy flat parser, which pins every node to tcp/60000.
#
# Target-agnostic: chain, deployment, funding mode and every poll budget arrive
# through the harness contract (docs/contract.md).
#
# Cost: two registrations at rate_limit x price_per_unit, each from its own
# fresh faucet claim.
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100       per-node registration rate limit
#   E2E_CLUSTER_ID=198       test cluster (isolated from any real network)
#   E2E_TCP_PORT_BASE=61100  node n's TCP port is base+n
#   E2E_RECEIVE_TIMEOUT_S=60 budget for the receiver's messageReceived
#   E2E_CONFIGURE_RLN_TIMEOUT_S=180  budget for configureRln to report
#   E2E_RLN_IDENTIFIER       the app-scope rln identifier both nodes share
#                            (64 hex; a fresh random one per run by default)
#   E2E_BOOTSTRAP=docker     both peers meet at a logos-docker relay; `none`
#                            peers them directly instead (harness/lib/bootstrap.sh
#                            carries the container knobs)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain bootstrap; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
CLUSTER_ID="${E2E_CLUSTER_ID:-198}"
TCP_PORT_BASE="${E2E_TCP_PORT_BASE:-61100}"
RECEIVE_TIMEOUT_S="${E2E_RECEIVE_TIMEOUT_S:-60}"
CONFIGURE_RLN_TIMEOUT_S="${E2E_CONFIGURE_RLN_TIMEOUT_S:-180}"
CONTENT_TOPIC="/test/1/logos-rln-e2e-delivery/proto"
PAYLOAD="logos rln delivery e2e"
SENDER=n1
RECEIVER=n2
# ONE identifier for both nodes. The rln identifier scopes the application, not
# the member: it goes into the external nullifier both sides derive, so peers
# that do not share it can never validate each other's proofs — each node still
# registers its own membership (own credential, own leaf) under it. Fresh per
# run so a re-run never reuses a spent epoch budget.
RLN_IDENTIFIER="${E2E_RLN_IDENTIFIER:-$(openssl rand -hex 32)}"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
          E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_POLL_INTERVAL_S" -ge 1 ] 2>/dev/null || die "E2E_POLL_INTERVAL_S must be a positive integer"
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — this scenario registers both nodes over the faucet-paid Register path; pick a faucet deployment"

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

# Call a delivery_module method and print its value. The module's methods are
# synchronous and answer a StdLogosResult, whose value is empty on success for
# most of them — so the success flag, not the value, is what says it worked.
dm_call() {
    local node="$1" meth="$2"; shift 2
    local raw
    raw=$(node_call "$node" delivery_module "$meth" "$@" | jres) || raw=""
    case "$raw" in
        *'"success":true'*) printf '%s' "$raw" | jval ;;
        *) die_node "$node" "delivery_module.$meth failed: ${raw:-<empty>}" ;;
    esac
}

BOOTSTRAP_MODE="${E2E_BOOTSTRAP:-docker}"

cleanup() { daemon_stop_all; bootstrap_down; }
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

# ---------- membership: the register scenario's path, once per node ----------
# Leaves the node's rln identifier in RLNID/<node>.
register_node() {
    local node="$1" holding bounds price claim rlnid reg state state_json leaf _t

    section "$node: membership"
    daemon_start "$node" || die "daemon_start $node failed"
    daemon_load_modules "$node" lez_core liblogos_lez_rln_module \
        liblogos_rln_module delivery_module || die "$node: load-module failed"

    wallet_open "$node" || die_node "$node" "wallet open failed"
    wallet_sync "$node" >/dev/null || die_node "$node" "wallet sync failed"

    holding=$(wallet_fresh_holding "$node") || holding=""
    [ -n "$holding" ] || die_node "$node" "no unused holding account"
    say "$node: holding $holding"

    bounds=$(node_call "$node" liblogos_lez_rln_module get_registry_bounds \
        "$(argfile "cfg-$node" "$E2E_CONFIG_ACCOUNT")" | jres) || bounds=""
    [ -n "$bounds" ] || die_node "$node" "get_registry_bounds failed (rln module up?)"
    price=$(printf '%s' "$bounds" | jfield price_per_unit)
    [ -n "$price" ] || die_node "$node" "no price_per_unit in bounds: $bounds"
    claim=$(( RATE_LIMIT * price * 2 ))
    say "$node: claiming $claim RLNTOK from the faucet"
    node_call "$node" liblogos_lez_rln_module claim_tokens \
        "$(argfile "cfg2-$node" "$E2E_CONFIG_ACCOUNT")" "$(argfile "hold-$node" "$holding")" "$claim" \
        | jres >/dev/null || die_node "$node" "claim_tokens failed"
    wait_balance "$node" "$holding" "$claim" >/dev/null \
        || die_node "$node" "faucet credit never landed (want $claim)"

    # No unlock_keystore: the module runs its own auto-unlock at init
    # (full-lazy custody, all platforms) and self-provisions a secret for a
    # fresh store. Passing a password of our own would only fight that.
    rlnid="$RLN_IDENTIFIER"
    sv RLNID "$node" "$rlnid"
    # RegistryOptions on the wire is an ARRAY of {"key","value"} string pairs
    # (char* pairs in the C type), not an object — rate_limit included.
    say "$node: register_membership(rate $RATE_LIMIT)"
    reg=$(node_call "$node" liblogos_rln_module register_membership \
        "$REGISTRY_ID" "$(argfile "rlnid-$node" "$rlnid")" \
        "$(argfile "regopts-$node" "[{\"key\":\"rate_limit\",\"value\":\"$RATE_LIMIT\"},{\"key\":\"funding_holding_account_id\",\"value\":\"$holding\"}]")" | jres) || reg=""
    case "$reg" in
        *'"state":"pending"'*) ;;
        *) die_node "$node" "register_membership failed: ${reg:-<empty>}" ;;
    esac

    say "$node: polling get_membership_state to active (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
    state=""
    for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        state_json=$(node_call "$node" liblogos_rln_module get_membership_state \
            "$REGISTRY_ID" "$(argfile "rlnid2-$node" "$rlnid")" | jres) || state_json=""
        state=$(printf '%s' "$state_json" | jfield state)
        case "$state" in
            active|grace_period) break ;;
            failed) die_node "$node" "registration FAILED: $state_json" ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    case "$state" in
        active|grace_period) ;;
        *) die_node "$node" "membership never became active (last state: ${state:-<none>})" ;;
    esac
    leaf=$(printf '%s' "$state_json" | jfield leaf_index)
    say "$node: membership $state at leaf $leaf"
}

# ---------- the delivery node -----------------------------------------------
# configureRln installs the library's RLN plugin and starts the RLN backend; it
# must precede createNode, which is what reads the installed plugin.
start_delivery_node() {
    local node="$1" index="$2" peer="${3:-}" rlnid cfg entry

    section "$node: delivery node"
    rlnid=$(gv RLNID "$node")
    [ -n "$rlnid" ] || die "start_delivery_node: $node has no membership"

    # logosctl's transport deadline is a fixed 20 s with no CLI override, and
    # configureRln outlives it: it warms the registry root window over the
    # chain. The client's RPC_FAILED therefore says nothing about the module,
    # so fire and forget, then wait for the module's own verdict in the log.
    node_call "$node" delivery_module configureRln \
        "{\"registry-id\":\"$REGISTRY_ID\",\"rln-identifier\":\"$rlnid\",\"epoch-size-sec\":$E2E_EPOCH_SIZE_SEC}" \
        >/dev/null 2>&1 || true
    local _t verdict=""
    for _t in $(seq 1 "$(polls "$CONFIGURE_RLN_TIMEOUT_S" 5)"); do
        if node_logs "$node" | grep -q "rln served in-process"; then verdict=ok; break; fi
        if node_logs "$node" | grep -q "rln bridge unavailable"; then verdict=nobridge; break; fi
        if node_logs "$node" | grep -q "rln module start failed"; then verdict=nostart; break; fi
        sleep 5
    done
    case "$verdict" in
        ok) ;;
        nobridge) die_node "$node" "configureRln installed the plugin but the RLN bridge did not come up — nothing would answer the library's RLN requests" ;;
        nostart) die_node "$node" "configureRln could not start the RLN backend" ;;
        *) die_node "$node" "configureRln never reported within ${CONFIGURE_RLN_TIMEOUT_S}s" ;;
    esac
    say "$node: RLN configured on $REGISTRY_ID"

    entry=""
    [ -n "$peer" ] && entry=",\"entry-node\":[\"$peer\"]"
    cfg=$(cat <<JSON
{"mode":"core","preset":"","messagingOverrides":{
  "log-level":"DEBUG","listen-address":"127.0.0.1",
  "tcp-port":$(( TCP_PORT_BASE + index )),
  "cluster-id":$CLUSTER_ID,"num-shards-in-network":1,
  "store":false$entry}}
JSON
)
    dm_call "$node" createNode "$(argfile "nodecfg-$node" "$cfg")" >/dev/null
    dm_call "$node" start >/dev/null
    say "$node: node started on tcp $(( TCP_PORT_BASE + index ))"
}

# The first dialable multiaddr the node advertises.
node_maddr() {
    local node="$1" raw
    raw=$(dm_call "$node" getNodeInfo MyMultiaddresses)
    printf '%s' "$raw" | python3 -c '
import re, sys
raw = sys.stdin.read().strip().strip("@[]\"")
for part in re.split(r"[,\n]", raw):
    part = part.strip().strip("\"")
    if part.startswith("/"):
        print(part.replace("/ip4/0.0.0.0/", "/ip4/127.0.0.1/"))
        break
'
}

# Poll a node's RLN valid-root window warm: validate_proof serves from the local
# window only and answers not_ready until the registry read lands. A cold
# window on the receiver looks exactly like a lost message — it would Ignore
# the sender's proof — so gate the send on both nodes being warm. The probe
# proof spends one of the probed node's own message_id slots, which is why the
# sender's quota is snapshotted after this and not before.
warm_root_window() {
    local node="$1" rlnid sig ts proof verify _t
    rlnid=$(gv RLNID "$node")
    sig=$(printf 'root window probe' | to_hex)
    # One timestamp for both calls: each derives the proof's epoch from the
    # caller's clock, and validate_proof rejects a proof from another epoch.
    ts=$(date +%s)
    proof=$(node_call "$node" liblogos_rln_module generate_proof \
        "$REGISTRY_ID" "$(argfile "warmid-$node" "$rlnid")" "$(argfile "warmsig-$node" "$sig")" \
        "str:$ts" | jres | jval) || proof=""
    case "$proof" in
        *'"nullifier"'*) ;;
        *) die_node "$node" "generate_proof failed while warming the root window: ${proof:-<empty>}" ;;
    esac
    sv PROOFROOT "$node" "$(printf '%s' "$proof" | jfield root)"
    for _t in $(seq 1 "$(polls "$E2E_ROOT_WINDOW_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        verify=$(node_call "$node" liblogos_rln_module validate_proof \
            "$REGISTRY_ID" "$(argfile "warmid2-$node" "$rlnid")" "$(argfile "warmsig2-$node" "$sig")" \
            "str:$ts" "$(argfile "warmproof-$node" "$proof")" | jres | jval) || verify=""
        case "$verify" in
            *'"verdict":"valid"'*) say "$node: root window warm"; return 0 ;;
            *'"verdict":"invalid"'*) die_node "$node" "validate_proof rejected the node's own fresh proof: $verify" ;;
            *not_ready*) say "  $node: root window still cold ($_t)"; sleep "$E2E_POLL_INTERVAL_S" ;;
            *) die_node "$node" "validate_proof failed: ${verify:-<empty>}" ;;
        esac
    done
    die_node "$node" "root window never warmed within ${E2E_ROOT_WINDOW_TIMEOUT_S}s"
}

# The node's budget in the current epoch, into EPOCH_<label> / REMAINING_<label>.
# Assigns rather than prints: a failure inside $(…) would only kill the subshell.
read_quota() {
    local node="$1" label="$2" q epoch remaining
    q=$(node_call "$node" liblogos_rln_module get_epoch_quota \
        "$REGISTRY_ID" "$(argfile "quota-$node-$label" "$(gv RLNID "$node")")" \
        "str:$(date +%s)" | jres | jval) || q=""
    epoch=$(printf '%s' "$q" | jfield epoch_index)
    remaining=$(printf '%s' "$q" | jfield remaining)
    case "$epoch$remaining" in
        ''|*[!0-9]*) die_node "$node" "get_epoch_quota gave no numeric epoch/remaining: ${q:-<empty>}" ;;
    esac
    sv EPOCH "$label" "$epoch"
    sv REMAINING "$label" "$remaining"
}

register_node "$SENDER"
register_node "$RECEIVER"

# Topology: both peers meet at a logos-docker bootstrap relay rather than
# dialing each other, which is how they will actually find each other on a
# fleet. E2E_BOOTSTRAP=none falls back to direct peering — worth keeping, since
# it is what isolates a delivery fault from a bootstrap one.
if [ "$BOOTSTRAP_MODE" = docker ]; then
    section "bootstrap"
    bootstrap_up "$CLUSTER_ID" 1 "$REGISTRY_ID" "$RLN_IDENTIFIER" "$RATE_LIMIT"
    PEER=$(bootstrap_multiaddr)
    start_delivery_node "$SENDER" 1 "$PEER"
    start_delivery_node "$RECEIVER" 2 "$PEER"
else
    start_delivery_node "$SENDER" 1
    PEER=$(node_maddr "$SENDER")
    case "$PEER" in
        /ip4/*) say "sender multiaddr: $PEER" ;;
        *) die_node "$SENDER" "no dialable multiaddr from getNodeInfo: ${PEER:-<empty>}" ;;
    esac
    start_delivery_node "$RECEIVER" 2 "$PEER"
fi

# ---------- send + receive ---------------------------------------------------
section "delivery"
for _n in "$SENDER" "$RECEIVER"; do
    dm_call "$_n" subscribe "$CONTENT_TOPIC" >/dev/null
done
say "both nodes subscribed to $CONTENT_TOPIC; letting the mesh settle"
sleep 12

# Warm both: the sender proves, the receiver validates, and neither can do it
# from a cold window.
warm_root_window "$SENDER"
warm_root_window "$RECEIVER"

# A warm window is not an AGREED one. Each node warms against its own
# membership, but the receiver validates the SENDER's proof, so it has to hold
# the root that proof commits to. The two registered moments apart and the tree
# moved between them; for a root a warm window happens to miss the module
# answers "invalid" rather than not_ready, asks for one out-of-band refresh and
# expects the caller to retry. Gate the send on the receiver actually holding
# the sender's root, so that a rejection past this point is a real one.
await_root_agreement() {
    local root roots _t
    root=$(gv PROOFROOT "$SENDER")
    [ -n "$root" ] || die "sender's probe proof carried no root"
    for _t in $(seq 1 "$(polls "$E2E_ROOT_WINDOW_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        roots=$(node_call "$RECEIVER" liblogos_rln_module get_valid_roots "$REGISTRY_ID" | jres | jval) || roots=""
        case "$roots" in
            *"$root"*) say "receiver holds the sender's root ${root:0:16}…"; return 0 ;;
        esac
        say "  receiver's window misses the sender's root ($_t)"
        sleep "$E2E_POLL_INTERVAL_S"
    done
    say "WARNING: receiver never picked up the sender's root ${root:0:16}… — sending anyway"
    say "  receiver roots: ${roots:-<none>}"
}
await_root_agreement

read_quota "$SENDER" before
EPOCH_BEFORE=$(gv EPOCH before)
REMAINING_BEFORE=$(gv REMAINING before)
say "sender quota before: remaining $REMAINING_BEFORE/$RATE_LIMIT in epoch $EPOCH_BEFORE"

node_watch "$RECEIVER" received delivery_module messageReceived
REQ=$(dm_call "$SENDER" send "$CONTENT_TOPIC" "$(argfile payload "$PAYLOAD")")
[ -n "$REQ" ] || die_node "$SENDER" "send returned an empty requestId"
say "sent (requestId $REQ), awaiting messageReceived on $RECEIVER (budget ${RECEIVE_TIMEOUT_S}s)…"

if ! EVENT=$(node_await received "$RECEIVE_TIMEOUT_S" "$CONTENT_TOPIC"); then
    say "watched event stream on $RECEIVER:"
    cat "$(gv WATCHOUT received)" >&2 || true
    die_node "$RECEIVER" "no messageReceived for $CONTENT_TOPIC within ${RECEIVE_TIMEOUT_S}s"
fi
node_watch_stop received
say "received: $EVENT"

# The payload rides as base64 under arg2._bytes; a decoder that disagrees with
# the library's wire format yields empty bytes rather than an error, so assert
# the bytes made the trip rather than just the topic.
GOT=$(printf '%s' "$EVENT" | python3 -c '
import base64, json, sys
d = json.load(sys.stdin).get("data", {})
b = d.get("arg2")
if isinstance(b, dict):
    b = b.get("_bytes", "")
try:
    print(base64.b64decode(b + "=" * (-len(b) % 4)).decode("utf-8", "replace"))
except Exception:
    print("")
')
[ "$GOT" = "$PAYLOAD" ] || die_node "$RECEIVER" "payload mismatch: got '${GOT}', sent '$PAYLOAD'"
say "payload verified: $GOT"

# ---------- the quota the send spent ----------------------------------------
section "rln quota"
read_quota "$SENDER" after
EPOCH_AFTER=$(gv EPOCH after)
REMAINING_AFTER=$(gv REMAINING after)
if [ "$EPOCH_AFTER" = "$EPOCH_BEFORE" ]; then
    [ "$REMAINING_AFTER" = "$(( REMAINING_BEFORE - 1 ))" ] \
        || die "quota remaining $REMAINING_AFTER != $(( REMAINING_BEFORE - 1 )) after one send"
    say "epoch quota: $REMAINING_BEFORE -> $REMAINING_AFTER in epoch $EPOCH_AFTER"
else
    # The epoch rolled mid-run: a fresh epoch's budget says nothing about the
    # send, so assert only that the sender still has a quota to read.
    say "epoch rolled mid-send (before $EPOCH_BEFORE, after $EPOCH_AFTER) — quota assertion skipped, remaining $REMAINING_AFTER"
fi

echo
echo "e2e: PASS — RLN-gated delivery on $REGISTRY_ID"
echo "e2e:   sender    $SENDER (rln $(gv RLNID "$SENDER" | cut -c1-16)…)"
echo "e2e:   receiver  $RECEIVER (rln $(gv RLNID "$RECEIVER" | cut -c1-16)…)"
echo "e2e:   topic     $CONTENT_TOPIC"
echo "e2e:   quota     $REMAINING_BEFORE -> $REMAINING_AFTER (epoch $EPOCH_AFTER)"
