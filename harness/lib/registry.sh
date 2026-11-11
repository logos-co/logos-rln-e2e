# shellcheck shell=bash
# harness/lib/registry.sh — is a deployment's registry still on the chain?
#
# A reset network keeps its sequencer URL and loses every account. A scenario
# run against a deployment from before the reset then reaches the chain fine
# and fails much later, on whichever registry read comes first, with an error
# that says nothing about why. Targets that run against an existing deployment
# call require_registry before staging it, so the run stops at the cause.

# Usage: registry_state <sequencer> <config-account-base58>
# Prints `present`, `absent` (the config account holds no program state: a
# reset network, or a deployment that never existed there) or `unreadable` (no
# usable answer). getAccount answers null for an account that does not exist,
# else {nonce, data:{actor_states:{<program>:[bytes]}}} — an account's data
# per program, the native balance under the all-ones program key.
registry_state() {
    curl -sS -m 60 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"getAccount\",\"params\":[\"$2\"],\"id\":1}" \
        "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["result"]
except Exception:
    print("unreadable"); sys.exit()
if r is None:
    print("absent"); sys.exit()
data = r.get("data") if isinstance(r, dict) else None
states = data.get("actor_states") if isinstance(data, dict) else None
if not isinstance(states, dict):
    print("unreadable"); sys.exit()
native = "1" * 32
print("present" if any(k != native and v for k, v in states.items()) else "absent")
'
}

# Usage: require_registry <sequencer> <deployment.json> <label>
# Dies unless the descriptor's config account is on the chain, naming the
# sequencer, its chain head and what to do about it.
require_registry() {
    local seq="$1" desc="$2" label="$3" cfg state head
    cfg=$(jq -re '.config_account' "$desc") || die "$label: $desc has no config_account"
    state=$(registry_state "$seq" "$cfg")
    head=$(curl -sS -m 60 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' "$seq" 2>/dev/null \
        | jq -r '.result // "?"' 2>/dev/null) || head="?"
    case "$state" in
        present) say "$label: registry config $cfg is on chain (block ${head:-?})" ;;
        absent) die "$label is not on $seq (chain at block ${head:-?}): its config account $cfg holds no \
program state. The network was probably reset. Provision a new deployment (logos-lez-rln \
tools/deployments/provision.sh) and point the run at it." ;;
        *) die "$label: cannot tell whether it is on $seq — getAccount($cfg) gave no usable answer" ;;
    esac
}

# ---------------------------------------------------------------------------
# The registries of a run. A target provisions every name in E2E_REGISTRIES
# (`default` plus a scenario's extras — docs/contract.md) and stages each as
# a wallet home under $E2E_RUN_DIR/registries/<name>; `default` is the
# E2E_WALLET_HOME the scalar contract vars describe. Scenarios address a
# registry by name through these.
# ---------------------------------------------------------------------------

# Usage: registry_stage <lez-rln source> <deployment-dir> <home>
# stage.sh a deployment (deployment.json + storage.json) into a wallet home a
# run can mutate. Shared by the local and the hosted targets.
registry_stage() {
    local lez="$1" dep_dir="$2" home="$3"
    bash "$lez/tools/deployments/stage.sh" "$dep_dir" "$home" \
        || die "stage.sh failed for $dep_dir"
    # stage.sh emits the wallet as a seed; the run mutates its own copy.
    cp "$home/storage.json.seed" "$home/storage.json" \
        || die "no storage.json.seed in $home"
    # The descriptor itself, for what stage.sh does not flatten (the
    # registry's rate-limit bounds — registry_bounds below).
    cp "$dep_dir/deployment.json" "$home/deployment.json" \
        || die "no deployment.json in $dep_dir"
}

# Usage: registry_home [name]   (default: default)
# The staged home (stage.sh output) of a registry. A run with no registries
# dir still serves `default` from E2E_WALLET_HOME.
registry_home() {
    local name="${1:-default}" dir
    dir="${E2E_RUN_DIR:?registry_home: E2E_RUN_DIR unset}/registries/$name"
    if [ ! -d "$dir" ] && [ "$name" = default ] && [ -n "${E2E_WALLET_HOME:-}" ]; then
        dir="$E2E_WALLET_HOME"
    fi
    [ -d "$dir" ] || die "no registry '$name' in this run (E2E_REGISTRIES=${E2E_REGISTRIES:-default}; the target stages one home per name)"
    printf '%s' "$dir"
}

# Usage: registry_config_account [name]   -> base58
registry_config_account() {
    local home
    home=$(registry_home "${1:-default}") || return 1
    tr -d '\n\r' < "$home/config_account.txt"
}

# Usage: registry_tree [name]   -> 64 hex
registry_tree() {
    local home
    home=$(registry_home "${1:-default}") || return 1
    grep -oE 'LEZ_RLN_TREE_ID_HEX=[0-9a-f]{64}' "$home/env.sh" | cut -d= -f2
}

# Usage: registry_bounds [name]   -> "<min> <max>"
# The inclusive rate-limit range the registry's config was initialised with,
# from the descriptor the target staged beside the home (local target).
registry_bounds() {
    local home
    home=$(registry_home "${1:-default}") || return 1
    [ -f "$home/deployment.json" ] || die "registry_bounds: no deployment.json staged for '${1:-default}'"
    jq -re '"\(.min_rate_limit) \(.max_rate_limit)"' "$home/deployment.json" \
        || die "registry_bounds: $home/deployment.json records no min_rate_limit/max_rate_limit (provisioned by a lez-rln before per-registry bounds?)"
}

# Usage: registry_id [name]
# The CAIP-10 id every module call takes:
# logos:<target>:<32-byte hex of the base58 config account>.
registry_id() {
    local cfg hex
    cfg=$(registry_config_account "${1:-default}") || return 1
    [ -n "$cfg" ] || die "registry_id: no config account staged for '${1:-default}'"
    hex=$(python3 -c '
import sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + A.index(c)
print(n.to_bytes(32, "big").hex())
' "$cfg") || die "cannot decode config account '$cfg'"
    printf 'logos:%s:%s' "${E2E_TARGET:?registry_id: E2E_TARGET unset}" "$hex"
}
