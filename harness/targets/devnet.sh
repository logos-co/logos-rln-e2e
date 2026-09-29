# shellcheck shell=bash
# harness/targets/devnet.sh — the LEZ devnet (networks/devnet.env).
#
# The same hosted-network target as testnet (harness/targets/testnet.sh
# _hosted_up); only the network differs. Provision and fund it with
# tools/network/provision.sh networks/devnet.env; runs then read the payer
# wallet it left under ~/.local/share/logos-rln-e2e/devnet/ (override with
# E2E_PAYER_WALLET).

# shellcheck source=harness/targets/testnet.sh
. "$(dirname "${BASH_SOURCE[0]}")/testnet.sh"

target_up() { _hosted_up devnet; }
