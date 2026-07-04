#!/usr/bin/env bash
# Build the logos-libp2p-module .lgx for Linux from the local (unpushed)
# branches, COPY-based — no GitHub push needed. Stages the three repos into a
# clean build context (no .git / build junk / darwin librln), then Docker
# builds a Linux librln_mix + the Linux .lgx (see Dockerfile.lgx-linux).
#
# Output: ./lp2p-out/libp2p_module.lgx (Linux variant).
#
# Repos expected as siblings under ~/Waku/Logos:
#   nim-libp2p-mix (rebase/mix-cbind), mix-rln-spam-protection-plugin
#   (feat/cbind-rln), logos-libp2p-module (rebase/enable-mix), logos-rln-gifter
#   (the standalone RLN membership gifter protocol module).
set -euo pipefail

LOGOS_ROOT="${LOGOS_ROOT:-$HOME/Waku/Logos}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX=$(mktemp -d)
OUT="${1:-$HERE/lp2p-out}"

for r in nim-libp2p-mix mix-rln-spam-protection-plugin logos-libp2p-module logos-rln-gifter; do
    rsync -a \
        --exclude='.git' --exclude='build' --exclude='nimcache*' \
        --exclude='result*' --exclude='*.dylib' --exclude='vendor/librln*.a' \
        "$LOGOS_ROOT/$r/" "$CTX/$r/"
done
cp "$HERE/Dockerfile.lgx-linux" "$CTX/Dockerfile"

echo "context: $(du -sh "$CTX" | cut -f1)"
docker build --target lgx --output "type=local,dest=$OUT" "$CTX"
rm -rf "$CTX"
echo "built: $OUT/libp2p_module.lgx"
