#!/usr/bin/env bash
# scenarios/delivery-rln-soak — the delivery+RLN message path under sustained
# load, across several RLN epochs, deliberately past the per-epoch budget.
#
# delivery-rln proves the seam's CONTRACT on three messages and breaks on the
# first success. This proves nothing about the contract and everything about
# what the path COSTS: two logos-core nodes, both sending and both validating,
# over enough epochs that each one runs out of slots in each of them.
#
# What it measures (reported, never asserted):
#   - send -> messagePropagated and send -> peer's messageReceived latency,
#     p50/p95/max, per phase and per round. Phase A runs UNDER the budget so
#     there is a clean baseline before any parked task is retrying in the
#     background.
#   - proof-request amplification: generate_proof calls per message.
#   - what becomes of a message the budget refuses.
#
# What it asserts:
#   - the baseline round delivers everything, both ways;
#   - each saturation round spends EXACTLY rate_limit slots per node — the
#     budget is neither over- nor under-spent;
#   - the epoch rolls and the budget refills;
#   - nothing arrives unproven, and no rate_limit_violation appears anywhere.
#
# The overflow's fate is measured, not asserted, because the delivery library
# decides it: admitAndProve stamps the task admitted BEFORE attaching a proof,
# and attachRlnProof derives the epoch from message.timestamp, which
# toWakuMessage fixes once and no retry restamps. So a refused message retries
# the same exhausted epoch once a second until MaxTimeInCache (60s) fails it.
# Whether that is still true is exactly what the over-quota block reports.
#
# Sizing is load-bearing, not taste:
#   - a round's burst must fit inside one epoch, so each round waits for the
#     epoch boundary and fires just past it. ~0.25s per node_call (one
#     logoscore CLI spawn plus a daemon round trip; there is no batch path)
#     puts a 32-send burst at ~8s of a 60s epoch.
#   - the epoch must stay at or under MaxTimeInCache or the overflow dies
#     before the next epoch arrives and "does it recover" is unobservable.
#
# No checkouts required: the flake pins delivery-module at v0.3.0-rc.1 and
# rln-modules/lez-rln at the LEZ v0.2.5-rc3 set, which is the stack this runs
# against. Override with DELIVERY_MODULE_CHECKOUT / LOGOS_DELIVERY_CHECKOUT to
# test an unreleased delivery tree.
#
# Env beyond docs/contract.md:
#   E2E_SOAK_RATE_LIMIT=100       the membership's per-epoch budget. Asked for
#                                 in start()'s config; asserted afterwards.
#                                 100 is the LOCAL REGISTRY'S FLOOR (bounds are
#                                 [100, 600]) — below it register_membership is
#                                 refused, so a cheap round is not on offer.
#   E2E_SOAK_OVERSHOOT=6          sends beyond the budget, per node per round
#   E2E_SOAK_ROUNDS=3             saturation epochs (phase B)
#   E2E_SOAK_EPOCH_SIZE_SEC=      epoch size. Unset derives one from the load
#                                 (a ~100-slot round does not fit the 60s local
#                                 default) and the derived value is what start()
#                                 and the RLN preset are handed.
#   E2E_SOAK_RECV_WAIT_S=30       per-round budget for the peer's receipts
#   E2E_SOAK_WARMUP_ATTEMPTS=4    per-direction tries to get the root windows
#                                 warm before anything is measured
#   E2E_SOAK_DRAIN_S=75           post-run wait for parked tasks to reach a
#                                 terminal state (MaxTimeInCache is 60s)
#   E2E_SOAK_PORT=61980           tcp ports are PORT+1, PORT+2
#   E2E_EVENT_TIMEOUT_S=30        per-event wait budget during bring-up
#   E2E_MESH_WAIT_S=12            gossipsub mesh stabilization pause
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

# 100 is the LOCAL REGISTRY'S FLOOR, not a choice: register_membership is
# refused with "rate_limit N outside registry bounds [100, 600]" below it, so
# a small budget is not available on this deployment and a round is ~100 sends
# per node whether or not that is convenient.
RATE_LIMIT="${E2E_SOAK_RATE_LIMIT:-100}"
OVERSHOOT="${E2E_SOAK_OVERSHOOT:-6}"
ROUNDS="${E2E_SOAK_ROUNDS:-3}"
RECV_WAIT_S="${E2E_SOAK_RECV_WAIT_S:-30}"
DRAIN_S="${E2E_SOAK_DRAIN_S:-75}"
BASE_PORT="${E2E_SOAK_PORT:-61980}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
TOPIC="/logos-rln-e2e/1/delivery-rln-soak/proto"
CLUSTER_ID="198"
NODES_ALL="n1 n2"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_PAYER E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done

[ "$RATE_LIMIT" -gt "$OVERSHOOT" ] \
    || die "E2E_SOAK_RATE_LIMIT ($RATE_LIMIT) must exceed E2E_SOAK_OVERSHOOT ($OVERSHOOT) — the baseline round sends rate_limit-overshoot"
BURST=$(( RATE_LIMIT + OVERSHOOT ))
BASELINE=$(( RATE_LIMIT - OVERSHOOT ))
# A round must fit ENTIRELY inside one epoch: it starts 2s past the boundary,
# spends ~0.25s per send call across two nodes, waits for the budget to read
# empty, then settles for RECV_WAIT_S before reading the quota again. If any of
# that lands in the next epoch the burst straddles a roll, the counter it reads
# is not the counter it spent, and every per-round assertion stops meaning
# anything.
#
# With the registry floor at 100 slots that is ~53s of send calls alone, which
# does not fit the 60s local default — so the epoch is DERIVED from the load
# unless the caller pins one. The scenario owns this number end to end: it is
# what start() and the RLN preset are handed, so raising it here raises it
# everywhere it matters.
BURST_COST_S=$(( (BURST * 2 + 3) / 4 ))
ROUND_COST_S=$(( 2 + BURST_COST_S + RECV_WAIT_S ))
EPOCH="${E2E_SOAK_EPOCH_SIZE_SEC:-}"
if [ -z "$EPOCH" ]; then
    # 30% headroom over the measured-ish round cost, and never below the
    # target's own default.
    EPOCH=$(( ROUND_COST_S * 13 / 10 ))
    [ "$EPOCH" -ge "$E2E_EPOCH_SIZE_SEC" ] || EPOCH="$E2E_EPOCH_SIZE_SEC"
    say "epoch size ${EPOCH}s derived from the load (a round needs ~${ROUND_COST_S}s); \
pin it with E2E_SOAK_EPOCH_SIZE_SEC"
fi
[ "$ROUND_COST_S" -lt "$EPOCH" ] \
    || die "a round needs ~${ROUND_COST_S}s (2s align + ~${BURST_COST_S}s for ${BURST} sends on two nodes \
+ ${RECV_WAIT_S}s settle) but the epoch is only ${EPOCH}s — raise E2E_SOAK_EPOCH_SIZE_SEC, or lower \
E2E_SOAK_RECV_WAIT_S / E2E_SOAK_RATE_LIMIT / E2E_SOAK_OVERSHOOT"
# An epoch longer than the send service's 60s MaxTimeInCache means a refused
# message dies well before its epoch rolls, so this run cannot distinguish
# "never recovers" from "would have recovered next epoch" by outcome alone.
# The epoch-timestamp evidence in the over-quota block still answers it.
[ "$EPOCH" -le 60 ] \
    || say "note: epoch ${EPOCH}s exceeds the library's 60s retry window, so an over-quota \
message dies before its epoch rolls — the recovery question is answered by the epoch timestamps, not by outcome"

SENDS_CSV="$E2E_RUN_DIR/soak-sends.csv"
QUOTA_CSV="$E2E_RUN_DIR/soak-quota.csv"
printf 'phase,round,node,seq,request_id,t_send_ns\n' >"$SENDS_CSV"
printf 'phase,round,node,when,epoch_index,rate_limit,remaining\n' >"$QUOTA_CSV"

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

REGISTRY_ID=$(delivery_registry_id)
RLN_ID=$(delivery_rln_identifier)
say "registry: $REGISTRY_ID"
say "load: rate limit $RATE_LIMIT, burst $BURST/node/round, $ROUNDS saturation rounds, epoch ${EPOCH}s"

# The presets file is how RLN reaches a node since logos-delivery-module#118:
# createNode resolves it, there is no configureRln. Written before any daemon
# starts, because the daemon reads the path off its own command line and the
# file is read at createNode — one that cannot be parsed fails that call rather
# than quietly leaving RLN off.
RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$EPOCH"
E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} $(delivery_rln_presets_env "$RLN_PRESETS_FILE")"
export E2E_DAEMON_ENV

# ---------- daemons ----------------------------------------------------------
section "daemons: RLN stack + delivery_module on both nodes"
# Each node gets a wallet of its OWN before its daemon starts: only the staged
# wallet_config.json is copied, so the module creates a fresh wallet there and
# derives a payer nothing else holds. Copying the staged storage.json instead
# would give every node the same seed and the SAME derived account, and they
# would race one nonce.
for n in $NODES_ALL; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
done
for n in $NODES_ALL; do
    daemon_start "$n" || die "daemon_start $n failed"
    daemon_load_modules "$n" liblogos_lez_rln_module liblogos_rln_module \
        delivery_module || die "$n: load-module failed"
done
NODES_UP=1

# ---------- wallets ----------------------------------------------------------
# BOTH nodes need a ready wallet: the registry reads every validator does go
# through liblogos_lez_rln_module, which owns its wallet in-process. And each
# node pays for its own membership out of its own wallet copy.
section "wallets"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "syncing wallets to chain head $CHAIN_HEAD"
for n in $NODES_ALL; do
    wallet_open "$n" || die_node "$n" "wallet open failed"
    wallet_sync "$n" >/dev/null || die_node "$n" "wallet sync failed"
    wallet_fund "$n" >/dev/null || die_node "$n" "funding its payer failed"
    say "$n: payer $(wallet_payer "$n") holds $(wallet_native_balance "$n") native"
done

# ---------- provisioning -----------------------------------------------------
# The module registers itself. `rate_limit` here is a JSON NUMBER (start()'s
# provisioning rate), unlike register_membership's options array where it is a
# string — and it is the only way to get a small budget, since this scenario
# registers nothing by hand.
section "provisioning at rate $RATE_LIMIT (the module registers itself)"
for n in $NODES_ALL; do
    delivery_prewarm "$n" \
        "{\"epoch_size_sec\":$EPOCH,\"registries\":[\"$REGISTRY_ID\"],\"rate_limit\":$RATE_LIMIT}"
done
for n in $NODES_ALL; do
    delivery_await_provisioned "$n" "$REGISTRY_ID" "$RLN_ID"
done

# The budget we got, not the one we asked for: the burst size and every
# saturation assertion are built on this number.
#
# It also guards an ordering hazard, though only partially at the default rate.
# The preset carries registry-id / rln-identifier / epoch-size-sec and no rate
# limit, so the start createNode fires re-enters provisioning at the MODULE's
# default rate of 100 — harmless only because provision_one short-circuits on a
# live record, which is why delivery_await_provisioned runs first. At
# E2E_SOAK_RATE_LIMIT values other than 100 a broken ordering shows up here as
# a mismatch; AT 100 (the registry floor, and the default) the two rates
# coincide and this check cannot tell them apart. Run once with a rate inside
# (100, 600] if you want that ordering actually proven.
for n in $NODES_ALL; do
    Q=$(delivery_quota "$n" "$REGISTRY_ID" "$RLN_ID" "init_$n")
    RL=$(printf '%s' "$Q" | jfield rate_limit)
    [ "$RL" = "$RATE_LIMIT" ] || die_node "$n" "membership rate_limit is '$RL', want $RATE_LIMIT (quota: ${Q:-<empty>}). \
rate_limit 0 means no usable membership; any other value means provisioning ran at a rate this scenario did not ask for \
— the preset carries no rate_limit, so createNode's start must not be the thing that provisioned."
    say "$n: budget $RL slots/epoch"
done

# ---------- delivery nodes ---------------------------------------------------
section "delivery nodes (rln from the preset, bridge up at createNode)"
for n in $NODES_ALL; do
    node_watch_start "$n" delivery_module
    # node_watch_stop CLEARS NODEEVT on purpose (so a later wait fails loudly
    # rather than polling a dead watcher), so the stream path has to be taken
    # here — the analyzer reads these files after the watchers are down.
    sv EVTFILE "$n" "$(gv NODEEVT "${n}_delivery_module")"
done
delivery_node_up n1 "$(( BASE_PORT + 1 ))" "$CLUSTER_ID" "" "$EVT_TIMEOUT"
delivery_node_up n2 "$(( BASE_PORT + 2 ))" "$CLUSTER_ID" "$(gv MADDR n1)" "$EVT_TIMEOUT"

for n in $NODES_ALL; do
    FAILED=$(node_logs "$n" | grep -m1 "failed to start RLN module\|no usable RLN membership\|could not verify RLN membership") || FAILED=""
    [ -z "$FAILED" ] || die_node "$n" "library failed RLN bring-up: $FAILED"
done

section "mesh"
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
for n in $NODES_ALL; do
    delivery_must_call "$n" subscribe "subscribe" "$TOPIC" >/dev/null
done
say "both nodes subscribed to $TOPIC"
# Both nodes validate here, so both read paths must be warm — unlike
# delivery-rln, where only n2 receives.
for n in $NODES_ALL; do
    delivery_wait_roots_warm "$n" "$REGISTRY_ID"
done

# ---------- the load ---------------------------------------------------------

# Usage: soak_send <phase> <round> <node> <seq>
# Fire one send and record when. The event lines carry a nanosecond timestamp
# as their last arg, so this joins straight against them — the watcher's own
# ISO timestamp field is second-resolution and useless for latency.
soak_send() {
    local phase="$1" round="$2" node="$3" seq="$4" t0 reqid
    t0=$(python3 -c 'import time; print(time.time_ns())')
    reqid=$(delivery_must_call "$node" send "send ($phase r$round s$seq)" "$TOPIC" \
        "$(argfile "pay_${node}_${phase}_${round}_${seq}" "soak $phase r$round s$seq from $node")")
    [ -n "$reqid" ] || die_node "$node" "$phase r$round s$seq: send returned no requestId"
    printf '%s,%s,%s,%s,%s,%s\n' "$phase" "$round" "$node" "$seq" "$reqid" "$t0" >>"$SENDS_CSV"
}

# Usage: soak_quota <phase> <round> <when>
soak_quota() {
    local phase="$1" round="$2" when="$3" n q
    for n in $NODES_ALL; do
        q=$(delivery_quota "$n" "$REGISTRY_ID" "$RLN_ID" "${phase}_${round}_${when}_${n}")
        printf '%s,%s,%s,%s,%s,%s,%s\n' "$phase" "$round" "$n" "$when" \
            "$(printf '%s' "$q" | jfield epoch_index)" \
            "$(printf '%s' "$q" | jfield rate_limit)" \
            "$(printf '%s' "$q" | jfield remaining)" >>"$QUOTA_CSV"
        say "  $n $when r$round: $q"
    done
}

# Sleep to just past the next epoch boundary, so a burst never straddles a roll.
epoch_align() {
    local rem
    rem=$(( EPOCH - $(date +%s) % EPOCH ))
    say "aligning to the next epoch boundary (${rem}s)…"
    sleep $(( rem + 2 ))
}

# Usage: soak_round <phase> <round> <sends_per_node>
soak_round() {
    local phase="$1" round="$2" count="$3" seq t0
    epoch_align
    soak_quota "$phase" "$round" before
    t0=$(date +%s)
    # Interleaved, so both nodes are proving concurrently — the interesting case.
    for seq in $(seq 1 "$count"); do
        soak_send "$phase" "$round" n1 "$seq"
        soak_send "$phase" "$round" n2 "$seq"
    done
    say "$phase round $round: $(( count * 2 )) sends issued in $(( $(date +%s) - t0 ))s"
    # A slot is reserved inside generate_proof, which runs asynchronously behind
    # the send call. Reading the quota at a fixed offset would race the prover
    # and report a budget that is merely not spent YET, so wait for it to read
    # empty instead — and say how long that took, which is the throughput
    # number the whole scenario exists to produce.
    if [ "$count" -gt "$RATE_LIMIT" ]; then
        local deadline spent n rem all_zero
        # An ABSOLUTE deadline measured from the first send, not a remaining
        # duration: the poll has until the round must start settling, and
        # comparing a remaining duration against total elapsed is how this
        # loop first shipped never running at all.
        deadline=$(( EPOCH - RECV_WAIT_S - 5 ))
        spent=""
        while [ $(( $(date +%s) - t0 )) -lt "$deadline" ]; do
            all_zero=1
            for n in $NODES_ALL; do
                rem=$(delivery_quota "$n" "$REGISTRY_ID" "$RLN_ID" "drain_${phase}_${round}_${n}" | jfield remaining)
                [ "${rem:-1}" = "0" ] || all_zero=0
            done
            if [ "$all_zero" = 1 ]; then
                spent=$(( $(date +%s) - t0 ))
                break
            fi
            sleep 3
        done
        if [ -n "$spent" ]; then
            say "$phase round $round: both budgets spent ${spent}s after the first send \
($RATE_LIMIT proofs/node)"
        else
            say "$phase round $round: budgets still not empty ${deadline}s after the first send — \
proving could not keep up with the send rate; the after-quota assertion below will say by how much"
        fi
    fi
    say "$phase round $round: settling ${RECV_WAIT_S}s"
    sleep "$RECV_WAIT_S"
    soak_quota "$phase" "$round" after
    [ $(( $(date +%s) - t0 )) -lt "$EPOCH" ] \
        || say "WARNING: round $round took longer than the ${EPOCH}s epoch — its quota reads straddle a roll"
}

# A freshly provisioned pair has a cold valid-root window on both sides: two
# registrations moved the tree root, and a proof against a root the peer has
# not seen yet comes back `invalid` and the message is dropped. delivery-rln
# absorbs that with a three-attempt send loop; a soak cannot, because its very
# first assertion is that the baseline round loses nothing. So spend a message
# each way here, outside the measurements, until both directions work.
#
# It also takes the first-proof cost (module warm-up) out of the baseline
# latency numbers, which is worth as much as the root window is.
soak_warmup() {
    local attempts="${E2E_SOAK_WARMUP_ATTEMPTS:-4}" dir from to a reqid prop hash ok rem
    for dir in "n1 n2" "n2 n1"; do
        set -- $dir; from="$1"; to="$2"
        ok=0
        for a in $(seq 1 "$attempts"); do
            rem=$(delivery_quota "$from" "$REGISTRY_ID" "$RLN_ID" "warm_${from}_${a}" | jfield remaining)
            # Out of budget here is not the failure under test — roll into a
            # fresh epoch and keep probing the root window.
            [ "${rem:-0}" != "0" ] || { say "warm-up: $from has no slots left; waiting for the next epoch"; epoch_align; }
            local t0
            t0=$(python3 -c 'import time; print(time.time_ns())')
            reqid=$(delivery_must_call "$from" send "warm-up $from->$to ($a)" "$TOPIC" \
                "$(argfile "warm_${from}_${a}" "soak warmup r1 s${a} from ${from}")")
            # Recorded like any other send: the analyzer asserts that nothing
            # arrives which no send in this run published, and warm-up messages
            # are published by this run.
            printf '%s,%s,%s,%s,%s,%s\n' warmup 1 "$from" "$a" "$reqid" "$t0" >>"$SENDS_CSV"
            prop=$(node_wait_event "$from" delivery_module messagePropagated "$EVT_TIMEOUT" "$reqid") || prop=""
            if [ -z "$prop" ]; then
                say "warm-up $from->$to attempt $a: never propagated"
                continue
            fi
            hash=$(printf '%s' "$prop" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
            if node_wait_event "$to" delivery_module messageReceived 15 "$hash" >/dev/null; then
                say "warm-up $from->$to: delivered on attempt $a"
                ok=1
                break
            fi
            say "warm-up $from->$to attempt $a: propagated but not received (root window still cold)"
        done
        [ "$ok" = 1 ] || die "warm-up $from->$to never delivered in $attempts attempts — \
the pair cannot pass a proof-gated message at all, so nothing the soak measures would mean anything"
    done
}

section "warm-up (root windows, outside the measurements)"
soak_warmup

section "phase A — baseline, $BASELINE sends/node (under the $RATE_LIMIT budget)"
soak_round baseline 1 "$BASELINE"

section "phase B — saturation, $ROUNDS rounds of $BURST sends/node (budget $RATE_LIMIT)"
for ROUND in $(seq 1 "$ROUNDS"); do
    soak_round saturation "$ROUND" "$BURST"
done

# Parked tasks fail at MaxTimeInCache (60s) past admission; wait them out so
# every send has a terminal outcome before anything is counted.
section "drain (${DRAIN_S}s — parked tasks reach a terminal state at ~60s)"
sleep "$DRAIN_S"
for n in $NODES_ALL; do
    node_watch_stop "$n" delivery_module
done

# A bridged node answers its own verdicts in-process, so they never reach the
# event stream — but a rate_limit_violation would mean the module reissued a
# slot, and it says so on stderr. Cheap canary for the one failure the event
# join cannot see.
for n in $NODES_ALL; do
    VIOL=$(node_logs "$n" | grep -c "rate_limit_violation") || VIOL=0
    [ "$VIOL" = 0 ] || die_node "$n" "$VIOL rate_limit_violation verdict(s) in the daemon log — \
a slot was reissued, or two members share an identity. generate_proof allocates monotonically and \
never reissues, so this is slot accounting breaking, not spam."
done

# ---------- results ----------------------------------------------------------
section "results"
python3 "$HERE/analyze.py" \
    --sends "$SENDS_CSV" --quota "$QUOTA_CSV" \
    --events "n1=$(gv EVTFILE n1)" \
    --events "n2=$(gv EVTFILE n2)" \
    --rate-limit "$RATE_LIMIT" --epoch-size "$EPOCH" \
    --json "$E2E_RUN_DIR/soak-summary.json" | tee "$E2E_RUN_DIR/soak-summary.txt"
RC=${PIPESTATUS[0]}
[ "$RC" = 0 ] || die "soak assertions failed (rc=$RC) — summary in $E2E_RUN_DIR/soak-summary.txt"

echo
echo "e2e: PASS — delivery-rln-soak (target $E2E_TARGET)"
echo "e2e:   load      2 nodes x ($BASELINE baseline + $ROUNDS x $BURST) sends, budget $RATE_LIMIT/epoch, epoch ${EPOCH}s"
echo "e2e:   data      $SENDS_CSV, $QUOTA_CSV, $E2E_RUN_DIR/soak-summary.{txt,json}"
