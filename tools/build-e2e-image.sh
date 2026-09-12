#!/usr/bin/env bash
# Build the bootstrap image the delivery scenario runs its relay from.
#
#   ./tools/build-e2e-image.sh [-t TAG]
#
# Everything comes from logos-modules-dev, and it has to:
#   - the release catalog's delivery_module 0.2.1 predates the RLN plugin, so a
#     relay built from it cannot validate anything;
#   - only dev carries lez_core 0.4.0. 0.4.1 is built on execution-zone
#     v0.2.5-rc2 and cannot decode the deployed testnet at all — syncing dies
#     with "Parse error: Unexpected variant tag", including from a wallet it
#     wrote itself.
#
# storage_module and blockchain_module are not published to dev, so they are
# left empty; the Dockerfile guards each download and the relay needs neither.
set -uo pipefail

TAG=logos:e2e-dev
while [ $# -gt 0 ]; do
    case "$1" in
        -t) TAG="${2:?-t needs a tag}"; shift 2 ;;
        -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

DEV=https://raw.githubusercontent.com/logos-co/logos-modules-dev/refs/heads/main/logos-repo.json
LOGOS_DOCKER="${LOGOS_DOCKER:-../logos-docker}"
[ -f "$LOGOS_DOCKER/Dockerfile" ] \
    || { echo "no logos-docker checkout at $LOGOS_DOCKER (set LOGOS_DOCKER)" >&2; exit 1; }

cd "$LOGOS_DOCKER" || exit 1
exec docker build -t "$TAG" \
  --build-arg MODULES_REPO="$DEV" \
  --build-arg RLN_REPO="$DEV" \
  --build-arg DELIVERY_VERSION=0.2.1-138.g7431d480 \
  --build-arg RLN_VERSION=0.7.0-64.g53d31e3d \
  --build-arg LEZ_RLN_VERSION=2.1.0-63.gc89c7691 \
  --build-arg LEZ_CORE_VERSION=0.4.0-111.g549cf115 \
  --build-arg OPENMETRICS_VERSION=0.1.1-7.g5dbca244 \
  --build-arg STORAGE_VERSION= \
  --build-arg BLOCKCHAIN_VERSION= \
  .
