# shellcheck shell=bash
# harness/lib/lgx.sh — build/unpack/install .lgx module bundles.
#
# One implementation for host runs and image builds: install_lgx flattens a
# bundle into <dest>/<name>/{manifest.json,<variant files>,variant}, picking
# this host's variant and falling back to the bundle's only variant (the
# single-variant case the container entrypoint has).
#
# Env beyond docs/contract.md:
#   E2E_PLATFORM   variant name override (default: derived from uname)
#   E2E_ROOT       repo root holding flake.nix (default: two dirs up)

E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

lgx_platform() {
    if [ -n "${E2E_PLATFORM:-}" ]; then printf '%s' "$E2E_PLATFORM"; return; fi
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)  printf 'darwin-arm64-dev' ;;
        Linux-x86_64)  printf 'linux-x86_64-dev' ;;
        Linux-aarch64) printf 'linux-aarch64-dev' ;;
        *) die "unsupported platform $(uname -s)-$(uname -m)" ;;
    esac
}

lgx_of() {
    local out; out=$(find "$1/" -maxdepth 1 -name '*.lgx' | head -1)
    [ -f "$out" ] || die "no .lgx under $1"
    printf '%s' "$out"
}

# Build a module bundle from a WORKING TREE instead of the flake pin: copy the
# tree (filtered) and override the flake input with it. The copy carries the
# tree verbatim — uncommitted changes and any gitignored staged sources —
# minus target/result/.git: a raw `path:` override copies rust-lib/target
# (~1 GB of local cargo artifacts) into /nix/store on every eval and fills the
# disk. Nix content-addresses the copy, so unchanged trees rebuild for free.
# Usage: module_lgx <flake-attr> <src-tree> [input-name]
module_lgx() {
    local attr="$1" tree="$2" input="${3:-rln-modules}"
    [ -d "$tree" ] || die "module_lgx: no source tree at $tree"
    local src="${E2E_RUN_DIR:-.}/src-$input"
    say "$attr: building from a filtered copy of $tree" >&2
    rsync -a --delete --exclude '*/rust-lib/target' --exclude 'result' \
        --exclude 'result-*' --exclude '.git' "$tree/" "$src/" \
        || die "rsync $tree failed"
    local out
    out=$(cd "$E2E_ROOT" && nix build --no-link --print-out-paths ".#$attr" \
        --override-input "$input" "path:$src") || die "nix build .#$attr failed"
    lgx_of "$out"
}

# Usage: install_lgx <bundle.lgx> [dest-modules-dir]
install_lgx() {
    local lgx="$1" dest="${2:-${E2E_MODULES_DIR:-}}" name tmp plat variant nvar
    [ -f "$lgx" ] || die "install_lgx: no bundle at $lgx"
    [ -n "$dest" ] || die "install_lgx: no destination (set E2E_MODULES_DIR)"
    name=$(tar xzOf "$lgx" manifest.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    [ -n "$name" ] || die "install_lgx: cannot read name from $lgx"
    tmp=$(mktemp -d)
    tar xzf "$lgx" -C "$tmp" || die "install_lgx: cannot unpack $lgx"
    plat=$(lgx_platform)
    if [ -d "$tmp/variants/$plat" ]; then
        variant="$plat"
    else
        # Single-variant bundles (image builds) carry whatever the builder
        # produced; anything else is a genuine platform mismatch.
        nvar=$(find "$tmp/variants" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
        [ "$nvar" = "1" ] || die "install_lgx: $lgx has no variants/$plat"
        variant=$(basename "$(find "$tmp/variants" -mindepth 1 -maxdepth 1 -type d | head -1)")
    fi
    rm -rf "${dest:?}/$name"
    mkdir -p "$dest/$name"
    cp "$tmp/manifest.json" "$dest/$name/"
    cp -L "$tmp/variants/$variant/"* "$dest/$name/"
    printf '%s' "$variant" > "$dest/$name/variant"
    rm -rf "$tmp"
}
