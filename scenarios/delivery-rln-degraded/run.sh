#!/usr/bin/env bash
# scenarios/delivery-rln-degraded — a node that boots while the sequencer is
# unreachable, and what happens when the chain comes back.
#
# Opening the LEZ wallet is a chain read: wallet_ffi_open builds the sequencer
# client, which calibrates every configured endpoint and then drops any it has
# no statistics for, so on a fresh home an unreachable sequencer leaves no
# leader and the open fails outright. That used to be terminal — one failure
# latched Readiness::Failed, nothing re-armed it, and liblogos_rln_module's
# provisioning pass treats "failed" as a verdict and records Refused for the
# life of the process. The node came up, looked healthy, and never registered
# a membership again however healthy the chain became.
#
# What this asserts, in order:
#   1. the fault really lands — the node's reads reach the proxy and are refused
#   2. under it the wallet reads `pending` WITH A REASON, and stays pending for
#      the dwell: never `failed`, which is the bug this pins
#   3. lifting the fault is enough on its own — no restart, no second start
#      call: the wallet reaches ready
#   4. and the node then finishes the job it used to abandon: the module
#      provisions a membership that goes active on chain
#   5. and delivery comes up on it, RLN Ready from the preset
#
# Step 2 fails on an unfixed module stack — the wallet is `failed` within
# seconds — which is the point: run it against the old modules first, or a
# green result says nothing.
#
# Only THIS node is degraded. harness/lib/fault.sh rewrites its
# wallet_config.json to dial the proxy, while the harness keeps reading the
# sequencer directly, so chain_head and funding still work during the outage.
#
# Env beyond docs/contract.md:
#   E2E_DEGRADED_DWELL_S=45   how long to hold the outage while checking that
#                             the wallet stays pending rather than latching
#   E2E_DEGRADED_PORT=61884   delivery tcp port
#   E2E_FAULT_PORT=3141       the proxy's port (harness/lib/fault.sh)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain delivery fault; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
BASE_PORT="${E2E_DEGRADED_PORT:-61884}"
DWELL_S="${E2E_DEGRADED_DWELL_S:-45}"
WITH_DELIVERY="${E2E_DEGRADED_DELIVERY:-1}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
CLUSTER_ID="198"
NODE=n1

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_PAYER E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done

NODES_UP=0
DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ "$NODES_UP" = 1 ]; then
        DYING=1
        echo "---- $NODE log tail ----" >&2
        node_logs "$NODE" 40 >&2 || true
        if [ -s "$(fault_trace_path)" ]; then
            echo "---- fault proxy trace tail ----" >&2
            tail -15 "$(fault_trace_path)" >&2 || true
        fi
    fi
    exit 1
}
cleanup() {
    fault_down
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving the node up, state in $E2E_RUN_DIR"
        return
    fi
    [ "$NODES_UP" = 1 ] && daemon_stop_all
}
trap cleanup EXIT

REGISTRY_ID=$(delivery_registry_id)
RLN_ID=$(delivery_rln_identifier)
say "registry: $REGISTRY_ID (rate $RATE_LIMIT)"

# RLN arrives through the node's preset, the upstream door since
# logos-delivery-module#118: the conf carries no rln-* key. Only the delivery
# leg reads it, so it is staged only when that leg runs.
if [ "$WITH_DELIVERY" = 1 ]; then
    RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
    delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC"
    E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} $(delivery_rln_presets_env "$RLN_PRESETS_FILE")"
    export E2E_DAEMON_ENV
fi

# ---------- the outage, in place before the node exists ----------------------
section "fault: the sequencer refuses this node's connections"
fault_up
# The home must exist before its config can be rewritten, and the rewrite must
# land before daemon_start: the module reads the home from the daemon's
# environment at load and an existing wallet_config.json is authoritative over
# LEZ_RLN_SEQUENCER, so this file is the only thing that re-points the wallet.
daemon_self_paying "$NODE" "$E2E_RUN_DIR/wallet-$NODE"
fault_point_node "$NODE"
fault_mode refuse

if [ "$WITH_DELIVERY" = 1 ]; then
    section "daemon: RLN stack + delivery_module, started into the outage"
else
    section "daemon: the RLN stack, started into the outage"
fi
daemon_start "$NODE" || die "daemon_start $NODE failed"
NODES_UP=1
if [ "$WITH_DELIVERY" = 1 ]; then
    daemon_load_modules "$NODE" liblogos_lez_rln_module liblogos_rln_module \
        delivery_module || die "$NODE: load-module failed"
else
    daemon_load_modules "$NODE" liblogos_lez_rln_module liblogos_rln_module \
        || die "$NODE: load-module failed"
    say "E2E_DEGRADED_DELIVERY=0: RLN stack only, no delivery leg"
fi

# start() is what sets provisioning going: it records the registries this node
# will prove against and hands them to the provisioning pass. On a delivery node
# the library makes this call; with the delivery leg off the scenario has to,
# and it belongs HERE, inside the outage, because that is the sequence a real
# node hits — boot, start RLN, and the chain is not there. It is also the only
# way this run exercises the provisioning pass's own wallet wait, which is the
# second half of the fix.
say "n1: start(registries=[$REGISTRY_ID], rate=$RATE_LIMIT) — during the outage"
START=$(node_call "$NODE" liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"],\"rate_limit\":$RATE_LIMIT}" \
    | jres | jval) || START=""
case "$START" in
    *'"started":true'*) say "n1: start returned started:true even with the chain unreachable" ;;
    *) die "n1: start failed during the outage: ${START:-<empty>}
  start must not depend on the chain — it dispatches provisioning and returns." ;;
esac

# ---------- 1. the fault landed ---------------------------------------------
# Asserted rather than assumed: every other assertion below is vacuous if the
# node was quietly talking to the real sequencer all along.
section "the outage is real"
REFUSED=0
for _t in $(seq 1 12); do
    REFUSED=$(awk '$3 == "refuse" {n++} END {printf "%d", n+0}' "$(fault_trace_path)")
    [ "$REFUSED" -gt 0 ] && break
    sleep 5
done
[ "$REFUSED" -gt 0 ] \
    || die "the node made no refused request in 60s — the fault never landed, so nothing below would mean anything. Check that $NODE's wallet_config.json points at $E2E_FAULT_URL"
say "$NODE: $REFUSED chain requests refused at the proxy — the outage is reaching the module"
# The harness is NOT degraded: it reads the sequencer directly, which is what
# lets it fund and observe during an outage it induced.
chain_head >/dev/null || die "the harness lost its own view of the chain — only the node should be degraded"
say "harness still sees chain head $(chain_head) on $E2E_SEQUENCER"

# ---------- 2. pending, with a reason, and it stays that way -----------------
# The distinction is the whole fix: "pending" means keep waiting, "failed"
# means waiting cannot help, and liblogos_rln_module's provisioning pass
# abandons a registry for the life of the process on "failed". An unreachable
# sequencer is an outage, not a verdict.
section "the wallet waits instead of giving up (budget ${DWELL_S}s)"
DETAIL=""
DWELL_T0=$(date +%s)
while [ $(( $(date +%s) - DWELL_T0 )) -lt "$DWELL_S" ]; do
    ST=$(node_call "$NODE" liblogos_lez_rln_module wallet_status | jres) || ST=""
    case "$ST" in
        *'"state":"failed"'*)
            die "the wallet latched FAILED under an unreachable sequencer: $ST
  This is the defect this scenario pins. A failed wallet is terminal: ensure.rs
  records Refused and never re-enters, so the node will not register even after
  the chain returns. Expected 'pending' with the open error as its detail." ;;
        *'"state":"ready"'*)
            die "the wallet reports READY while every request is being refused: $ST" ;;
        *'"state":"pending"'*)
            DETAIL=$(printf '%s' "$ST" | jfield detail) ;;
        '') ;;  # the module not answering calls yet — early, and worth waiting
        *) die "$NODE: unexpected wallet_status: $ST" ;;
    esac
    # The provisioning pass's own view. `refused` is the other half of the
    # defect: it means the pass read the wallet, took "failed" for a verdict and
    # abandoned this registry for the life of the process.
    PROV=$(node_call "$NODE" liblogos_rln_module get_membership_state \
        "$REGISTRY_ID" "$(argfile "st_$NODE" "$RLN_ID")" | jres | jfield provisioning) || PROV=""
    case "$PROV" in
        *refused*)
            die "provisioning already gave up while the chain was merely unreachable: '$PROV'
  ensure.rs recorded Refused, and it only ever re-enters from start(), so this
  node would never register again even once the chain returned." ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
say "n1: provisioning parked at '${PROV:-<none>}', not refused"
[ -n "$DETAIL" ] \
    || die "the wallet never reported a pending state in ${DWELL_S}s — expected 'pending' naming the open failure"
say "$NODE: wallet still pending after ${DWELL_S}s, detail: $DETAIL"
case "$DETAIL" in
    *"opening the wallet"*|*"sequencer"*|*"no handle"*) ;;
    *) die "the pending detail does not say what it is waiting on: '$DETAIL'" ;;
esac
say "$NODE: the detail names the failure, so an operator can tell this from a slow sync"

# ---------- 3. lifting the outage is enough, on its own ---------------------
section "recovery: the chain comes back and nothing else happens"
fault_mode pass
# wallet_ready branches on state exactly as a consumer should — it waits on
# pending and dies on failed — so reaching ready here IS the recovery
# assertion. Nothing restarts the daemon and nothing calls start again.
wallet_ready "$NODE" || die "$NODE: the wallet never recovered after the outage lifted"
say "$NODE: wallet ready — recovered unattended, no restart and no second start call"

# ---------- 4. and it finishes the job it used to abandon --------------------
section "provisioning after the outage"
# The one thing the module cannot do for itself: no program mints native
# balance. Everything after this is the module's own work.
# Deliberately NOT wallet_fund. That helper transfers and then waits for the
# payer to hold the FULL amount — which assumes nothing spends it meanwhile.
# Here something does: this node's provisioning pass has been parked at
# awaiting_funding since start(), so it prices the registration and submits it
# the moment the balance lands. The balance then never reads back at the full
# amount and the wait times out against a node that is working perfectly. It
# was observed at ~4.93e9 of 5e9, the difference being the registration the
# wait was there to enable.
#
# (delivery-rln's E2E_FUND_LATE path calls wallet_fund in exactly this position
# and carries the same race; it wins on timing rather than by construction.)
#
# The membership going active below is the stronger evidence anyway: it proves
# the transfer arrived AND that the money was usable for what it was sent for.
PAYER=$(wallet_payer "$NODE") || die_node "$NODE" "no payer to fund"
FUND_AMOUNT="${E2E_FUND_AMOUNT:-5000000000}"
say "$NODE: funding its payer $PAYER with $FUND_AMOUNT native"
wallet_fund_account "$PAYER" "$FUND_AMOUNT"
delivery_await_provisioned "$NODE" "$REGISTRY_ID" "$RLN_ID"
say "$NODE: payer holds $(wallet_native_balance "$NODE") native after paying for the membership"
# The read path is what a validator needs and the first thing an outage takes
# away: a cold root window makes every validate_proof answer not_ready, which
# delivery turns into Ignore — a silently dropped message. Asserted here rather
# than in the delivery leg because it is the RLN module's own read path.
delivery_wait_roots_warm "$NODE" "$REGISTRY_ID"

# ---------- 5. a working delivery node on top of it -------------------------
if [ "$WITH_DELIVERY" = 1 ]; then
    section "delivery bring-up on the recovered node"
    node_watch_start "$NODE" delivery_module
    PORT=$(( BASE_PORT + 1 ))
    CFG=$(printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true}' \
        "$PORT" "$CLUSTER_ID")
    delivery_must_call "$NODE" createNode "createNode" "$(argfile "cfg_$NODE" "$CFG")" >/dev/null
    delivery_wait_rln_ready "$NODE"
    delivery_must_call "$NODE" start "start (dispatch)" >/dev/null
    node_wait_event "$NODE" delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
        || die "$NODE: no nodeStarted within ${EVT_TIMEOUT}s"
    say "$NODE: delivery up on 127.0.0.1:$PORT with RLN Ready from the preset"
else
    say "delivery leg skipped (E2E_DEGRADED_DELIVERY=0) — everything above is the"
    say "RLN module stack's own behavior, which is where the defect and fix live"
fi

# ---------- what it cost in RPC ---------------------------------------------
# Not an assertion. A count per method is the amplification baseline worth
# having before anything points at a hosted endpoint with rate limits and a
# cold-start latency measured in seconds.
section "chain RPC this run made through the proxy"
awk '{n[$2]++} END {for (m in n) printf "e2e:   %-34s %d\n", m, n[m]}' \
    "$(fault_trace_path)" | sort -k3 -rn
say "total chain requests: $(fault_trace_count) (trace: $(fault_trace_path))"

section "PASS"
say "delivery-rln-degraded: the node booted into an unreachable sequencer, waited"
say "instead of giving up, and recovered unattended into a registered, RLN-Ready"
say "delivery node once the chain came back."
