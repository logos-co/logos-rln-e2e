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
# usable answer). Reads both account shapes: LEZ v0.3.0 ({nonce, data:{shards:
# {<program>:[bytes]}}}, the native balance under the all-ones program key) and
# v0.2.5 ({program_owner, balance, data:[bytes]}).
registry_state() {
    curl -sS -m 60 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"getAccount\",\"params\":[\"$2\"],\"id\":1}" \
        "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["result"]
except Exception:
    print("unreadable"); sys.exit()
if not isinstance(r, dict):
    print("absent"); sys.exit()
data = r.get("data")
if isinstance(data, dict):
    native = "1" * 32
    shards = data.get("shards") or {}
    print("present" if any(k != native and v for k, v in shards.items()) else "absent")
elif isinstance(data, list):
    print("present" if data else "absent")
else:
    print("unreadable")
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
