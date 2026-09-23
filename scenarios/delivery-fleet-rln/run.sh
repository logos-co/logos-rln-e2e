#!/usr/bin/env bash
# scenarios/delivery-fleet-rln — a fleet of validating relays, run for as long
# as you ask it to.
#
# Three containerised relays, each holding its OWN membership and validating
# every proof it forwards, and two host endpoints that meet only at the fleet.
# The endpoints never dial each other and they dial DIFFERENT relays, so a
# message crosses the fleet to arrive: r1 --- r2 --- r3, n1 on r1, n2 on r3.
# That makes the fleet load-bearing rather than incidental — a relay that
# stops validating, or starts rejecting, shows up as delivery stopping.
#
# What delivery-relay-rln already proves, on one relay and three messages, is
# the CONTRACT: that a relay validates, that a witness cannot hijack the
# verdict. What this proves is that the arrangement KEEPS WORKING: the same
# path, driven at a steady rate for E2E_FLEET_DURATION_S, across enough RLN
# epochs that every membership's budget refills repeatedly and every relay's
# root window goes stale and refreshes under traffic.
#
# The interesting failures are the ones that need time: a root window that
# stops refreshing, a membership that expires mid-run, a slow leak in the
# proof path, a relay that drifts out of the mesh and never rejoins.
#
# What it asserts:
#   - all five nodes provision a membership and reach rlnState Ready;
#   - every send is accepted and carries a proof;
#   - the delivered fraction stays at or above E2E_FLEET_MIN_DELIVERY (a
#     gossipsub mesh is allowed the occasional miss; a path that has stopped
#     working is not);
#   - the sender's epoch budget refills — i.e. the run really did cross epochs.
#
# What it reports:
#   - send -> receive latency over the whole run, p50/p95/max, and per-epoch
#     so drift is visible rather than averaged away;
#   - per-relay validate counts, which is how you see the fleet sharing work.
#
# Needs the relay image (published RLN modules inside):
#     bash tools/build-e2e-image.sh
#
# Env beyond docs/contract.md:
#   E2E_FLEET_RELAYS=3          containerised relays
#   E2E_FLEET_DURATION_S=1800   how long to send for, after bring-up
#   E2E_FLEET_SEND_INTERVAL_S=5 seconds between sends
#   E2E_FLEET_RECV_WAIT_S=15    per-message budget for the receiver's receipt
#   E2E_FLEET_MIN_DELIVERY=95   percent of sends that must arrive
#   E2E_FLEET_PORT=61990        endpoint tcp ports are PORT+1, PORT+2
#   E2E_RELAY_PORT=61890        first relay's port; the others take the next up
#   E2E_EVENT_TIMEOUT_S=30      per-event wait during bring-up
#   E2E_MESH_WAIT_S=12          gossipsub mesh stabilization pause
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain relay delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RELAYS="${E2E_FLEET_RELAYS:-3}"
DURATION_S="${E2E_FLEET_DURATION_S:-1800}"
SEND_INTERVAL_S="${E2E_FLEET_SEND_INTERVAL_S:-5}"
RECV_WAIT_S="${E2E_FLEET_RECV_WAIT_S:-15}"
MIN_DELIVERY="${E2E_FLEET_MIN_DELIVERY:-95}"
BASE_PORT="${E2E_FLEET_PORT:-61990}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
TOPIC="/logos-rln-e2e/1/delivery-fleet/proto"
CLUSTER_ID="198"
SENDER=n1
RECEIVER=n2
ENDPOINTS="$SENDER $RECEIVER"

FLEET=""
_i=1
while [ "$_i" -le "$RELAYS" ]; do
    FLEET="$FLEET r$_i"
    _i=$(( _i + 1 ))
done
FLEET="${FLEET# }"
ALL_NODES="$FLEET $ENDPOINTS"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_PAYER E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
command -v docker >/dev/null || die "delivery-fleet-rln needs docker for the relay fleet"
[ "$RELAYS" -ge 1 ] || die "E2E_FLEET_RELAYS must be at least 1"

SENDS_CSV="$E2E_RUN_DIR/fleet-sends.csv"
printf 'seq,epoch_index,request_id,message_hash,t_send_ns,t_recv_ns,delivered\n' >"$SENDS_CSV"

NODES_UP=0
DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ "$NODES_UP" = 1 ]; then
        DYING=1
        local n
        for n in $ALL_NODES; do
            echo "---- $n log tail ----" >&2
            node_logs "$n" 25 >&2 || true
        done
    fi
    exit 1
}
# A container's log dies with the container, and daemon_stop_all removes them
# — so what the fleet did is gone exactly when a failure makes it interesting.
# Copy each relay's log into the run dir first; it is the only record of what
# a relay forwarded, validated or dropped.
save_relay_logs() {
    local r
    for r in $FLEET; do
        docker logs "$(relay_name "$r")" > "$E2E_RUN_DIR/relay-$r.log" 2>&1 || true
    done
    say "relay logs saved to $E2E_RUN_DIR/relay-*.log"
}
cleanup() {
    [ "$NODES_UP" = 1 ] && save_relay_logs
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving the fleet up, state in $E2E_RUN_DIR"
        return
    fi
    [ "$NODES_UP" = 1 ] && daemon_stop_all
}
trap cleanup EXIT

REGISTRY_ID=$(delivery_registry_id)
RLN_ID=$(delivery_rln_identifier)
say "registry: $REGISTRY_ID"
say "fleet: $RELAYS validating relays, endpoints $SENDER -> $RECEIVER"
say "load: one send every ${SEND_INTERVAL_S}s for ${DURATION_S}s (epoch ${E2E_EPOCH_SIZE_SEC}s)"

# One scope for the whole fleet. Staged before any daemon starts: it reaches
# each node as an env var on its own command line, and createNode is what reads
# it. The relay containers see the same file — the run dir is mounted at the
# same absolute path.
# The relays dial each other, which the default bridge cannot carry: their
# ports are published on the host's loopback and 127.0.0.1 inside a container
# is that container. A shared network gives them name-based addressing
# (relay_maddr_internal); the host endpoints still reach them the published way.
E2E_RELAY_NETWORK="${E2E_RELAY_NETWORK:-e2e-fleet}"
export E2E_RELAY_NETWORK

RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC"
E2E_RLN_PRESETS_FILE="$RLN_PRESETS_FILE"   # relay.sh passes this into the containers
export E2E_RLN_PRESETS_FILE
E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} $(delivery_rln_presets_env "$RLN_PRESETS_FILE")"
export E2E_DAEMON_ENV

# ---------- the fleet --------------------------------------------------------
section "fleet: $RELAYS relays, each validating what it forwards"
for r in $FLEET; do
    relay_up "$r"
    daemon_load_modules "$r" liblogos_lez_rln_module liblogos_rln_module \
        delivery_module || die_node "$r" "load-module failed"
done
NODES_UP=1

# ---------- the endpoints ----------------------------------------------------
section "endpoints"
for n in $ENDPOINTS; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
done
for n in $ENDPOINTS; do
    daemon_start "$n" || die "daemon_start $n failed"
    daemon_load_modules "$n" liblogos_lez_rln_module liblogos_rln_module \
        delivery_module || die_node "$n" "load-module failed"
done

# ---------- wallets and memberships -----------------------------------------
# Five memberships: a relay provisions by exactly the same three calls an
# endpoint does, which is the seam the container node exists to keep honest.
section "wallets and memberships (5 nodes)"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "chain head $CHAIN_HEAD"
for n in $ALL_NODES; do
    wallet_ready "$n" || die_node "$n" "wallet never became ready"
    wallet_fund "$n" >/dev/null || die_node "$n" "funding its payer failed"
    say "$n: payer $(wallet_payer "$n") funded"
done
for n in $ALL_NODES; do
    delivery_prewarm "$n" \
        "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}"
done
for n in $ALL_NODES; do
    delivery_await_provisioned "$n" "$REGISTRY_ID" "$RLN_ID"
    say "$n: membership at leaf $(gv LEAF "$n")"
done

# ---------- topology ---------------------------------------------------------
# r1 is the fleet's own meeting point; r2..rN dial it, and the endpoints dial
# the ends of the chain so a message crosses the fleet rather than arriving
# from the relay it was handed to.
section "topology: r1 <- fleet, $SENDER -> r1, $RECEIVER -> r$RELAYS"
# Only the endpoints are watched: events come from the host binary talking to
# a host daemon, and a relay's daemon lives in a container. What each relay
# did is read from its own log instead (node_logs), which is where the
# validate counts below come from.
for n in $ENDPOINTS; do
    node_watch_start "$n" delivery_module
done

relay_cfg() {
    local port="$1" peers="$2"
    # listenAddress 0.0.0.0: from inside a container 127.0.0.1 is the
    # container, and a relay that cannot be dialled back is not a relay.
    printf '{"logLevel":"INFO","listenAddress":"0.0.0.0","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true%s}' \
        "$port" "$CLUSTER_ID" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

HUB=""
for r in $FLEET; do
    delivery_must_call "$r" createNode "$r createNode" \
        "$(argfile "cfg_$r" "$(relay_cfg "$(relay_port "$r")" "$HUB")")" >/dev/null
    delivery_wait_rln_ready "$r"
    delivery_must_call "$r" start "$r start" >/dev/null
    # No nodeStarted wait here: the event stream is a host-daemon facility and
    # this node is a container. relay_maddr's getNodeInfo is the confirmation
    # — it answers only once the node is up, and its peer id is needed anyway.
    # Two addresses per relay, and they are not interchangeable: MADDR is the
    # host's view, for the endpoints; HUB is what the next relay dials.
    sv MADDR "$r" "$(relay_maddr "$r")"
    say "$r: $(gv MADDR "$r") (peers reach it at $(relay_maddr_internal "$r"))"
    [ -n "$HUB" ] || HUB=$(relay_maddr_internal "$r")
done

LAST_RELAY=$(printf '%s\n' $FLEET | tail -1)
delivery_node_up "$SENDER"   "$(( BASE_PORT + 1 ))" "$CLUSTER_ID" "$(gv MADDR r1)" "$EVT_TIMEOUT"
delivery_node_up "$RECEIVER" "$(( BASE_PORT + 2 ))" "$CLUSTER_ID" "$(gv MADDR "$LAST_RELAY")" "$EVT_TIMEOUT"

for n in $ALL_NODES; do
    delivery_must_call "$n" subscribe "$n subscribe" "$TOPIC" >/dev/null
done
say "all $((RELAYS + 2)) nodes subscribed to $TOPIC"
# AFTER subscribing, not before: a peer joins the topic's mesh only once it has
# subscribed, and a message published into a mesh with no peer in it goes
# nowhere — with RLN that also means no proof is ever requested for it.
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"

# Every relay validates, so every relay's read path must be warm before the
# first send — a cold window answers not_ready and the message is dropped
# rather than forwarded.
for r in $FLEET; do
    delivery_wait_roots_warm "$r" "$REGISTRY_ID"
done
delivery_wait_roots_warm "$RECEIVER" "$REGISTRY_ID"

# ---------- the run ----------------------------------------------------------
section "sending for ${DURATION_S}s"
QUOTA_FIRST=$(delivery_quota "$SENDER" "$REGISTRY_ID" "$RLN_ID" "first")
say "$SENDER quota at start: $QUOTA_FIRST"
EPOCH_FIRST=$(printf '%s' "$QUOTA_FIRST" | jfield epoch_index)

SEQ=0
SENT=0
DELIVERED=0
PROVEN=0
EPOCHS_SEEN="$EPOCH_FIRST"
START_S=$(date +%s)
DEADLINE_S=$(( START_S + DURATION_S ))

while [ "$(date +%s)" -lt "$DEADLINE_S" ]; do
    SEQ=$(( SEQ + 1 ))
    T0=$(python3 -c 'import time; print(time.time_ns())')
    REQID=$(delivery_must_call "$SENDER" send "send $SEQ" "$TOPIC" \
        "$(argfile "pay_$SEQ" "fleet $SEQ from $SENDER")")
    [ -n "$REQID" ] || die_node "$SENDER" "send $SEQ returned no requestId"
    SENT=$(( SENT + 1 ))

    # A send that cost no proof is a send the rate limit did not touch.
    if node_wait_event "$SENDER" delivery_module \
        "$(delivery_rln_evt rlnGenerateProofRequest)" "$EVT_TIMEOUT" >/dev/null; then
        PROVEN=$(( PROVEN + 1 ))
    fi

    PROP=$(node_wait_event "$SENDER" delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") || PROP=""
    if [ -z "$PROP" ]; then
        ERR=$(node_wait_event "$SENDER" delivery_module messageError 1 "$REQID") || ERR=""
        [ -z "$ERR" ] || die_node "$SENDER" "send $SEQ failed: $ERR"
        die_node "$SENDER" "send $SEQ: no messagePropagated within ${EVT_TIMEOUT}s"
    fi
    HASH=$(printf '%s' "$PROP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("arg1",""))') || HASH=""

    T1=""
    GOT=0
    if [ -n "$HASH" ] \
        && node_wait_event "$RECEIVER" delivery_module messageReceived "$RECV_WAIT_S" "$HASH" >/dev/null; then
        T1=$(python3 -c 'import time; print(time.time_ns())')
        GOT=1
        DELIVERED=$(( DELIVERED + 1 ))
    fi

    Q=$(delivery_quota "$SENDER" "$REGISTRY_ID" "$RLN_ID" "s$SEQ")
    EPOCH=$(printf '%s' "$Q" | jfield epoch_index)
    case " $EPOCHS_SEEN " in *" $EPOCH "*) ;; *) EPOCHS_SEEN="$EPOCHS_SEEN $EPOCH" ;; esac
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$SEQ" "$EPOCH" "$REQID" "$HASH" "$T0" "${T1:-}" "$GOT" >>"$SENDS_CSV"

    if [ $(( SEQ % 12 )) -eq 0 ]; then
        say "  $SEQ sends, $DELIVERED delivered, epoch $EPOCH, $(( DEADLINE_S - $(date +%s) ))s left"
    fi
    sleep "$SEND_INTERVAL_S"
done

# ---------- verdict ----------------------------------------------------------
section "results"
save_relay_logs
[ "$SENT" -gt 0 ] || die "no sends were made — check E2E_FLEET_DURATION_S"
PCT=$(( DELIVERED * 100 / SENT ))
EPOCH_COUNT=$(printf '%s\n' $EPOCHS_SEEN | wc -w | tr -d ' ')

python3 - "$SENDS_CSV" <<'PY'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
lat = [(int(r["t_recv_ns"]) - int(r["t_send_ns"])) / 1e6
       for r in rows if r["delivered"] == "1" and r["t_recv_ns"]]
if not lat:
    print("e2e:   latency  no delivered messages to measure")
    raise SystemExit
lat.sort()
def pct(p):
    return lat[min(len(lat) - 1, int(len(lat) * p / 100))]
print(f"e2e:   latency  send -> received  n={len(lat)}  "
      f"p50 {pct(50):.1f}  p95 {pct(95):.1f}  max {max(lat):.1f}  min {min(lat):.1f} ms")
by_epoch = {}
for r in rows:
    if r["delivered"] == "1" and r["t_recv_ns"]:
        ms = (int(r["t_recv_ns"]) - int(r["t_send_ns"])) / 1e6
        by_epoch.setdefault(r["epoch_index"], []).append(ms)
for epoch in sorted(by_epoch):
    v = sorted(by_epoch[epoch])
    print(f"e2e:     epoch {epoch}  n={len(v):3d}  p50 {v[len(v)//2]:.1f} ms")
PY

# What each relay carried. Not a validation count: at the relay's log level a
# proof check leaves no per-message line, and this scenario does not assert
# that a relay validates — delivery-relay-rln does, with a witness responder
# that proves an external answer cannot hijack the verdict. What these numbers
# show is that every relay was on the path rather than one carrying it all.
for r in $FLEET; do
    N=$(grep -c 'Message received' "$E2E_RUN_DIR/relay-$r.log" 2>/dev/null || true)
    say "  $r: saw ${N:-0} messages"
done

[ "$PROVEN" -eq "$SENT" ] \
    || die "only $PROVEN of $SENT sends asked for a proof — a send that costs no proof is ungated"
[ "$PCT" -ge "$MIN_DELIVERY" ] \
    || die "delivered $DELIVERED/$SENT (${PCT}%), below E2E_FLEET_MIN_DELIVERY=${MIN_DELIVERY}%"
[ "$EPOCH_COUNT" -ge 2 ] \
    || die "the run stayed inside one epoch ($EPOCH_FIRST) — it cannot show a budget refilling. \
Raise E2E_FLEET_DURATION_S past the ${E2E_EPOCH_SIZE_SEC}s epoch"

say ""
say "delivery-fleet-rln PASS — $RELAYS validating relays, $SENT sends over ${DURATION_S}s"
say "  delivery   $DELIVERED/$SENT (${PCT}%), every send proved"
say "  epochs     $EPOCH_COUNT crossed ($EPOCHS_SEEN) — the budget refilled"
say "  path       $SENDER -> r1 -> … -> r$RELAYS -> $RECEIVER, endpoints never dialled each other"
say "  data       $SENDS_CSV"
