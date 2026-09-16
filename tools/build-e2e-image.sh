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
# without validating is this image with configureRln never called.
#
# The labels this stamps are the image's half of the pin check: version
# equality cannot catch a same-version-different-rev build, so the rev the
# bundle was built from is recorded here and asserted by _check_image_pins.
set -euo pipefail

TAG="${E2E_RELAY_IMAGE:-logos-rln-e2e:relay}"
DELIVERY_VERSION="${DELIVERY_VERSION:-0.2.1-138.g7431d480}"
LEZ_RLN_VERSION="${LEZ_RLN_VERSION:-4.0.0}"
RLN_VERSION="${RLN_VERSION:-0.8.0}"
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
