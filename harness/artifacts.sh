# shellcheck shell=bash
# harness/artifacts.sh — resolve every binary/bundle a scenario loads.
#
# Resolution order per artifact:
#   1. explicit env override: LOGOSCORE, WALLET_LGX, LEZ_RLN_LGX, RLN_LGX,
#      DELIVERY_LGX
#   2. checkout overrides — the dev loop for changing a repo and running a
#      scenario against it (filtered copy + --override-input):
#        RLN_MODULES_CHECKOUT=<dir>      the three RLN-stack bundles
#        DELIVERY_MODULE_CHECKOUT=<dir>  the delivery C++ shim
#        LOGOS_DELIVERY_CHECKOUT=<dir>   the Nim lib under it (source build;
#                                        composable with the shim override)
#   3. nix build from the flake pins: .#logoscore, .#wallet-lgx,
#      .#lez-rln-module-lgx, .#rln-module-lgx. Verified 2026-08-10: the module
#      bundles build from a clean rln-modules fetch — the module-builder
#      stages the sdk and regenerates the scaffold in-derivation. (The
#      checkout-side staging scripts are only for bare-cargo dev loops.)
#
# The pin-consistency check: the rln-modules tree pins rln-layouts to a
# logos-lez-rln rev in logos-lez-rln-module/rust-lib/Cargo.toml; if that rev
# differs from the lez-rln source in use, chain-state decode skew shows up as
# phantom chain bugs. Assert equality, fail loudly with both revs.
#
# Exports beyond docs/contract.md:
#   E2E_LEZ_RLN_SRC     pinned logos-lez-rln source (read-only /nix/store)
#   E2E_RLN_MODULES_SRC pinned logos-rln-modules source
#   LEZ_RLN_CHECKOUT    passthrough override for the lez-rln SOURCE
#   E2E_LEZ_RLN         the checkout when it exists, else the pinned store
#                       path. tools/deployments/stage.sh runs fine from the
#                       store path; provisioning needs a real checkout —
#                       which of the two a target needs is the target's call.

E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/lib/lgx.sh"

_nix_out() {
    local out
    # --accept-flake-config trusts OUR OWN flake's nixConfig (the logos cache
    # substituter the delivery bundle's prebuilt libs come from).
    out=$(nix build "$E2E_ROOT#$1" --no-link --print-out-paths --accept-flake-config | tail -1)
    [ -n "$out" ] || die "nix build .#$1 produced no output path"
    printf '%s' "$out"
}

_bundle_lgx() {
    if [ -n "${RLN_MODULES_CHECKOUT:-}" ]; then
        module_lgx "$1" "$RLN_MODULES_CHECKOUT"
    else
        lgx_of "$(_nix_out "$1")"
    fi
}

# The delivery stack's dev loop: either repo swaps for a working tree,
# independently or together —
#   DELIVERY_MODULE_CHECKOUT  the C++ shim (logos-delivery-module tree)
#   LOGOS_DELIVERY_CHECKOUT   the Nim library underneath it (logos-delivery
#                             tree; must have submodules checked out — the
#                             pin fetches with ?submodules=1, a path
#                             override carries only what's on disk)
# Swapping logos-delivery rebuilds liblogosdelivery from source (only pinned
# revs are prebuilt in the logos cache) — expect a long first build.
# DELIVERY_LGX (a prebuilt .lgx file) still short-circuits both.
_delivery_lgx() {
    local -a overrides=()
    local src out
    if [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ]; then
        say "delivery-lgx: shim from a filtered copy of $DELIVERY_MODULE_CHECKOUT" >&2
        src=$(staged_tree "$DELIVERY_MODULE_CHECKOUT" delivery-module)
        overrides+=(--override-input delivery-module "path:$src")
    fi
    if [ -n "${LOGOS_DELIVERY_CHECKOUT:-}" ]; then
        say "delivery-lgx: liblogosdelivery from a filtered copy of $LOGOS_DELIVERY_CHECKOUT (source build)" >&2
        src=$(staged_tree "$LOGOS_DELIVERY_CHECKOUT" logos-delivery)
        overrides+=(--override-input delivery-module/logos-delivery "path:$src")
    fi
    if [ ${#overrides[@]} -eq 0 ]; then
        lgx_of "$(_nix_out delivery-lgx)"
        return
    fi
    out=$(cd "$E2E_ROOT" && nix build --no-link --print-out-paths --accept-flake-config \
        ".#delivery-lgx" "${overrides[@]}") || die "nix build .#delivery-lgx (checkout override) failed"
    lgx_of "$out"
}

# rln-layouts is the on-chain wire: the module stack decodes chain state with
# it, so its pinned lez-rln rev must be the rev whose programs are deployed.
_check_pins() {
    local pins layouts_rev lock_rev
    pins=$(_nix_out pins)
    # shellcheck source=/dev/null
    . "$pins"
    export E2E_LEZ_RLN_SRC E2E_RLN_MODULES_SRC
    layouts_rev=$(grep -E '^rln-layouts' \
        "$E2E_RLN_MODULES_SRC/logos-lez-rln-module/rust-lib/Cargo.toml" \
        | grep -oE '[0-9a-f]{40}' | head -1)
    lock_rev=$(jq -r '.nodes["lez-rln"].locked.rev' "$E2E_ROOT/flake.lock")
    [ -n "$layouts_rev" ] || die "cannot read the rln-layouts rev from the rln-modules pin"
    [ -n "$lock_rev" ] || die "cannot read the lez-rln rev from flake.lock"
    [ "$layouts_rev" = "$lock_rev" ] || die "pin skew: rln-modules pins rln-layouts to lez-rln $layouts_rev, flake.lock pins lez-rln $lock_rev — the module stack would decode chain state with the wrong layouts. Bump one of the two."
    say "pins consistent: lez-rln ${lock_rev:0:12} (rln-layouts + flake.lock)"
}

resolve_artifacts() {
    section "artifacts"
    [ -n "${E2E_RUN_DIR:-}" ] || die "resolve_artifacts: E2E_RUN_DIR unset (run.sh sets it)"
    local tool out
    for tool in nix jq python3 tar curl rsync; do
        command -v "$tool" >/dev/null || die "missing tool: $tool"
    done

    _check_pins
    if [ -n "${LEZ_RLN_CHECKOUT:-}" ] && [ -d "$LEZ_RLN_CHECKOUT" ]; then
        E2E_LEZ_RLN="$LEZ_RLN_CHECKOUT"
    else
        E2E_LEZ_RLN="$E2E_LEZ_RLN_SRC"
    fi
    export E2E_LEZ_RLN LEZ_RLN_CHECKOUT="${LEZ_RLN_CHECKOUT:-}"
    say "lez-rln source: $E2E_LEZ_RLN"

    if [ -z "${LOGOSCORE:-}" ]; then
        out=$(_nix_out logoscore)
        LOGOSCORE="$out/bin/logoscore"
    fi
    [ -x "$LOGOSCORE" ] || die "logoscore not executable: $LOGOSCORE"
    export LOGOSCORE

    [ -n "${WALLET_LGX:-}" ]  || WALLET_LGX=$(_bundle_lgx wallet-lgx)
    [ -n "${LEZ_RLN_LGX:-}" ] || LEZ_RLN_LGX=$(_bundle_lgx lez-rln-module-lgx)
    [ -n "${RLN_LGX:-}" ]     || RLN_LGX=$(_bundle_lgx rln-module-lgx)
    export WALLET_LGX LEZ_RLN_LGX RLN_LGX
    say "bundles: $(basename "$WALLET_LGX"), $(basename "$LEZ_RLN_LGX"), $(basename "$RLN_LGX")"

    # The delivery bundle only when the scenario loads it (scenario.env is
    # sourced before resolve_artifacts, so NEEDS_MODULES is visible here) —
    # register/live-registry runs must not pay for the delivery build.
    case " ${NEEDS_MODULES:-} " in
        *" delivery_module "*)
            [ -n "${DELIVERY_LGX:-}" ] || DELIVERY_LGX=$(_delivery_lgx)
            export DELIVERY_LGX
            ;;
    esac

    E2E_MODULES_DIR="$E2E_RUN_DIR/modules"
    export E2E_MODULES_DIR
    mkdir -p "$E2E_MODULES_DIR"
    install_lgx "$WALLET_LGX"
    install_lgx "$LEZ_RLN_LGX"
    install_lgx "$RLN_LGX"
    [ -n "${DELIVERY_LGX:-}" ] && install_lgx "$DELIVERY_LGX"
    say "modules dir: $E2E_MODULES_DIR ($(lgx_platform))"
}
