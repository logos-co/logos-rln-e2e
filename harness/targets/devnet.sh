# shellcheck shell=bash
# harness/targets/devnet.sh — the LEZ devnet (networks/devnet.env).
#
# The same hosted-network target as testnet (harness/targets/testnet.sh
# _hosted_up); only the network differs. docs/networks.md has the funding and
# provisioning notes for the current devnet; runs read the payer wallet from
# E2E_PAYER_WALLET (default under ~/.local/share/logos-rln-e2e/devnet/).

# shellcheck source=harness/targets/testnet.sh
. "$(dirname "${BASH_SOURCE[0]}")/testnet.sh"

target_up() { _hosted_up devnet; }
