#!/usr/bin/env bash
# Thin shim -> canonical logos-lez-rln/tools/deployments/verify.sh (guest-drift guard).
# FEATURE: deployment-profile tooling.
#
#   LEZ_RLN_DIR=/path/to/logos-lez-rln bash verify.sh docker/testnet/deployments/<name>
set -euo pipefail
LEZ_RLN_DIR="${LEZ_RLN_DIR:?set LEZ_RLN_DIR to your logos-lez-rln checkout}"
exec bash "$LEZ_RLN_DIR/tools/deployments/verify.sh" "$@"
