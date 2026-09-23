#!/usr/bin/env bash
# tools/build-e2e-image.sh — build the bootstrap relay image.
#
# The relay is a container so that "the peers meet at a third node" is a real
# network hop. Everything in the image is a published artifact; see
# harness/container/Dockerfile.relay for why nothing is compiled.
#
#   bash tools/build-e2e-image.sh
#   bash tools/build-e2e-image.sh -t logos:mine
#
# There is no "relay without RLN" image: delivery_module declares the RLN
# module as a dependency and will not load without it. A relay that forwards
# without validating is this image given a preset with RLN off.
#
# The labels this stamps are the image's half of the pin check. Note what that
# check can and cannot see: delivery-module records a REV, but the RLN pair
# records only a VERSION, and a version can cover two different builds — a
# dependency bump that leaves metadata.json alone produces exactly that. When
# it happens the fix is a version bump in logos-rln-modules, not a cleverer
# comparison here.
#
# The versions default to what THIS repo's pin builds, read out of the pinned
# tree by harness/resolve.py rather than typed in. That is what stops the
# image drifting from the host peers every time the pin moves.
set -euo pipefail

TAG="${E2E_RELAY_IMAGE:-logos-rln-e2e:relay}"
DELIVERY_VERSION="${DELIVERY_VERSION:-0.3.0-146.gfd00701f}"
# Derived, not hardcoded: ask the resolver what the current pin builds. An
# explicit env var still wins, which is what a release-candidate image needs.
if [ -z "${LEZ_RLN_VERSION:-}" ] || [ -z "${RLN_VERSION:-}" ]; then
    _here=$(cd "$(dirname "$0")/.." && pwd)
    _pins=$(nix build "$_here#pins" --no-link --print-out-paths --accept-flake-config | tail -1) \
        || { echo "build-e2e-image: cannot resolve the pins; set LEZ_RLN_VERSION and RLN_VERSION" >&2; exit 1; }
    # shellcheck source=/dev/null
    . "$_pins"
    _matrix=$(python3 "$_here/harness/resolve.py" --json \
                --modules-src "$E2E_RLN_MODULES_SRC" --flake-lock "$_here/flake.lock") \
        || { echo "build-e2e-image: the pin matrix is inconsistent — fix that before building an image" >&2; exit 1; }
    LEZ_RLN_VERSION="${LEZ_RLN_VERSION:-$(printf '%s' "$_matrix" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lez_rln_module"]["value"])')}"
    RLN_VERSION="${RLN_VERSION:-$(printf '%s' "$_matrix" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rln_module"]["value"])')}"
fi
RLN_INDEX="${RLN_INDEX:-https://github.com/logos-co/logos-rln-modules/releases/download/index}"

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--tag) TAG="$2"; shift 2 ;;
        --delivery-version) DELIVERY_VERSION="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null || { echo "docker is not on PATH" >&2; exit 1; }

# The delivery_module bundle names the commit it was built from; record it so
# a rebuilt-but-same-version image cannot pass the pin check silently.
DM_REV="${DELIVERY_VERSION##*.g}"

echo "relay image : $TAG"
echo "  rln       : lez $LEZ_RLN_VERSION + rln $RLN_VERSION"
echo "  delivery  : $DELIVERY_VERSION (rev $DM_REV)"

exec docker build \
    -f "$ROOT/harness/container/Dockerfile.relay" \
    -t "$TAG" \
    --build-arg "DELIVERY_VERSION=$DELIVERY_VERSION" \
    --build-arg "LEZ_RLN_VERSION=$LEZ_RLN_VERSION" \
    --build-arg "RLN_VERSION=$RLN_VERSION" \
    --build-arg "RLN_INDEX=$RLN_INDEX" \
    --label "org.logos.e2e.catalog=$RLN_INDEX" \
    --label "org.logos.delivery-module.rev=$DM_REV" \
    --label "org.logos.lez-rln-module.version=$LEZ_RLN_VERSION" \
    --label "org.logos.rln-module.version=$RLN_VERSION" \
    "$ROOT"
