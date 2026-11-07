# shellcheck shell=bash
# harness/artifacts.sh — resolve every binary/bundle a scenario loads.
#
# Resolution order per artifact:
#   1. explicit env override: LOGOSCORE, WALLET_LGX, LEZ_RLN_LGX, RLN_LGX,
#      DELIVERY_LGX, LIBP2P_LGX, GIFTER_LGX, AUTH_LGX, SIGN_LGX
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
#   E2E_LEZ_RLN_REV     the lez-rln rev the pin builds against (derived)
#   E2E_LEZ_RLN_MODULE_VERSION / E2E_RLN_MODULE_VERSION
#                       module versions this run builds (derived), which the
#                       relay image build uses instead of hardcoded ARGs
#   E2E_LEZ_RLN_SRC     pinned logos-lez-rln source (read-only /nix/store)
#   E2E_RLN_MODULES_SRC pinned logos-rln-modules source
#   LEZ_RLN_CHECKOUT    passthrough override for the lez-rln SOURCE
#   E2E_LEZ_RLN         the checkout when it exists, else the pinned store
#                       path. tools/deployments/stage.sh runs fine from the
#                       store path; provisioning needs a real checkout —
#                       which of the two a target needs is the target's call.

E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/lib/lgx.sh"

# The key of a pinned build: this flake's two files and the attr. Nothing
# else this flake evaluates lives in the tree (its packages are re-exports of
# locked inputs).
_pin_key() {
    _e2e_sha "$1 $(shasum -a 256 "$E2E_ROOT/flake.nix" "$E2E_ROOT/flake.lock" | cut -c1-64 | tr '\n' ' ')"
}

# `nix build .#<attr>` from the pins, through the artifact cache: an unchanged
# flake.nix + flake.lock answers from <cache>/artifacts/<attr> without the
# 60-80 s evaluation. --accept-flake-config trusts OUR OWN flake's nixConfig
# (the logos cache substituter the delivery bundle's prebuilt libs come from).
# Every result is GC-rooted (nix_root) and pushed to the local cache (nix_push).
_nix_out() {
    local attr="$1" key out
    key=$(_pin_key "$attr")
    if out=$(artifact_cache_get "$attr" "$key"); then
        say "$attr: pin unchanged, cached $out" >&2
        nix_root "e2e-$attr" "$out"
    else
        nix_retry_cfg
        out=$(nix build "$E2E_ROOT#$attr" --no-link --print-out-paths --accept-flake-config --fallback | tail -1)
        [ -n "$out" ] && [ -e "$out" ] || die "nix build .#$attr produced no output path"
        nix_root "e2e-$attr" "$out"
        nix_push "$out" "$attr"
        artifact_cache_put "$attr" "$key" "$out"
    fi
    printf '%s' "$out"
}

_bundle_lgx() {
    local out
    if [ -n "${RLN_MODULES_CHECKOUT:-}" ]; then
        module_lgx "$1" "$RLN_MODULES_CHECKOUT"
    else
        # a die inside $(...) only ends the subshell: check the path here
        out=$(_nix_out "$1") || die "nix build .#$1 failed"
        lgx_of "$out"
    fi
}

# _checkout_lgx <flake dir> <name> — `nix build <dir>#lgx` for a bundle that
# has no pin in this flake (libp2p_module, gifter, auth, sign), through the
# artifact cache (keyed by the tree's content), GC-rooted and pushed to the
# local cache like every other build, printing the store path. Empty output
# (a dropped substitute download) is a failure here, not later at
# load-module. Without the root, a min-free auto-GC between this build and
# install_lgx deletes the path (seen 2026-11-05).
_checkout_lgx() {
    local dir="$1" name="$2" key out
    [ -d "$dir" ] || return 1
    key=$(_e2e_sha "$dir $(_tree_hash "$dir")")
    if out=$(artifact_cache_get "$name-checkout" "$key"); then
        say "$name: $dir unchanged, cached $out" >&2
        nix_root "e2e-$name-checkout" "$out"
        printf '%s' "$out"
        return 0
    fi
    nix_retry_cfg
    out=$(cd "$dir" && nix build .#lgx --no-link --print-out-paths --accept-flake-config --fallback | tail -1) || return 1
    [ -n "$out" ] && [ -e "$out" ] || return 1
    nix_root "e2e-$name-checkout" "$out"
    nix_push "$out" "$name"
    artifact_cache_put "$name-checkout" "$key" "$out"
    printf '%s' "$out"
}

# _need_lgx <var> <what>: the resolved bundle must be a file, or the run stops here.
_need_lgx() {
    local path
    eval "path=\"\${$1:-}\""
    [ -n "$path" ] && [ -f "$path" ] || die "$2: resolved to '${path:-<empty>}', not a bundle file — the build above failed"
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
        out=$(_nix_out delivery-lgx) || die "nix build .#delivery-lgx failed"
        lgx_of "$out"
        return
    fi
    # The override build goes through this flake (the delivery pin is only
    # here), so it pays the evaluation; the artifact cache, keyed by the
    # pins and every staged copy's content hash, spares a rerun.
    local key hashes="" c
    for c in "$(e2e_cache_dir)"/src/delivery-module "$(e2e_cache_dir)"/src/logos-delivery; do
        [ -f "$c/.e2e-src-hash" ] && hashes="$hashes $(basename "$c")=$(cat "$c/.e2e-src-hash")"
    done
    key=$(_e2e_sha "$(_pin_key delivery-lgx) ${overrides[*]} $hashes")
    if out=$(artifact_cache_get delivery-lgx-checkout "$key"); then
        say "delivery-lgx: overrides unchanged, cached $out" >&2
        nix_root e2e-delivery-lgx-checkout "$out"
    else
        nix_retry_cfg
        out=$(cd "$E2E_ROOT" && nix build --no-link --print-out-paths --accept-flake-config --fallback \
            ".#delivery-lgx" "${overrides[@]}" | tail -1)
        [ -n "$out" ] && [ -e "$out" ] || die "nix build .#delivery-lgx (checkout override) produced no output path"
        nix_root e2e-delivery-lgx-checkout "$out"
        nix_push "$out" delivery-lgx
        artifact_cache_put delivery-lgx-checkout "$key" "$out"
    fi
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
    # An explicit path: ref — the staged copy sits inside THIS repo's git
    # worktree (runs/ is ignored), and a bare `.` there would resolve as a
    # git+file flake and refuse the untracked files.
    # bash 3.2 expands an EMPTY array under `set -u` as an unbound variable, so
    # the no-override case — which is now the ordinary one, since the delivery
    # pin carries what chat needs — has to skip the expansion rather than pass
    # an empty list. _delivery_lgx above guards the same way.
    if [ ${#overrides[@]} -eq 0 ]; then
        out=$(nix build --no-link --print-out-paths --accept-flake-config \
            "path:$src#lgx") || die "nix build chat-module path:#lgx failed"
    else
        out=$(nix build --no-link --print-out-paths --accept-flake-config \
            "path:$src#lgx" "${overrides[@]}") || die "nix build chat-module path:#lgx (checkout override) failed"
    fi
    lgx_of "$out"
}

# rln-layouts is the on-chain wire: the module stack decodes chain state with
# it, so its pinned lez-rln rev must be the rev whose programs are deployed.
# The matrix comes from harness/resolve.py: logos-rln-modules is the pin, and
# the lez-rln rev and the two module versions are READ OUT of it rather than
# maintained beside it. This runs the resolver for its verdict and exports what
# it derived, so a scenario or the relay image build can use the versions this
# run actually builds instead of a number someone typed.
_check_pins() {
    local pins out
    pins=$(_nix_out pins)
    # shellcheck source=/dev/null
    . "$pins"
    export E2E_LEZ_RLN_SRC E2E_RLN_MODULES_SRC

    out=$(python3 "$E2E_ROOT/harness/resolve.py" --json \
            --modules-src "$E2E_RLN_MODULES_SRC" \
            --flake-lock "$E2E_ROOT/flake.lock") \
        || die "pin matrix refused — see above. Relock lez-rln to the rev the \
rln-modules pin builds against, or bump rln-layouts in logos-rln-modules."

    E2E_LEZ_RLN_REV=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lez_rln"]["value"])')
    E2E_LEZ_RLN_MODULE_VERSION=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lez_rln_module"]["value"])')
    E2E_RLN_MODULE_VERSION=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rln_module"]["value"])')
    export E2E_LEZ_RLN_REV E2E_LEZ_RLN_MODULE_VERSION E2E_RLN_MODULE_VERSION
    say "pin matrix: rln-modules decides lez-rln ${E2E_LEZ_RLN_REV:0:12}, \
liblogos_lez_rln_module $E2E_LEZ_RLN_MODULE_VERSION, liblogos_rln_module $E2E_RLN_MODULE_VERSION"
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

    # Each resolver runs in a $(...): its die ends only the subshell, so the
    # result is checked here, before anything boots. A run that reached the
    # devnet with an empty bundle path used to cost 4 min to fail at load-module.
    [ -n "${LEZ_RLN_LGX:-}" ] || LEZ_RLN_LGX=$(_bundle_lgx lez-rln-module-lgx) || die "lez-rln-module-lgx: no bundle"
    [ -n "${RLN_LGX:-}" ]     || RLN_LGX=$(_bundle_lgx rln-module-lgx) || die "rln-module-lgx: no bundle"
    _need_lgx LEZ_RLN_LGX lez-rln-module-lgx
    _need_lgx RLN_LGX rln-module-lgx
    export LEZ_RLN_LGX RLN_LGX

    # lez_core, like every other optional module: only when the scenario loads
    # it. Since liblogos_lez_rln_module 3.0.0 owns its wallet in-process,
    # nothing in this repo asks for lez_core any more — the Basecamp scenarios
    # were the last, and they read the app's balance off the chain instead.
    # The branch stays because a scenario may still want a wallet of its own;
    # nothing else must pay for the build.
    case " ${NEEDS_MODULES:-} " in
        *" lez_core "*)
            [ -n "${WALLET_LGX:-}" ] || WALLET_LGX=$(_bundle_lgx wallet-lgx) || die "wallet-lgx: no bundle"
            _need_lgx WALLET_LGX wallet-lgx
            export WALLET_LGX
            ;;
    esac
    say "bundles: $(basename "$LEZ_RLN_LGX"), $(basename "$RLN_LGX")${WALLET_LGX:+, $(basename "$WALLET_LGX")}"

    # The delivery bundle only when the scenario loads it (scenario.env is
    # sourced before resolve_artifacts, so NEEDS_MODULES is visible here) —
    # register/live-registry runs must not pay for the delivery build.
    case " ${NEEDS_MODULES:-} " in
        *" delivery_module "*)
            [ -n "${DELIVERY_LGX:-}" ] || DELIVERY_LGX=$(_delivery_lgx) || die "delivery-lgx: no bundle"
            _need_lgx DELIVERY_LGX delivery-lgx
            export DELIVERY_LGX
            ;;
    esac

    # chat_module (chat-basecamp-rln): checkout-or-env only, see _chat_lgx.
    case " ${NEEDS_MODULES:-} " in
        *" chat_module "*)
            [ -n "${CHAT_LGX:-}" ] || CHAT_LGX=$(_chat_lgx)
            export CHAT_LGX
            ;;
    esac

    # Gifter-path artifacts: not pinned in this repo's flake, so these
    # resolve from an env override or a checkout build only. The gifter
    # checkout also carries its verifier (rln_auth_module) and producer
    # (rln_sign_module) modules, each its own flake under rust/.
    case " ${NEEDS_MODULES:-} " in
        *" libp2p_module "*)
            if [ -z "${LIBP2P_LGX:-}" ]; then
                [ -n "${LIBP2P_MODULE_CHECKOUT:-}" ] \
                    || die "libp2p_module requested: set LIBP2P_LGX or LIBP2P_MODULE_CHECKOUT (no flake pin yet)"
                out=$(_checkout_lgx "$LIBP2P_MODULE_CHECKOUT" libp2p) || die "libp2p_module: nix build .#lgx failed in ${LIBP2P_MODULE_CHECKOUT}"
                LIBP2P_LGX=$(lgx_of "$out") || die "libp2p_module: no .lgx in $out"
            fi
            export LIBP2P_LGX
            ;;
    esac
    case " ${NEEDS_MODULES:-} " in
        *" rln_gifter_module "*)
            if [ -z "${GIFTER_LGX:-}" ]; then
                [ -n "${GIFTER_CHECKOUT:-}" ] \
                    || die "rln_gifter_module requested: set GIFTER_LGX or GIFTER_CHECKOUT (no flake pin yet — needs the register-target fix branch)"
                out=$(_checkout_lgx "$GIFTER_CHECKOUT/rust/rln-gifter-module" gifter) || die "rln_gifter_module: nix build .#lgx failed in ${GIFTER_CHECKOUT}"
                GIFTER_LGX=$(lgx_of "$out") || die "rln_gifter_module: no .lgx in $out"
            fi
            export GIFTER_LGX
            ;;
    esac
    case " ${NEEDS_MODULES:-} " in
        *" rln_auth_module "*)
            if [ -z "${AUTH_LGX:-}" ]; then
                [ -n "${GIFTER_CHECKOUT:-}" ] \
                    || die "rln_auth_module requested: set AUTH_LGX or GIFTER_CHECKOUT (no flake pin yet)"
                out=$(_checkout_lgx "$GIFTER_CHECKOUT/rust/rln-auth-module" auth) || die "rln_auth_module: nix build .#lgx failed in ${GIFTER_CHECKOUT}"
                AUTH_LGX=$(lgx_of "$out") || die "rln_auth_module: no .lgx in $out"
            fi
            export AUTH_LGX
            ;;
    esac
    case " ${NEEDS_MODULES:-} " in
        *" rln_sign_module "*)
            if [ -z "${SIGN_LGX:-}" ]; then
                [ -n "${GIFTER_CHECKOUT:-}" ] \
                    || die "rln_sign_module requested: set SIGN_LGX or GIFTER_CHECKOUT (no flake pin yet)"
                out=$(_checkout_lgx "$GIFTER_CHECKOUT/rust/rln-sign-module" sign) || die "rln_sign_module: nix build .#lgx failed in ${GIFTER_CHECKOUT}"
                SIGN_LGX=$(lgx_of "$out") || die "rln_sign_module: no .lgx in $out"
            fi
            export SIGN_LGX
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
    install_lgx "$LEZ_RLN_LGX"
    install_lgx "$RLN_LGX"
    [ -n "${WALLET_LGX:-}" ] && install_lgx "$WALLET_LGX"
    [ -n "${DELIVERY_LGX:-}" ] && install_lgx "$DELIVERY_LGX"
    [ -n "${CHAT_LGX:-}" ] && install_lgx "$CHAT_LGX"
    [ -n "${LIBP2P_LGX:-}" ] && install_lgx "$LIBP2P_LGX"
    [ -n "${GIFTER_LGX:-}" ] && install_lgx "$GIFTER_LGX"
    [ -n "${AUTH_LGX:-}" ] && install_lgx "$AUTH_LGX"
    [ -n "${SIGN_LGX:-}" ] && install_lgx "$SIGN_LGX"
    say "modules dir: $E2E_MODULES_DIR ($(lgx_platform))"
}
