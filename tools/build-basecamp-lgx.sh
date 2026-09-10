#!/usr/bin/env bash
# Build every portable .lgx needed to drive the delivery scenario by hand in
# Basecamp, and collect them into one directory.
#
#   ./tools/build-basecamp-lgx.sh [-o OUTDIR] [--core|--all] [--list]
#
# --core builds the four modules the scenario itself drives; --all (default)
# adds the two UIs and the three modules rln_membership_ui declares at runtime.
#
# Revisions are the set verified together against the hosted testnet:
# logos-delivery-module master with logos-rln-modules c89c769, the rev that
# module's own lock resolves liblogos_rln_module to.
#
# Two things this handles that a bare `nix build` does not:
#
#   * crates.io answers 403 to the user-agent-less curl nixpkgs' fetchurl
#     sends, so any uncached Rust crate FOD fails. Each round refetches the
#     crates the log names from static.crates.io, adds them under the exact
#     path the FOD expects, and roots them so a later gc cannot drop them. The
#     wallet module needs this: its closure pulls crates no Logos-side pin
#     reaches.
#   * one nix process per attribute — evaluating several at once has been
#     OOM-killed on an 11 GB machine.
set -uo pipefail

OUTDIR="$PWD/basecamp-lgx"
SET=all
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUTDIR="${2:?-o needs a path}"; shift 2 ;;
        --core) SET=core; shift ;;
        --all) SET=all; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

DM_REV=514fa12655ddfe0bc3e961dc823ceaa32210f26a       # logos-delivery-module master
RLN_REV=c89c7691d06af32c002426f3c6f6dece79dbffaa      # logos-rln-modules feat/lip-alignment
WALLET_REV=0ea57f8a1c57539d6ee0961a9cd27b064685b9e8   # logos-execution-zone-module, rln-modules' pin
DEMO_REV=49d0a05eb61d5d8eefb269d1d47537e5debe3a91     # logos-delivery-demo main
GIFTER_REV=c6d854a82cb9eb0cbc6a5c8b1f23030f74e711da   # logos-rln-gifter master
LIBP2P_REV=ec7b8f583781365389910da8b81688239661805d   # logos-libp2p-module master

# name|flake ref|attr
CORE="
delivery_module|github:logos-co/logos-delivery-module/$DM_REV|lgx-portable
liblogos_rln_module|github:logos-co/logos-rln-modules/$RLN_REV?dir=logos-rln-module|lgx-portable
liblogos_lez_rln_module|github:logos-co/logos-rln-modules/$RLN_REV?dir=logos-lez-rln-module|lgx-portable
lez_core|github:logos-blockchain/logos-execution-zone-module/$WALLET_REV|lgx-portable
"

# rln_membership_ui is a ui_qml module: its libp2p/gifter/keycard dependencies
# are declared in metadata.json but are not flake inputs, so no dependency
# collector reaches them. Hence the explicit entries.
UI="
logos_delivery_demo|github:logos-co/logos-delivery-demo/$DEMO_REV|lgx-portable
rln_membership_ui|github:logos-co/logos-rln-modules/$RLN_REV?dir=logos-rln-membership-ui|lgx-portable
libp2p_module|github:logos-co/logos-libp2p-module/$LIBP2P_REV|lgx-portable
rln_gifter_module|github:logos-co/logos-rln-gifter/$GIFTER_REV?dir=rust/rln-gifter-module|lgx-portable
keycard_capture_module|github:logos-co/logos-rln-gifter/$GIFTER_REV?dir=rust/keycard-capture-module|lgx-portable
"

case "$SET" in
    core) TARGETS="$CORE" ;;
    all)  TARGETS="$CORE$UI" ;;
esac

if [ "$LIST_ONLY" = 1 ]; then
    printf '%s\n' "$TARGETS" | grep -v '^$' | while IFS='|' read -r name ref attr; do
        printf '  %-24s %s#%s\n' "$name" "$ref" "$attr"
    done
    exit 0
fi

for tool in nix curl python3 sha256sum; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

WORK="${TMPDIR:-/tmp}/basecamp-lgx-work"
mkdir -p "$OUTDIR" "$WORK" || exit 1

# Refetch every crate FOD the log names from a host with no UA rules. Returns 0
# when it fixed at least one, so the caller knows a retry is worth it.
fix_crates() {
    local log="$1" fixed=0 fodname drv url name hash out json cname cver cpath
    for fodname in $(grep -oE "cannot download [^ ]+ from any mirror" "$log" \
                     | awk '{print $3}' | sort -u); do
        drv=$(grep -oE "/nix/store/[a-z0-9]{32}-${fodname//./\\.}\.drv" "$log" | head -1)
        [ -n "$drv" ] || continue
        json=$(nix derivation show "$drv" 2>/dev/null) || continue
        read -r url name hash out <<<"$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
def find(o):
    if isinstance(o, dict):
        if "env" in o and "builder" in o:
            return o
        for v in o.values():
            r = find(v)
            if r:
                return r
    return None
e = find(d)["env"]
print(e.get("urls", "").split()[0], e.get("name"), e.get("outputHash"), e.get("out"))
')" || continue
        [ -n "$url" ] && [ -n "$out" ] || continue
        [ -e "$out" ] && continue
        case "$url" in
            https://crates.io/api/v1/crates/*/download)
                cname=${url#https://crates.io/api/v1/crates/}
                cver=${cname#*/}; cver=${cver%/download}; cname=${cname%%/*}
                url="https://static.crates.io/crates/$cname/$cname-$cver.crate" ;;
        esac
        echo "    refetching $name"
        curl -fsSL -A "curl/8.0" -o "$WORK/$name" "$url" || continue
        [ "$(sha256sum "$WORK/$name" | cut -d' ' -f1)" = "$hash" ] || continue
        if cpath=$(nix-store --add-fixed sha256 "$WORK/$name"); then
            nix-store --add-root "$WORK/root-$name" --indirect -r "$cpath" >/dev/null 2>&1
            fixed=$((fixed + 1))
        fi
    done
    return $(( fixed > 0 ? 0 : 1 ))
}

build_one() {
    local name="$1" ref="$2" attr="$3" log out lgx round
    for round in $(seq 1 20); do
        log="$WORK/$name-$round.log"
        # --keep-going so one round names every failed crate, not just the first
        if nix build "$ref#$attr" --out-link "$WORK/result-$name" \
             --keep-going --max-jobs 1 >"$log" 2>&1; then
            out=$(readlink -f "$WORK/result-$name")
            lgx=$(find "$out/" -maxdepth 1 -name '*.lgx' | head -1)
            [ -n "$lgx" ] || { echo "  !! built, but no .lgx under $out"; return 1; }
            cp -L "$lgx" "$OUTDIR/$name.lgx" || return 1
            echo "  -> $OUTDIR/$name.lgx"
            return 0
        fi
        fix_crates "$log" || {
            echo "  !! FAILED — tail of $log:"
            tail -12 "$log" | sed 's/^/     /'
            return 1
        }
    done
    echo "  !! FAILED after 20 rounds ($log)"
    return 1
}

FAILED=0
while IFS='|' read -r name ref attr; do
    [ -n "$name" ] || continue
    echo "== $name"
    build_one "$name" "$ref" "$attr" || FAILED=$((FAILED + 1))
done <<EOF
$(printf '%s\n' "$TARGETS" | grep -v '^$')
EOF

echo
echo "bundles in $OUTDIR:"
ls -1 "$OUTDIR"/*.lgx 2>/dev/null | sed 's/^/  /' || echo "  (none)"
[ "$FAILED" = 0 ] || echo "
$FAILED module(s) failed — see the logs under $WORK"
echo "
Load these into Basecamp. Then: configureRln BEFORE createNode, and give both
peers the SAME rln-identifier."
exit "$FAILED"
