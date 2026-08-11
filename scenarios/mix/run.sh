#!/usr/bin/env bash
# scenarios/mix — 5-node mixnet with per-hop RLN spam protection (the
# logos-delivery mix stack, PINS.env), membership pre-provisioned ON-CHAIN:
#
#   build stack -> generate credentials + plugin tree (host-side identities)
#   -> register the same commitments, in tree order, through
#      liblogos_lez_rln_module.register_member on the target's deployment
#   -> ASSERT the plugin tree root is a valid on-chain root   <- the point
#   -> launch 5 wakunode2 mix nodes on those credentials
#   -> cover-traffic window (cover emission exercises per-hop RLN
#      continuously; no interactive client needed)
#   -> verdict: per-node metrics table + no rejected messages
#
# The chain is only touched at provision time (static membership): the nodes
# themselves prove/verify against their local tree copy, whose root the
# scenario has pinned to the registry.
#
# Env beyond docs/contract.md:
#   E2E_MIX_RUNTIME_S     cover-traffic window (default 120)
#   E2E_MIX_RATE_LIMIT    per-member rate limit (default 100 = registry min;
#                         keep a multiple of 4 — R/(1+L) cover math)
#   E2E_MIX_LOG_LEVEL     node log level (default INFO)
#   LOGOS_DELIVERY_CHECKOUT / MIX_REBUILD   see lib/stack.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done
# shellcheck source=/dev/null
. "$HERE/lib/stack.sh"
# shellcheck source=/dev/null
. "$HERE/lib/nodes.sh"
# shellcheck source=/dev/null
. "$HERE/lib/chain_register.sh"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done

REG_NODE=reg
NODE_UP=0
cleanup() {
    mix_nodes_stop
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: state in $E2E_RUN_DIR"
        return
    fi
    [ "$NODE_UP" = 1 ] && daemon_stop "$REG_NODE"
}
trap cleanup EXIT

# ---------- stack + credentials ---------------------------------------------
section "mix stack"
mix_stack_checkout
mix_stack_build
mix_tool_build
CREDS="$E2E_RUN_DIR/mix/creds"
mix_creds_setup "$CREDS"

# ---------- chain: register the membership set ------------------------------
section "on-chain membership"
daemon_start "$REG_NODE" || die "daemon_start failed"
NODE_UP=1
daemon_load_modules "$REG_NODE" logos_execution_zone liblogos_lez_rln_module \
    || die "load-module failed"
wallet_open "$REG_NODE"
say "syncing wallet"
wallet_sync "$REG_NODE" >/dev/null || die "wallet sync failed"
mix_chain_register "$REG_NODE" "$CREDS"
daemon_stop "$REG_NODE"
NODE_UP=0

# ---------- the mixnet -------------------------------------------------------
section "mixnet"
mix_nodes_configs "$E2E_RUN_DIR/mix/configs"
mix_nodes_start "$E2E_RUN_DIR/mix/configs" "$CREDS"

RUNTIME="${E2E_MIX_RUNTIME_S:-120}"
say "cover-traffic window: ${RUNTIME}s"
sleep "$RUNTIME"

# ---------- verdict ----------------------------------------------------------
# Metrics endpoints on covering relays answer unreliably (proof generation
# saturates the event loop), so the verdict aggregates over the nodes that DO
# answer and requires per-hop evidence from at least one: a forwarded
# Intermediate message is a mix hop whose RLN proof verified (spam protection
# rejects before forwarding). Rejections must be zero everywhere scrapeable.
section "verdict"
scraped=0 emitted_total=0 proofs_total=0 hops_total=0 rejected_total=0
printf '%-4s %10s %10s %12s %12s %10s %10s\n' node emitted received proofs_gen hops_fwd rejected build_err
for i in 0 1 2 3 4; do
    if ! curl -s -m 15 -o /dev/null "http://127.0.0.1:$(mix_node_metrics_port "$i")/metrics"; then
        printf '%-4s %10s\n' "n$i" "(no scrape)"
        continue
    fi
    scraped=$((scraped + 1))
    e=$(mix_metric "$i" mix_cover_emitted_total)
    r=$(mix_metric "$i" mix_cover_received_total)
    p=$(mix_metric "$i" mix_rln_proof_generation_duration_seconds_count)
    h=$(mix_metric "$i" 'mix_messages_forwarded_total{type="Intermediate"')
    j=$(mix_metric "$i" mix_rln_messages_rejected_total)
    b=$(mix_metric "$i" mix_cover_error_total)
    printf '%-4s %10s %10s %12s %12s %10s %10s\n' "n$i" "$e" "$r" "$p" "$h" "$j" "$b"
    emitted_total=$((emitted_total + e))
    proofs_total=$((proofs_total + p))
    hops_total=$((hops_total + h))
    rejected_total=$((rejected_total + j))
done

[ "$scraped" -ge 2 ] || die "only $scraped/5 metrics endpoints answered — cannot form a verdict"
[ "$emitted_total" -gt 0 ] || die "no cover traffic emitted — mix idle"
[ "$proofs_total" -gt 0 ] || die "no RLN proofs generated — spam protection not exercised"
[ "$hops_total" -gt 0 ] || die "no forwarded Intermediate messages — no hop verified a proof"
[ "$rejected_total" -eq 0 ] || die "$rejected_total messages rejected — registered members must verify clean"

say "PASS — mixnet over on-chain membership"
say "  plugin tree root  $MIX_TREE_ROOT (== on-chain valid root)"
say "  scrapeable nodes  $scraped/5"
say "  cover emitted     $emitted_total"
say "  rln proofs        $proofs_total generated"
say "  verified hops     $hops_total (forwarded Intermediate)"
say "  rejected          $rejected_total"
