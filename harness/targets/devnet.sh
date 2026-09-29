# shellcheck shell=bash
# harness/targets/devnet.sh — a hosted LEZ devnet whose payer holds real funds.
#
# Like testnet: no chain lifecycle, the programs are already provisioned and
# the descriptor names them. The difference is the wallet. A devnet payer is
# funded by a bedrock deposit into the zone (docs/devnet.md), so its
# storage.json is a spendable key and is never committed: the public half of
# the descriptor lives in deployments/<name>/deployment.json and the wallet is
# handed in from outside the repo. target_up puts the two together under the
# run dir and stages them exactly as testnet.sh does.
#
# Inputs beyond the contract:
#   E2E_DEPLOYMENT=<name>      descriptor dir under deployments/ (default
#                              devnet-z2)
#   E2E_PAYER_WALLET=<file>    storage.json holding the descriptor's payer
#                              (default ~/.local/share/logos-rln-e2e/devnet/
#                              deployments/<name>/storage.json)
#   LEZ_RLN_CHECKOUT=<dir>     as for testnet.sh
#   E2E_FUND_AMOUNT            per-node funding; defaults to 1e9 here so one
#                              deposit lasts (a registration needs ~6.5e8)

# shellcheck source=harness/targets/testnet.sh
. "$(dirname "${BASH_SOURCE[0]}")/testnet.sh"

target_up() {
    section "target: devnet"
    for tool in curl jq python3; do
        command -v "$tool" >/dev/null || die "missing tool: $tool"
    done

    local name desc wallet dep_dir
    name="${E2E_DEPLOYMENT:-devnet-z2}"
    desc="$_TESTNET_HERE/deployments/$name/deployment.json"
    [ -f "$desc" ] || die "no descriptor deployments/$name/deployment.json (available: $(_testnet_deployments))"
    wallet="${E2E_PAYER_WALLET:-$HOME/.local/share/logos-rln-e2e/devnet/deployments/$name/storage.json}"
    [ -f "$wallet" ] \
        || die "no payer wallet at $wallet — set E2E_PAYER_WALLET to the storage.json holding $(jq -r '.payer_account' "$desc")"

    dep_dir="$E2E_RUN_DIR/deployment-$name"
    mkdir -p "$dep_dir"
    cp "$desc" "$dep_dir/deployment.json"
    cp "$wallet" "$dep_dir/storage.json"
    chmod 600 "$dep_dir/storage.json"

    _testnet_stage "$name" "$dep_dir"

    E2E_FUND_AMOUNT="${E2E_FUND_AMOUNT:-1000000000}"
    export E2E_FUND_AMOUNT
}
