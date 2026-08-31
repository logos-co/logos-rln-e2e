# shellcheck shell=bash
# harness/artifacts.sh — resolve every binary/bundle a scenario loads.
#
# Resolution order per artifact:
#   1. explicit env override: LOGOSCORE, WALLET_LGX, LEZ_RLN_LGX, RLN_LGX,
#      DELIVERY_LGX, CONSUMER_LGX, LIBP2P_LGX, GIFTER_LGX
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

# chat_module rides its own repo's flake (no pin in the e2e flake yet — the
# fork branch is a moving target). Its delivery dependency is the flake
# input named `logos-delivery-module` (NOT this repo's `delivery-module`),
# which nests the Nim library as `logos-delivery`; the same two checkouts
# that override the delivery bundle override chat's copy of it, so the
# chat_module and delivery_module .lgx bundles are built from the SAME
# forked trees. Reuses the staged copies _delivery_lgx already made.
_chat_lgx() {
    local -a overrides=()
    local src dm ld out
    [ -n "${CHAT_MODULE_CHECKOUT:-}" ] \
        || die "chat_module requested: set CHAT_LGX or CHAT_MODULE_CHECKOUT (no flake pin yet)"
    say "chat-lgx: building from a filtered copy of $CHAT_MODULE_CHECKOUT" >&2
    src=$(staged_tree "$CHAT_MODULE_CHECKOUT" chat-module)
    if [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ]; then
        dm="$E2E_RUN_DIR/src-delivery-module"
        [ -d "$dm" ] || dm=$(staged_tree "$DELIVERY_MODULE_CHECKOUT" delivery-module)
        overrides+=(--override-input logos-delivery-module "path:$dm")
    fi
    if [ -n "${LOGOS_DELIVERY_CHECKOUT:-}" ]; then
        ld="$E2E_RUN_DIR/src-logos-delivery"
        [ -d "$ld" ] || ld=$(staged_tree "$LOGOS_DELIVERY_CHECKOUT" logos-delivery)
        overrides+=(--override-input logos-delivery-module/logos-delivery "path:$ld")
    fi
    out=$(cd "$src" && nix build --no-link --print-out-paths --accept-flake-config \
        ".#lgx" "${overrides[@]}") || die "nix build chat-module .#lgx failed"
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

    # The in-repo consumer module (Nim mock of logos-delivery), only when the
    # scenario loads it. A path subflake of THIS repo: the working tree is the
    # pin, so there is no checkout-override knob — edit and re-run.
    case " ${NEEDS_MODULES:-} " in
        *" nim_rln_consumer "*)
            [ -n "${CONSUMER_LGX:-}" ] || CONSUMER_LGX=$(lgx_of "$(_nix_out consumer-lgx)")
            export CONSUMER_LGX
            ;;
    esac

    # chat_module (chat-basecamp-rln): checkout-or-env only, see _chat_lgx.
    case " ${NEEDS_MODULES:-} " in
        *" chat_module "*)
            [ -n "${CHAT_LGX:-}" ] || CHAT_LGX=$(_chat_lgx)
            export CHAT_LGX
            ;;
    esac

    # Gifter-path artifacts (consumer-gifter): not pinned in this repo's flake
    # yet — the gifter needs a register-target fix that hasn't merged (its
    # lp.rs still calls the pre-rename module name), so these resolve from an
    # env override or a checkout build only. Pin them once upstream is fixed.
    case " ${NEEDS_MODULES:-} " in
        *" libp2p_module "*)
            if [ -z "${LIBP2P_LGX:-}" ]; then
                [ -n "${LIBP2P_MODULE_CHECKOUT:-}" ] \
                    || die "libp2p_module requested: set LIBP2P_LGX or LIBP2P_MODULE_CHECKOUT (no flake pin yet)"
                LIBP2P_LGX=$(lgx_of "$(cd "$LIBP2P_MODULE_CHECKOUT" && nix build .#lgx --no-link --print-out-paths --accept-flake-config | tail -1)")
            fi
            export LIBP2P_LGX
            ;;
    esac
    case " ${NEEDS_MODULES:-} " in
        *" rln_gifter_module "*)
            if [ -z "${GIFTER_LGX:-}" ]; then
                [ -n "${GIFTER_CHECKOUT:-}" ] \
                    || die "rln_gifter_module requested: set GIFTER_LGX or GIFTER_CHECKOUT (no flake pin yet — needs the register-target fix branch)"
                GIFTER_LGX=$(lgx_of "$(cd "$GIFTER_CHECKOUT/rust/rln-gifter-module" && nix build .#lgx --no-link --print-out-paths --accept-flake-config | tail -1)")
            fi
            export GIFTER_LGX
            ;;
    esac

    # Applications (NEEDS_APPS) — not .lgx bundles, not installed into
    # E2E_MODULES_DIR; each resolves to an executable the scenario launches
    # itself. basecamp: the dev #app build ONLY — its wrapper sets the Qt
    # paths, the QML inspector is compiled in, and (critically) only the
    # non-portable build appends the `-dev` variant liblogos discovery needs
    # to load the harness-built module bundles; the portable inspector
    # bundle would silently load zero side-loaded modules.
    case " ${NEEDS_APPS:-} " in
        *" basecamp "*)
            if [ -z "${BASECAMP_APP:-}" ]; then
                [ -n "${BASECAMP_CHECKOUT:-}" ] \
                    || die "basecamp requested: set BASECAMP_APP or BASECAMP_CHECKOUT"
                say "basecamp: building #app from $BASECAMP_CHECKOUT"
                out=$(cd "$BASECAMP_CHECKOUT" && nix build .#app --no-link --print-out-paths --accept-flake-config | tail -1)
                BASECAMP_APP="$out/bin/LogosBasecamp"
            fi
            [ -x "$BASECAMP_APP" ] || die "basecamp binary not executable: $BASECAMP_APP"
            export BASECAMP_APP
            say "basecamp app: $BASECAMP_APP"
            ;;
    esac

    E2E_MODULES_DIR="$E2E_RUN_DIR/modules"
    export E2E_MODULES_DIR
    mkdir -p "$E2E_MODULES_DIR"
    install_lgx "$WALLET_LGX"
    install_lgx "$LEZ_RLN_LGX"
    install_lgx "$RLN_LGX"
    [ -n "${DELIVERY_LGX:-}" ] && install_lgx "$DELIVERY_LGX"
    [ -n "${CHAT_LGX:-}" ] && install_lgx "$CHAT_LGX"
    [ -n "${CONSUMER_LGX:-}" ] && install_lgx "$CONSUMER_LGX"
    [ -n "${LIBP2P_LGX:-}" ] && install_lgx "$LIBP2P_LGX"
    [ -n "${GIFTER_LGX:-}" ] && install_lgx "$GIFTER_LGX"
    say "modules dir: $E2E_MODULES_DIR ($(lgx_platform))"
}
