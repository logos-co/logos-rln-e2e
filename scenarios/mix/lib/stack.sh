# shellcheck shell=bash
# scenarios/mix/lib/stack.sh — checkout + build of the pinned mix-node stack
# (PINS.env). Sourced by the scenario; also runnable standalone:
#   bash scenarios/mix/lib/stack.sh build
#
# The stack builds with make/nimble from a REAL git clone (zerokit submodule
# gitlink + nimble git-URL deps + their own nim toolchain install), so the
# pin is cloned clone-and-go into ~/.cache/logos-rln-e2e/logos-delivery/<rev>
# — LOGOS_DELIVERY_CHECKOUT overrides for a dev working tree. First build is
# ~30-45 min (nim toolchain + deps + librln + wakunode2 + chat2mix); reruns
# are incremental.

_MIX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_MIX_LIB_DIR/../PINS.env"

MIX_STACK=""

mix_stack_checkout() {
    if [ -n "${LOGOS_DELIVERY_CHECKOUT:-}" ]; then
        [ -d "$LOGOS_DELIVERY_CHECKOUT/.git" ] || die "LOGOS_DELIVERY_CHECKOUT is not a git tree: $LOGOS_DELIVERY_CHECKOUT"
        MIX_STACK="$LOGOS_DELIVERY_CHECKOUT"
        say "mix stack: using checkout $MIX_STACK ($(git -C "$MIX_STACK" rev-parse --short HEAD))"
        return 0
    fi
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/logos-rln-e2e/logos-delivery/$LOGOS_DELIVERY_REV"
    if [ ! -d "$cache/.git" ]; then
        say "mix stack: fetching $LOGOS_DELIVERY_REPO @ ${LOGOS_DELIVERY_REV:0:12}…"
        rm -rf "$cache"
        mkdir -p "$cache"
        git -C "$cache" init -q
        git -C "$cache" remote add origin "$LOGOS_DELIVERY_REPO"
        # GitHub serves arbitrary-SHA fetches; fall back to a full fetch if not.
        if ! git -C "$cache" fetch -q --depth 1 origin "$LOGOS_DELIVERY_REV" 2>/dev/null; then
            say "mix stack: shallow rev fetch refused — full fetch"
            git -C "$cache" fetch -q origin || die "cannot fetch $LOGOS_DELIVERY_REPO"
        fi
        git -C "$cache" checkout -q "$LOGOS_DELIVERY_REV" || die "rev $LOGOS_DELIVERY_REV not fetchable"
        git -C "$cache" submodule update --init --depth 1 -q || die "submodule init failed"
    fi
    MIX_STACK="$cache"
    say "mix stack: $MIX_STACK"
}

mix_stack_build() {
    [ -n "$MIX_STACK" ] || die "mix_stack_build before mix_stack_checkout"
    local t0 t1
    t0=$(date +%s)
    if [ -x "$MIX_STACK/build/wakunode2" ] && [ -x "$MIX_STACK/build/chat2mix" ] && [ "${MIX_REBUILD:-0}" != "1" ]; then
        say "mix stack: binaries present (MIX_REBUILD=1 forces make)"
        return 0
    fi
    say "mix stack: make wakunode2 chat2mix (log: ${E2E_RUN_DIR:-/tmp}/mix-build.log)"
    # Deps are staged with an explicit `nimble setup --localdeps --useSystemNim`
    # (flag AFTER the command — nimble 0.22.3 ignores it before): the locked
    # nim package otherwise re-clones and checksum-mismatches on fresh darwin
    # setups. The upstream Makefile applies the same override on Windows for
    # the same reason; its own recipe puts the flag where 0.22.3 drops it.
    # Their install scripts already put nim/nimble on PATH via `make deps`'
    # prerequisites, so run those targets first.
    ( cd "$MIX_STACK" \
      && make install-nimble build-nph logos_delivery.nims librln >/dev/null 2>&1 || true
      cd "$MIX_STACK" \
      && export PATH="$HOME/.nimble/bin:$PATH" \
      && nimble setup --localdeps --useSystemNim \
      && mkdir -p nimbledeps && touch nimbledeps/.nimble-setup \
      && make NIMBLE="nimble --useSystemNim" -j"$(getconf _NPROCESSORS_ONLN)" wakunode2 chat2mix ) \
        > "${E2E_RUN_DIR:-/tmp}/mix-build.log" 2>&1 \
        || { tail -30 "${E2E_RUN_DIR:-/tmp}/mix-build.log" >&2; die "mix stack build failed"; }
    [ -x "$MIX_STACK/build/wakunode2" ] || die "build finished but no build/wakunode2"
    t1=$(date +%s)
    say "timing: mix-build $((t1 - t0))s"
}

# Standalone: `bash stack.sh build` for prewarming the cache.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    # shellcheck source=/dev/null
    . "$_MIX_LIB_DIR/../../../harness/lib/compat.sh"
    case "${1:-build}" in
        build) mix_stack_checkout && mix_stack_build ;;
        checkout) mix_stack_checkout ;;
        *) die "usage: stack.sh [checkout|build]" ;;
    esac
fi
