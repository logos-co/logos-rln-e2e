# shellcheck shell=bash
# harness/targets/testnet.sh — the hosted-testnet target.
#
# No chain lifecycle: the descriptor is committed under this repo's
# deployments/<name> (see deployments/README.md). target_up asserts the
# descriptor's sequencer answers getLastBlockId, stages the deployment into
# E2E_WALLET_HOME and exports the contract env (docs/contract.md) with the
# testnet poll budgets.
#
# Inputs beyond the contract:
#   E2E_DEPLOYMENT=<name>    descriptor dir under deployments/ — required, no
#                            default: a testnet run always names the tree it
#                            spends against.
#   LEZ_RLN_CHECKOUT=<dir>   logos-lez-rln source providing
#                            tools/deployments/stage.sh. Resolution: this var,
#                            then E2E_LEZ_RLN_SRC (harness/artifacts.sh), then
#                            the flake pin (nix build .#pins), then
#                            ../logos-lez-rln.
#   The contract's poll budgets honour a pre-set env; the defaults below are
#   the contract's testnet values.
#
# Descriptors are staged, never verified here: verify.sh re-derives program ids
# from built guest binaries, which a testnet run must not require.

_TESTNET_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_testnet_chain_head() {
    local head
    # -m 60: the hosted testnet's first request after idle can take ~15s alone
    # (cold LB); a 15s budget flaked target_up on an otherwise healthy chain.
    head=$(curl -sS -m 60 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' \
        "$1" 2>/dev/null | jq -re '.result // empty' 2>/dev/null) || return 1
    case "$head" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$head"
}

# The lez-rln source carrying tools/deployments/stage.sh.
_testnet_lez_src() {
    local pins
    if [ -n "${LEZ_RLN_CHECKOUT:-}" ]; then
        printf '%s' "$LEZ_RLN_CHECKOUT"
        return 0
    fi
    if [ -n "${E2E_LEZ_RLN_SRC:-}" ]; then
        printf '%s' "$E2E_LEZ_RLN_SRC"
        return 0
    fi
    if pins=$(nix build "$_TESTNET_HERE#pins" --no-link --print-out-paths 2>/dev/null) \
        && [ -f "$pins" ]; then
        # shellcheck disable=SC1090
        . "$pins"
        if [ -n "${E2E_LEZ_RLN_SRC:-}" ]; then
            printf '%s' "$E2E_LEZ_RLN_SRC"
            return 0
        fi
    fi
    [ -d "$_TESTNET_HERE/../logos-lez-rln" ] || return 1
    (cd "$_TESTNET_HERE/../logos-lez-rln" && pwd)
}

_testnet_deployments() {
    local d names=""
    for d in "$_TESTNET_HERE"/deployments/*/; do
        [ -f "$d/deployment.json" ] || continue
        names="$names $(basename "$d")"
    done
    printf '%s' "${names# }"
}

target_up() {
    section "target: testnet"
    for tool in curl jq python3; do
        command -v "$tool" >/dev/null || die "missing tool: $tool"
    done

    local name dep_dir lez head available
    available=$(_testnet_deployments)
    name="${E2E_DEPLOYMENT:-}"
    [ -n "$name" ] \
        || die "--target testnet needs E2E_DEPLOYMENT=<name> (deployments/: ${available:-<none committed>})"
    dep_dir="$_TESTNET_HERE/deployments/$name"
    [ -f "$dep_dir/deployment.json" ] && [ -f "$dep_dir/storage.json" ] \
        || die "no deployment 'deployments/$name' with deployment.json + storage.json (available: ${available:-<none committed>})"

    lez=$(_testnet_lez_src) \
        || die "no logos-lez-rln source for tools/deployments/stage.sh (set LEZ_RLN_CHECKOUT)"
    [ -f "$lez/tools/deployments/stage.sh" ] || die "no tools/deployments/stage.sh under $lez"

    E2E_SEQUENCER=$(jq -re '.sequencer' "$dep_dir/deployment.json") \
        || die "deployments/$name/deployment.json has no sequencer"
    head=$(_testnet_chain_head "$E2E_SEQUENCER") \
        || die "sequencer $E2E_SEQUENCER does not answer getLastBlockId (deployment '$name')"
    say "sequencer $E2E_SEQUENCER at block $head"

    E2E_DEPLOYMENT_DIR="$dep_dir"
    E2E_WALLET_HOME="$E2E_RUN_DIR/wallet-home"
    bash "$lez/tools/deployments/stage.sh" "$dep_dir" "$E2E_WALLET_HOME" \
        || die "stage.sh failed for deployments/$name"
    # stage.sh emits the wallet as a seed; the run mutates its own copy.
    cp "$E2E_WALLET_HOME/storage.json.seed" "$E2E_WALLET_HOME/storage.json" \
        || die "no storage.json.seed in $E2E_WALLET_HOME"

    E2E_TREE_ID=$(grep -oE 'LEZ_RLN_TREE_ID_HEX=[0-9a-f]{64}' "$E2E_WALLET_HOME/env.sh" | cut -d= -f2)
    E2E_CONFIG_ACCOUNT=$(tr -d '\n\r' < "$E2E_WALLET_HOME/config_account.txt")
    E2E_FUNDING=$(tr -d '\n\r' < "$E2E_WALLET_HOME/funding.txt")
    [ -n "$E2E_TREE_ID" ] && [ -n "$E2E_CONFIG_ACCOUNT" ] && [ -n "$E2E_FUNDING" ] \
        || die "staged fixtures incomplete in $E2E_WALLET_HOME"

    E2E_CONFIRM_TIMEOUT_S="${E2E_CONFIRM_TIMEOUT_S:-600}"
    E2E_POLL_INTERVAL_S="${E2E_POLL_INTERVAL_S:-10}"
    E2E_EPOCH_SIZE_SEC="${E2E_EPOCH_SIZE_SEC:-600}"
    E2E_ROOT_WINDOW_TIMEOUT_S="${E2E_ROOT_WINDOW_TIMEOUT_S:-120}"
    export E2E_SEQUENCER E2E_DEPLOYMENT_DIR E2E_WALLET_HOME E2E_TREE_ID \
        E2E_CONFIG_ACCOUNT E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
        E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S
    say "deployment: $name tree ${E2E_TREE_ID:0:8}… config $E2E_CONFIG_ACCOUNT funding $E2E_FUNDING"
}

target_down() { :; }
