#!/usr/bin/env bash
# tools/lez-v030-local.sh — run scenarios on the local target against the
# LEZ v0.3.0 port, before either side is pinned here.
#
# Inputs (checkouts, built):
#   LEZ_RLN_CHECKOUT      logos-lez-rln at the v0.3.0 port; guest .bins staged
#                         in methods/guest/target/riscv32im-risc0-zkvm-elf/docker/
#                         and the host bins built (see its lez-rln/CLAUDE.md)
#   RLN_MODULES_CHECKOUT  logos-rln-modules on feat/lez-v0.3.0 (lez module 5.0.0)
#   E2E_LEZ_RLN_REV       the port's rev (what the modules' rln-layouts pins);
#                         default: HEAD of LEZ_RLN_CHECKOUT
#
# The two module bundles build from RLN_MODULES_CHECKOUT's own flake, which
# locks LEZ v0.3.0 for its nested inputs; module_lgx's single --override-input
# would keep this repo's rc3 lock underneath. Prebuilt LEZ_RLN_LGX / RLN_LGX
# skip that build.
#
# E2E_LOCAL_PROFILE=fresh: profiles/local-default holds an rc3 tree and wallet.
#
# E2E_V030_TARGET (default local) picks the target; testnet is the live
# LEZ 0.3 zone, and also needs E2E_PAYER_WALLET (see harness/targets/testnet.sh).
#
# Usage: tools/lez-v030-local.sh <scenario> [run.sh args...]
# Last green (lez-rln e54598d): local 2026-10-01 — live-registry, register,
# keystore, delivery-rln, delivery-rln-soak; testnet 2026-10-02 —
# live-registry, register, delivery-rln.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCEN="${1:?usage: tools/lez-v030-local.sh <scenario> [run.sh args...]}"
shift

: "${LEZ_RLN_CHECKOUT:?set LEZ_RLN_CHECKOUT to the logos-lez-rln v0.3.0 port}"
: "${RLN_MODULES_CHECKOUT:?set RLN_MODULES_CHECKOUT to logos-rln-modules feat/lez-v0.3.0}"
export LEZ_RLN_CHECKOUT RLN_MODULES_CHECKOUT
export E2E_LEZ_RLN_REV="${E2E_LEZ_RLN_REV:-$(git -C "$LEZ_RLN_CHECKOUT" rev-parse HEAD)}"
export E2E_LOCAL_PROFILE="${E2E_LOCAL_PROFILE:-fresh}"

bundle() {
    local out
    out=$(cd "$RLN_MODULES_CHECKOUT" && nix build ".#$1" --no-link --print-out-paths --accept-flake-config | tail -1)
    find "$out/" -maxdepth 1 -name '*.lgx' | head -1
}
export LEZ_RLN_LGX="${LEZ_RLN_LGX:-$(bundle logos-lez-rln-module-lgx)}"
export RLN_LGX="${RLN_LGX:-$(bundle logos-rln-module-lgx)}"
echo "lez-rln $E2E_LEZ_RLN_REV; bundles $LEZ_RLN_LGX $RLN_LGX"

exec "$ROOT/run.sh" "$SCEN" --target "${E2E_V030_TARGET:-local}" "$@"
