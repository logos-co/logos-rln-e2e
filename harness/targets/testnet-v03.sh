# shellcheck shell=bash
# harness/targets/testnet-v03.sh — the LEZ v0.3 testnet zone
# (https://testnet.lez.logos.co), next to the rc3 `testnet` zone. Same hosted
# flow as testnet/devnet: E2E_DEPLOYMENT names a committed descriptor, and
# E2E_PAYER_WALLET the storage.json that tools/deployments/provision.sh left
# beside it outside the repo.

. "$(dirname "${BASH_SOURCE[0]}")/testnet.sh"

target_up() { _hosted_up testnet-v03; }
