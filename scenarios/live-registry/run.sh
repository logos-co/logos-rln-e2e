#!/usr/bin/env bash
# scenarios/live-registry — run the registry-provider module's gated
# live-chain cargo tests (logos-lez-rln-module/rust-lib/src/testnet_tests.rs,
# `testnet_*`) against the target's deployment. The tests read a deployment
# descriptor via LEZ_RLN_CHECKOUT/deployments/<name>; a shim tree under
# $E2E_RUN_DIR satisfies that layout with a symlink to $E2E_DEPLOYMENT_DIR,
# so any target's descriptor works unmodified.
#
# Source tree: $RLN_MODULES_CHECKOUT if set (dev inner loop — staged in
# place only when its SDK copy is missing), else the pinned source
# materialized into $E2E_RUN_DIR and staged there. cargo builds into a
# persistent cache dir so reruns skip the cold zerokit build.
#
# Env beyond docs/contract.md:
#   RLN_MODULES_CHECKOUT     use a working tree instead of the pin
#   E2E_CARGO_TARGET_DIR     build cache (default ~/.cache/logos-rln-e2e/cargo-target)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

for _v in E2E_RUN_DIR E2E_DEPLOYMENT_DIR E2E_RLN_MODULES_SRC; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
command -v cargo >/dev/null || die "cargo not found — the live-registry tests build the module crate on the host (rustup.rs)"
[ -f "$E2E_DEPLOYMENT_DIR/deployment.json" ] || die "no deployment.json in $E2E_DEPLOYMENT_DIR"

# ---------- source tree ------------------------------------------------------
section "sources"
if [ -n "${RLN_MODULES_CHECKOUT:-}" ]; then
    SRC="$RLN_MODULES_CHECKOUT"
    [ -d "$SRC/logos-lez-rln-module/rust-lib" ] || die "not a rln-modules tree: $SRC"
    if [ ! -d "$SRC/logos-lez-rln-module/logos-rust-sdk-src" ]; then
        say "staging SDK into checkout (missing)"
        bash "$SRC/logos-lez-rln-module/stage-sources.sh" >/dev/null || die "stage-sources.sh failed"
    fi
    say "using checkout: $SRC"
else
    SRC="$E2E_RUN_DIR/rln-modules"
    say "materializing pinned source ($(basename "$E2E_RLN_MODULES_SRC"))"
    rsync -a "$E2E_RLN_MODULES_SRC/" "$SRC/" || die "cannot materialize $E2E_RLN_MODULES_SRC"
    chmod -R u+w "$SRC"
    bash "$SRC/logos-lez-rln-module/stage-sources.sh" >/dev/null || die "stage-sources.sh failed"
    say "staged: $SRC"
fi

# ---------- deployment shim --------------------------------------------------
# Fixed name "e2e": the run dir is already unique, and the name only exists
# inside this shim.
SHIM="$E2E_RUN_DIR/lez-rln-shim"
mkdir -p "$SHIM/deployments"
ln -sfn "$E2E_DEPLOYMENT_DIR" "$SHIM/deployments/e2e"
say "deployment shim: $SHIM/deployments/e2e -> $E2E_DEPLOYMENT_DIR"

# ---------- the tests --------------------------------------------------------
section "cargo test testnet_ (live-registry suite)"
# The standalone sequencer leaves the CLOCK_50 account at zero, so chain time
# never tracks wall time on a local devnet (membership lifecycle timing is
# only faithfully exercised against testnet — docs/contract.md). The clock
# test would correctly fail there; skip it on local, run everything on testnet.
SKIP=()
if [ "${E2E_TARGET:-}" = "local" ]; then
    say "local target: skipping testnet_clock_account_decodes_to_live_chain_time (standalone sequencer keeps CLOCK_50 at 0)"
    SKIP=(--skip testnet_clock_account_decodes_to_live_chain_time)
fi
CACHE="${E2E_CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/logos-rln-e2e/cargo-target}"
mkdir -p "$CACHE"
OUT="$E2E_RUN_DIR/live-registry.out"
( cd "$SRC/logos-lez-rln-module/rust-lib" \
  && env LEZ_RLN_TESTNET_TESTS=1 \
         LEZ_RLN_CHECKOUT="$SHIM" \
         LEZ_RLN_TESTNET_DEPLOYMENT=e2e \
         CARGO_TARGET_DIR="$CACHE" \
         cargo test testnet_ -- --nocapture ${SKIP[@]+"${SKIP[@]}"} ) 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || die "cargo test failed (rc=$rc, full output: $OUT)"
grep -q "testnet test skipped" "$OUT" && die "gate did not propagate — tests skipped themselves"
PASSED=$(grep -Eo 'test result: ok\. [0-9]+ passed' "$OUT" | grep -Eo '[0-9]+' | tail -1)
[ -n "$PASSED" ] && [ "$PASSED" -ge 1 ] || die "could not confirm any test ran (see $OUT)"

say "PASS — $PASSED live-registry tests green against $(jq -r .sequencer "$E2E_DEPLOYMENT_DIR/deployment.json")"
