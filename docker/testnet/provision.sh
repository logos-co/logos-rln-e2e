#!/usr/bin/env bash
# Thin shim -> canonical logos-lez-rln/tools/deployments/provision.sh.
# FEATURE: deployment-profile tooling.
#
#   LEZ_RLN_DIR=/path/to/logos-lez-rln bash provision.sh --name <name> \
#       [--tree <64hex>] [--adopt-wallet <storage.json>] [--sequencer <url>]
#
# Provisions on the sequencer and writes the new deployment into THIS repo's build
# context (docker/testnet/deployments/) so `docker build --build-arg DEPLOYMENT=`
# stays self-contained. The provisioning logic lives once, in logos-lez-rln.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEZ_RLN_DIR="${LEZ_RLN_DIR:?set LEZ_RLN_DIR to your logos-lez-rln checkout}"
exec bash "$LEZ_RLN_DIR/tools/deployments/provision.sh" --outdir "$HERE/deployments" "$@"
