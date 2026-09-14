#!/usr/bin/env bash
# harness/selftest.sh — the no-chain proof of the harness layers: resolve the
# artifacts, boot one daemon with the three modules loaded, and call into both
# RLN modules with NO sequencer anywhere. The assertion is that the call comes
# back as well-formed JSON (a value OR a module error envelope) — a chain
# failure is a PASS here; what is under test is artifacts -> lgx -> daemon ->
# json, not the chain.
#
# Safe to run on a laptop with nothing else up: no chain, no docker, no ports.
#
#   bash harness/selftest.sh        E2E_KEEP=1 keeps the daemon + run dir
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/compat.sh"

export E2E_KEEP="${E2E_KEEP:-0}"
export CALL_TIMEOUT="${CALL_TIMEOUT:-60}"
E2E_RUN_DIR="$ROOT/runs/$(date +%Y%m%d-%H%M%S)-selftest"
export E2E_RUN_DIR
mkdir -p "$E2E_RUN_DIR"
say "run dir: $E2E_RUN_DIR"

. "$HERE/artifacts.sh"
. "$HERE/lib/daemon.sh"

NODE=selftest
cleanup() {
    daemon_stop_all
    [ "${E2E_KEEP:-0}" = "1" ] || rm -rf "$E2E_RUN_DIR"
}
trap cleanup EXIT

resolve_artifacts
daemon_start "$NODE"
daemon_load_modules "$NODE" lez_core liblogos_lez_rln_module liblogos_rln_module

section "no-chain probes"
FAIL=0
# A dummy scope: the registry id shape the membership module parses, and a
# config account no deployment owns. Neither can succeed without a chain — the
# point is that the failure arrives as JSON.
DUMMY_CFG=11111111111111111111111111111111
DUMMY_ID=$(printf '%064d' 0)
REGISTRY_ID="logos:selftest:$(printf '%064d' 1)"

RAW=$(node_call "$NODE" liblogos_lez_rln_module get_registry_bounds "$(argfile st_cfg "$DUMMY_CFG")")
STATUS=$(printf '%s' "$RAW" | jstatus)
if [ "$STATUS" = "ok" ] || [ "$STATUS" = "error" ]; then
    say "liblogos_lez_rln_module.get_registry_bounds -> status=$STATUS result='$(printf '%s' "$RAW" | jres)'"
else
    say "FAIL liblogos_lez_rln_module.get_registry_bounds returned no JSON: ${RAW:-<empty>}"
    FAIL=$((FAIL + 1))
fi

RAW=$(node_call "$NODE" liblogos_rln_module get_registry_parameters \
    "$REGISTRY_ID" "$(argfile st_rlnid "$DUMMY_ID")")
STATUS=$(printf '%s' "$RAW" | jstatus)
RES=$(printf '%s' "$RAW" | jres)
if [ "$STATUS" = "ok" ] && [ -n "$RES" ]; then
    # -> result: the envelope carries either the parameters or a typed error.
    say "liblogos_rln_module.get_registry_parameters -> $(printf '%s' "$RES" | jval)"
else
    say "FAIL liblogos_rln_module.get_registry_parameters: status='${STATUS:-<none>}' raw=${RAW:-<empty>}"
    FAIL=$((FAIL + 1))
fi

section "selftest"
if [ "$FAIL" = "0" ]; then
    say "PASS — artifacts, lgx install, daemon boot, module load and JSON plumbing all work"
else
    die_node "$NODE" "selftest: $FAIL probe(s) failed"
fi
