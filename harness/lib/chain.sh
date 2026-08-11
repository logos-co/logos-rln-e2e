# shellcheck shell=bash
# harness/lib/chain.sh — chain-level helpers shared by scenarios, over the
# node_call/node_logs seam (host daemon now, container later).
#
# Env beyond docs/contract.md:
#   E2E_REGISTRY_MOD  registry-provider module id (default
#                     liblogos_lez_rln_module)
#   E2E_ACTUAL_LEAF   set by confirm_and_ready to the on-chain leaf index

. "$(dirname "${BASH_SOURCE[0]}")/daemon.sh"

E2E_REGISTRY_MOD="${E2E_REGISTRY_MOD:-liblogos_lez_rln_module}"

# Usage: chain_head [endpoint]   (default $E2E_SEQUENCER)
chain_head() {
    local ep="${1:-${E2E_SEQUENCER:-}}" head
    [ -n "$ep" ] || return 1
    head=$(curl -sS -m 15 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' "$ep" \
        | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["result"])
except Exception:
    pass')
    case "$head" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$head"
}

# On-chain confirmation barrier for a membership: wait until the registry
# provider reports registered:true for our commitment on the CANONICAL tree
# BEFORE the caller proceeds, so a following registration lands on a DISTINCT
# leaf (a merkle proof alone was unreliable: it is served for the OPTIMISTIC
# leaf before the tree advances, so leaves collided). Reads the ACTUAL leaf
# into E2E_ACTUAL_LEAF and flags any mismatch with the optimistic one.
# Usage: confirm_and_ready <node> <id_commitment_hex> [optimistic_leaf] [label]
confirm_and_ready() {
    local node="$1" idc="$2" lopt="${3:-}"
    local label="${4:-$node}"
    local iv="${E2E_POLL_INTERVAL_S:-10}" res conf="" flag="" _w tries
    [ -n "${E2E_CONFIG_ACCOUNT:-}" ] || die "confirm_and_ready: E2E_CONFIG_ACCOUNT unset (the target sets it)"
    tries=$(( ${E2E_CONFIRM_TIMEOUT_S:-600} / iv ))
    [ "$tries" -lt 1 ] && tries=1
    E2E_ACTUAL_LEAF=""
    for _w in $(seq 1 "$tries"); do
        res=$(node_call "$node" "$E2E_REGISTRY_MOD" get_membership \
            "$(argfile confirm_cfg "$E2E_CONFIG_ACCOUNT")" "$(argfile confirm_idc "$idc")" | jres)
        case "$res" in
            *'"registered":true'*)
                conf=true
                E2E_ACTUAL_LEAF=$(printf '%s' "$res" | jfield leaf_index)
                break ;;
        esac
        sleep "$iv"
    done
    if [ "$conf" != "true" ]; then
        diagnose_reg "$node"
        return 1
    fi
    [ -n "$lopt" ] && [ "$lopt" != "$E2E_ACTUAL_LEAF" ] \
        && flag=" !! LEAF MISMATCH (proof for $lopt, actual $E2E_ACTUAL_LEAF)"
    say "$label confirmed leaf_opt=${lopt:-n/a} leaf_actual=$E2E_ACTUAL_LEAF$flag"
    return 0
}

# Diagnose a registration that never confirmed by scanning the node's log for
# the rln program's assert strings, then print the remediation.
# Usage: diagnose_reg <node>
diagnose_reg() {
    local node="$1" logs
    logs=$(node_logs "$node" "${E2E_DIAG_LINES:-2000}" 2>/dev/null)
    printf '%s\n' "  !! RLN registration on node '$node' did not confirm on-chain." >&2
    if printf '%s' "$logs" | grep -qiE "Insufficient balance|may be out of funds|range end index 49"; then
        cat >&2 <<EOF
  CAUSE: the run's funding account ran out of RLNTOK mid-run (each
         registration costs price_per_unit x rate_limit, read live from
         get_registry_bounds).
  FIX: claim a bigger budget — raise the scenario's rate limit budget
       (E2E_RATE_LIMIT / the scenario's claim multiplier) and re-run; nothing
       needs re-provisioning:
    E2E_RATE_LIMIT=<smaller rate> ./run.sh ${E2E_SCENARIO:-<scenario>} --target ${E2E_TARGET:-local}
EOF
    elif printf '%s' "$logs" | grep -qiE "Would exceed max total rate limit|max_total_rate_limit"; then
        cat >&2 <<EOF
  CAUSE: the RLN rate-limit pool is exhausted — this tree is effectively full.
  FIX: run against a fresh tree. --target local provisions one per run:
    ./run.sh ${E2E_SCENARIO:-<scenario>} --target local
  On testnet, provision a new deployment from the lez-rln checkout
  (tools/deployments/provision.sh, tree_id is the single knob) and commit its
  descriptor under deployments/.
EOF
    else
        cat >&2 <<EOF
  CAUSE: unknown. Inspect the node log:
    grep -iE 'register|balance|rate limit|payment|tree' $(node_log_path "$node")
EOF
    fi
}
