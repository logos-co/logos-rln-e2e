# shellcheck shell=bash
# harness/lib/usertools.sh — the operator's toolchain, as released.
#
# Everything else in this repo stages modules the harness's way: nix build the
# bundles from the flake pins, then install_lgx file-copies the -dev variant
# into $E2E_MODULES_DIR. An operator does none of that. They download one
# released binary, logosctl, and let it do the work: it is the daemon, the
# client (call/watch), and — through the package_manager and
# package_downloader modules it bundles — the catalog and the installer.
#
# Packages install through the RUNNING daemon into its session dir
# (<config>/modules), so every helper here takes a node that daemon_start has
# already brought up on daemon_stack_ctl.
#
# Traps that are not obvious from the commands:
#   - The macOS binary finds its lib/ and bundled modules relative to its real
#     path: run it where it was unpacked, never through a symlink.
#   - Linux ships an AppImage. There is no FUSE in CI, so it is unpacked and
#     run through its AppRun.
#   - `package install` refuses to proceed without -y when stdin is not a
#     terminal, which it never is here.
#   - Unsigned bundles install under the default signature_policy (warn),
#     which is what our publish pipeline produces.
#
# Releases are per platform and self-contained (Qt and OpenSSL inside the
# tarball), so they are large. They are cached under E2E_USERTOOLS_DIR and
# reused across runs — a fetch marks its tree with a .ok stamp only after a
# successful extract, so an interrupted download is re-fetched rather than
# half-used.
#
# Env:
#   E2E_USERTOOLS_DIR        cache root (default <repo>/.cache/usertools)
#   E2E_LOGOSCTL_RELEASE     logosctl tag (default 0.3.0)
#   E2E_RLN_CATALOG          repo descriptor added as a catalog (default the
#                            logos-rln-modules rolling `index` release, which
#                            is where our published bundles live)
#   E2E_USERTOOLS_TIMEOUT_S  budget per logosctl package command (default 900)

. "$(dirname "${BASH_SOURCE[0]}")/compat.sh"

_UT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UT_CACHE="${E2E_USERTOOLS_DIR:-$_UT_ROOT/.cache/usertools}"

UT_LOGOSCTL_RELEASE="${E2E_LOGOSCTL_RELEASE:-0.3.0}"
UT_RLN_CATALOG="${E2E_RLN_CATALOG:-https://github.com/logos-co/logos-rln-modules/releases/download/index/logos-repo.json}"

# The platform string the release assets are named with — NOT lgx_platform's
# (that one names bundle variants and carries a -dev suffix these do not).
ut_platform() {
    local arch os
    case "$(uname -m)" in
        arm64|aarch64) arch=aarch64 ;;
        x86_64|amd64)  arch=x86_64 ;;
        *) die "usertools: no released binaries for $(uname -m)" ;;
    esac
    case "$(uname -s)" in
        Darwin) os=macos ;;
        Linux)  os=linux ;;
        *) die "usertools: no released binaries for $(uname -s)" ;;
    esac
    printf '%s-%s' "$arch" "$os"
}

# Usage: _ut_fetch <tool> <repo> <version>
# Download and extract <repo>'s release asset for this platform, print the
# extracted tree. Cached: a tree with a .ok stamp is reused as is.
_ut_fetch() {
    local tool="$1" repo="$2" ver="$3"
    local plat dest tarball url
    plat=$(ut_platform)
    dest="$UT_CACHE/$tool-$ver-$plat"
    if [ -f "$dest/.ok" ]; then
        printf '%s' "$dest"
        return
    fi
    url="https://github.com/logos-co/$repo/releases/download/$ver/$tool-$plat.tar.gz"
    say "usertools: fetching $tool $ver ($plat)" >&2
    rm -rf "$dest"
    mkdir -p "$dest" || die "usertools: cannot create $dest"
    tarball="$dest/asset.tar.gz"
    curl -fsSL --retry 3 -o "$tarball" "$url" \
        || die "usertools: download failed: $url"
    tar xzf "$tarball" -C "$dest" || die "usertools: cannot unpack $tarball"
    rm -f "$tarball"
    local appimage
    appimage=$(ls "$dest"/*.AppImage 2>/dev/null | head -1)
    if [ -n "$appimage" ]; then
        ( cd "$dest" && "$appimage" --appimage-extract >/dev/null ) \
            || die "usertools: cannot extract $appimage"
        rm -f "$appimage"
    fi
    : > "$dest/.ok"
    printf '%s' "$dest"
}

# Usage: _ut_bin <tree> <name>
# The binary inside a release tree, whatever shape it came in.
_ut_bin() {
    local tree="$1" name="$2" cand
    for cand in "$tree"/*/bin/"$name" "$tree"/bin/"$name" "$tree"/squashfs-root/AppRun; do
        [ -x "$cand" ] && { printf '%s' "$cand"; return; }
    done
    die "usertools: no $name binary under $tree"
}

ut_logosctl() { _ut_bin "$(_ut_fetch logosctl logos-logoscore-cli "$UT_LOGOSCTL_RELEASE")" logosctl; }

# Usage: _ut_ctl <node> <args…>
# logosctl against <node>'s daemon, with a budget: an install downloads
# hundreds of MB.
_ut_ctl() {
    [ "$(node_flavor "$1")" = ctl ] || die "usertools: $1 is not a logosctl node (daemon_stack_ctl)"
    NODE_CLI_TIMEOUT_S="${E2E_USERTOOLS_TIMEOUT_S:-900}" node_cli "$@"
}

# Usage: ut_catalog_add <node> [descriptor-url]
# Add a catalog on top of the built-in official one and refresh the index, so
# the next install resolves from both.
ut_catalog_add() {
    local node="${1:?ut_catalog_add <node> [url]}" url="${2:-$UT_RLN_CATALOG}"
    _ut_ctl "$node" catalog add "$url" >/dev/null \
        || die_node "$node" "usertools: catalog add failed ($url)"
    _ut_ctl "$node" catalog refresh >/dev/null \
        || die_node "$node" "usertools: catalog refresh failed"
    say "$node: catalog added: $url"
}

# Usage: ut_package_install <node> <package>…
# Install by name from the enabled catalogs. Dependencies are followed, and
# the downloader verifies each bundle against its catalog entry.
ut_package_install() {
    local node="${1:?ut_package_install <node> <package>…}"; shift
    [ $# -gt 0 ] || die "ut_package_install: no packages given"
    _ut_ctl "$node" package install "$@" -y >/dev/null \
        || die_node "$node" "usertools: package install $* failed"
}

# Usage: ut_install_file <node> <bundle.lgx>
# Install a local bundle, bypassing the catalogs. It must be a PORTABLE build
# (variants/<platform>, not -dev): a released logosctl takes nothing else.
ut_install_file() {
    local node="${1:?ut_install_file <node> <bundle.lgx>}" lgx="${2:?bundle}"
    [ -f "$lgx" ] || die "usertools: no bundle at $lgx"
    _ut_ctl "$node" package install --file "$lgx" -y >/dev/null \
        || die_node "$node" "usertools: package install --file $lgx failed"
}

# Usage: ut_installed_version <node> <package>
# The version the package manager reports for an installed package, or empty.
# Read from its inventory rather than the files on disk: what the package
# manager believes is what the test is asserting about.
ut_installed_version() {
    local node="${1:?ut_installed_version <node> <package>}" pkg="${2:?package}"
    _ut_ctl "$node" package ls --json 2>/dev/null | python3 -c '
import json, sys
pkg = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(rows, list):
    sys.exit(0)
for row in rows:
    if isinstance(row, dict) and row.get("name") == pkg:
        print(row.get("version", ""))
        break
' "$pkg"
}
