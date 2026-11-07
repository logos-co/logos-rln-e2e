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

# Where staged source trees and the artifact result cache live across runs:
# a release workspace's state dir (E2E_STATE_DIR), else the checkout's .cache.
e2e_cache_dir() {
    if [ -n "${E2E_CACHE_DIR:-}" ]; then printf '%s' "$E2E_CACHE_DIR"
    elif [ -n "${E2E_STATE_DIR:-}" ]; then printf '%s' "$E2E_STATE_DIR/caches/e2e"
    else printf '%s' "$E2E_ROOT/.cache/e2e"
    fi
}

# Stage a WORKING TREE for a path: flake: a filtered copy carrying the tree
# verbatim — uncommitted changes and any gitignored staged sources — minus
# build outputs and .git: a raw `path:` of the tree copies rust-lib/target
# (~1 GB of local cargo artifacts) into /nix/store on every eval and fills
# the disk. The copy lives in <cache>/src/<name>, one per name across runs,
# keyed by the tree's content (_tree_hash, kept in .e2e-src-hash): an
# unchanged tree costs a git listing, not a rsync of 800 MB. The run dir
# records what was staged ("<name> <tree> <HEAD> <hash>" in sources.txt).
# Prints the staged path.
# Usage: staged_tree <src-tree> <name>
staged_tree() {
    local tree="$1" name="$2" src hash head
    [ -d "$tree" ] || die "staged_tree: no source tree at $tree"
    src="$(e2e_cache_dir)/src/$name"
    hash=$(_tree_hash "$tree")
    head=$(git -C "$tree" rev-parse HEAD 2>/dev/null) || head=-
    if [ -f "$src/.e2e-src-hash" ] && [ "$(cat "$src/.e2e-src-hash")" = "$hash" ]; then
        say "staged_tree: $name unchanged, reusing $src" >&2
    else
        mkdir -p "$src" || die "staged_tree: cannot create $src"
        rm -f "$src/.e2e-src-hash"
        rsync -a --delete --exclude '*/rust-lib/target' --exclude 'result' \
            --exclude 'result-*' --exclude '.git' "$tree/" "$src/" \
            || die "rsync $tree failed"
        printf '%s' "$hash" > "$src/.e2e-src-hash"
    fi
    if [ -n "${E2E_RUN_DIR:-}" ] && ! grep -qs "^$name " "$E2E_RUN_DIR/sources.txt"; then
        printf '%s %s %s %s\n' "$name" "$tree" "$head" "$hash" >> "$E2E_RUN_DIR/sources.txt"
    fi
    printf '%s' "$src"
}

# sha256 over what the copy carries: the index (blob ids + paths), the
# uncommitted diff, and the untracked file names — gitignored ones included,
# minus what rsync excludes anyway. A tree that is not a git checkout hashes
# to a fresh value every time, i.e. it is always re-synced and rebuilt.
_tree_hash() {
    local tree="$1"
    if ! git -C "$tree" rev-parse --git-dir >/dev/null 2>&1; then
        printf 'nogit-%s' "$(date +%s)"
        return
    fi
    {
        git -C "$tree" ls-files -s
        git -C "$tree" diff HEAD
        git -C "$tree" ls-files -o | grep -v -e '/rust-lib/target/' -e '^result'
    } 2>/dev/null | shasum -a 256 | cut -c1-64
}

# ── nix: retries, roots, the artifact result cache ───────────────────────────
#
# Every `nix` call on this flake costs 60-80 s before anything builds: the
# lock is ~29k nodes (336 distinct inputs duplicated down the logoscore and
# delivery subtrees), `nix flake metadata` alone takes that long, and the
# eval cache does not help. So the harness (1) remembers what each artifact
# resolved to, keyed by everything that could change the answer, and skips
# nix on a hit; (2) builds a checkout's bundles through the checkout's OWN
# flake (~15 s to evaluate), not through this one with an --override-input;
# (3) keeps every result as a GC root and in the local signed cache, since a
# `nix-collect-garbage` otherwise turns the next run into a 30-minute one.

# cache.nix.logos.co (Attic) drops NAR streams under nix's default 25
# parallel downloads; retry hard and stream fewer at once unless the caller's
# NIX_CONFIG already says so. --fallback goes on every build below.
nix_retry_cfg() {
    case "${NIX_CONFIG:-}" in *download-attempts*) return 0 ;; esac
    NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}download-attempts = 30
http-connections = 2
stalled-download-timeout = 600"
    export NIX_CONFIG
}

_e2e_sha() { printf '%s' "$1" | shasum -a 256 | cut -c1-64; }

# <cache>/artifacts/<name> holds "<key> <store path>" for the last build of
# <name>. A hit is a key match whose path still exists.
# Usage: artifact_cache_get <name> <key> -> path;  artifact_cache_put <name> <key> <path>
artifact_cache_get() {
    local f key="" path=""
    f="$(e2e_cache_dir)/artifacts/$1"
    [ -f "$f" ] || return 1
    read -r key path < "$f" || return 1
    [ "$key" = "$2" ] && [ -n "$path" ] && [ -e "$path" ] || return 1
    printf '%s' "$path"
}
artifact_cache_put() {
    local d
    d="$(e2e_cache_dir)/artifacts"
    mkdir -p "$d" && printf '%s %s\n' "$2" "$3" > "$d/$1.tmp.$$" && mv "$d/$1.tmp.$$" "$d/$1"
}

# A GC root for <path> at $RLN_GCROOTS/<link> when a release workspace set
# one. `nix build <store path>` realises an existing path without evaluating
# any flake, so re-rooting a cached result is instant.
# Usage: nix_root <link-name> <path>
nix_root() {
    [ -n "${RLN_GCROOTS:-}" ] || return 0
    mkdir -p "$RLN_GCROOTS"
    [ "$(readlink "$RLN_GCROOTS/$1" 2>/dev/null)" = "$2" ] && return 0
    nix build "$2" --out-link "$RLN_GCROOTS/$1" >/dev/null 2>&1 \
        || say "gc root $1 not created for $2 (ignored)" >&2
}

# Push <path> to the local signed cache (rln cache init).
# Usage: nix_push <path> [label]
nix_push() {
    [ -n "${RLN_NIX_CACHE:-}" ] && [ -f "${RLN_NIX_CACHE_KEY:-$HOME/.config/rln/nix-cache.sec}" ] || return 0
    nix copy --to "file://$RLN_NIX_CACHE?secret-key=${RLN_NIX_CACHE_KEY:-$HOME/.config/rln/nix-cache.sec}" "$1" >&2 \
        || say "cache push failed for ${2:-$1} (ignored)" >&2
}

# This flake's bundle attrs are re-exports of the rln-modules flake's
# packages (flake.nix); the mapping lets a checkout build through its own flake.
_modules_attr() {
    case "$1" in
        lez-rln-module-lgx) printf 'logos-lez-rln-module-lgx' ;;
        rln-module-lgx) printf 'logos-rln-module-lgx' ;;
        wallet-lgx) printf 'wallet-module' ;;
        *) return 1 ;;
    esac
}

# Build a module bundle from a WORKING TREE instead of the flake pin (see
# staged_tree for the copy semantics). The copy is built through ITS OWN
# flake, `path:<copy>#<package>`: the derivation is the one this flake's
# re-export with `--override-input rln-modules` would produce (this flake
# adds no follows to rln-modules), at a fifth of the evaluation time. An
# unchanged tree does not reach nix at all.
# Usage: module_lgx <flake-attr> <src-tree> [input-name]
module_lgx() {
    local attr="$1" tree="$2" input="${3:-rln-modules}"
    local src hash key out mattr
    src=$(staged_tree "$tree" "$input") || die "staged_tree failed for $tree"
    hash=$(cat "$src/.e2e-src-hash" 2>/dev/null) || die "staged copy $src carries no .e2e-src-hash"
    mattr=$(_modules_attr "$attr") || die "module_lgx: no rln-modules package known for .#$attr"
    key=$(_e2e_sha "$attr $input $hash $mattr")
    if out=$(artifact_cache_get "$attr-$input" "$key"); then
        say "$attr: $tree unchanged, cached $out" >&2
        nix_root "e2e-$attr-$input" "$out"
    else
        say "$attr: building path:$src#$mattr (filtered copy of $tree)" >&2
        nix_retry_cfg
        out=$(nix build "path:$src#$mattr" --no-link --print-out-paths --accept-flake-config --fallback | tail -1)
        [ -n "$out" ] && [ -e "$out" ] || die "nix build path:$src#$mattr produced no output path"
        nix_root "e2e-$attr-$input" "$out"
        nix_push "$out" "$attr"
        artifact_cache_put "$attr-$input" "$key" "$out"
    fi
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
    # -R because a ui_qml bundle carries qml/ and icons/ subdirectories, and a
    # module missing its qml loads as a broken app rather than failing outright.
    # -L stays: the tarball's entries deliberately point into /nix/store.
    # The glob is checked first — unmatched, it goes literal and cp reports a
    # path that never existed.
    [ -n "$(find "$tmp/variants/$variant" -mindepth 1 -maxdepth 1 -print -quit)" ] \
        || die "install_lgx: $lgx has an empty variants/$variant"
    cp -RL "$tmp/variants/$variant/"* "$dest/$name/" \
        || die "install_lgx: cannot stage variants/$variant from $lgx"
    printf '%s' "$variant" > "$dest/$name/variant"
    rm -rf "$tmp"
}
