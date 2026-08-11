#!/usr/bin/env bash
# logos-rln-e2e — run one scenario against one target chain.
#
#   ./run.sh <scenario> [--target local|testnet] [--keep]
#   ./run.sh --list
#
# A scenario is scenarios/<id>/{scenario.env,run.sh}: scenario.env declares
# what it needs (NODES, NEEDS_MODULES, TARGETS, RUNNER, optionally
# STATUS=quarantined), run.sh drives the nodes through the harness contract
# (docs/contract.md). A target (harness/targets/<target>.sh) stands up and
# provisions the chain, then exports the contract env. bash 3.2 clean.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/harness/lib/compat.sh"

usage() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

list_scenarios() {
    local env id status
    for env in "$HERE"/scenarios/*/scenario.env; do
        [ -f "$env" ] || continue
        id=$(basename "$(dirname "$env")")
        # shellcheck source=/dev/null
        status=$(. "$env"; printf '%s' "${STATUS:-active}")
        printf '  %-14s %s\n' "$id" "$status"
    done
}

SCENARIO=""
TARGET="local"
export E2E_KEEP="${E2E_KEEP:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --list) list_scenarios; exit 0 ;;
        --target) TARGET="${2:?--target needs a value}"; shift 2 ;;
        --keep) E2E_KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *) [ -z "$SCENARIO" ] || die "one scenario per run (got '$SCENARIO' and '$1')"
           SCENARIO="$1"; shift ;;
    esac
done
[ -n "$SCENARIO" ] || { usage; exit 2; }

SDIR="$HERE/scenarios/$SCENARIO"
[ -f "$SDIR/scenario.env" ] || die "unknown scenario '$SCENARIO' — ./run.sh --list"
. "$SDIR/scenario.env"
[ "${STATUS:-active}" != "quarantined" ] \
    || die "scenario '$SCENARIO' is quarantined — see scenarios/$SCENARIO/STATUS.md"
case " ${TARGETS:-local testnet} " in
    *" $TARGET "*) ;;
    *) die "scenario '$SCENARIO' does not support target '$TARGET' (supports: ${TARGETS:-local testnet})" ;;
esac
TARGET_SH="$HERE/harness/targets/$TARGET.sh"
[ -f "$TARGET_SH" ] || die "unknown target '$TARGET'"

export E2E_TARGET="$TARGET"
export E2E_SCENARIO="$SCENARIO"
E2E_RUN_DIR="$HERE/runs/$(date +%Y%m%d-%H%M%S)-$SCENARIO-$TARGET"
export E2E_RUN_DIR
mkdir -p "$E2E_RUN_DIR"
say "run dir: $E2E_RUN_DIR"

. "$HERE/harness/artifacts.sh"
resolve_artifacts

# shellcheck source=/dev/null
. "$TARGET_SH"
trap 'target_down' EXIT
target_up

section "scenario: $SCENARIO --target $TARGET"
case "${RUNNER:-bash}" in
    bash) bash "$SDIR/run.sh" ;;
    *) die "runner '${RUNNER}' not supported yet" ;;
esac
