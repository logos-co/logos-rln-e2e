# shellcheck shell=bash
# harness/lib/wallet.sh — wallet open/sync/funding helpers, over the node_call
# seam (host daemon now, container later).
#
# Env beyond docs/contract.md:
#   E2E_WALLET_MOD    wallet module id (default lez_core; was
#                     logos_execution_zone before its 01c6f40 rename)
#   E2E_REGISTRY_MOD  registry-provider module id (default
#                     liblogos_lez_rln_module)
#   SYNC_STEP         blocks per sync_to_block call (default 3000)

. "$(dirname "${BASH_SOURCE[0]}")/daemon.sh"
. "$(dirname "${BASH_SOURCE[0]}")/chain.sh"

E2E_WALLET_MOD="${E2E_WALLET_MOD:-lez_core}"
E2E_REGISTRY_MOD="${E2E_REGISTRY_MOD:-liblogos_lez_rln_module}"
SYNC_STEP="${SYNC_STEP:-3000}"

# Usage: wallet_ready <node>
# Wait until the registry module's own wallet is open and caught up.
#
# Since liblogos_lez_rln_module 3.0.0 the module owns its wallet in-process:
# it adopts the staged home named by LEE_WALLET_HOME_DIR (config, storage and
# the payer's derivation together) and brings it up on its own thread at load.
# So there is nothing for a scenario to open — and nothing may open it, since
# lez_core opening that same storage.json would make two writers of one file.
# What a scenario waits for instead is readiness.
wallet_ready() {
    local node="${1:?wallet_ready <node>}" st _t tries
    local iv="${E2E_POLL_INTERVAL_S:-5}"
    tries=$(( ${E2E_WALLET_READY_S:-300} / iv ))
    [ "$tries" -lt 1 ] && tries=1
    for _t in $(seq 1 "$tries"); do
        st=$(node_call "$node" "$E2E_REGISTRY_MOD" wallet_status | jres) || st=""
        case "$st" in
            *'"ready":true'*) return 0 ;;
            # An empty detail is a slow start; a populated one is the reason
            # it gave up, and waiting longer will not fix it.
            ''|*'"detail":""'*) sleep "$iv" ;;
            *) die_node "$node" "registry wallet failed to come up: $st" ;;
        esac
    done
    die_node "$node" "registry wallet never became ready (last: ${st:-<empty>})"
}

# Kept under their old names so scenarios read unchanged; both now mean "wait
# for the module's own wallet to be usable".
wallet_open() { wallet_ready "$1"; }
wallet_sync() { wallet_ready "$1"; }

# Derivation is DETERMINISTIC from the wallet's key chain, so early slots
# collide with accounts earlier runs already created on-chain — walk until one
# has no on-chain token data. Prints the account id; 1 when the walk is
# exhausted.
#
# It asks the registry module, not lez_core: since 3.0.0 the wallet that signs
# is the registry module's own, and an account derived anywhere else is one it
# holds no key for.
# Usage: wallet_fresh_holding <node>
wallet_fresh_holding() {
    local node="$1" acc bal_json _d
    for _d in $(seq 1 "${E2E_DERIVE_TRIES:-30}"); do
        acc=$(node_call "$node" "$E2E_REGISTRY_MOD" create_holding_account | jres) || acc=""
        case "$acc" in ''|ERR|None) sleep 2; continue ;; esac
        bal_json=$(node_call "$node" "$E2E_REGISTRY_MOD" get_token_balance \
            "$(argfile fresh_holding "$acc")" | jres) || bal_json=""
        case "$bal_json" in
            *'"exists":false'*) printf '%s' "$acc"; return 0 ;;
        esac
    done
    return 1
}

# Poll until <account> holds at least <want> RLNTOK (credit lands async).
# Prints the last seen balance; 1 when the budget runs out.
# Usage: wait_balance <node> <account> <want>
wait_balance() {
    local node="$1" acct="$2" want="$3" bal=0 _w tries
    local iv="${E2E_POLL_INTERVAL_S:-5}"
    tries=$(( ${E2E_CONFIRM_TIMEOUT_S:-180} / iv ))
    [ "$tries" -lt 1 ] && tries=1
    for _w in $(seq 1 "$tries"); do
        bal=$(node_call "$node" "$E2E_REGISTRY_MOD" get_token_balance \
            "$(argfile wait_balance "$acct")" | jres | jfield balance)
        case "$bal" in ''|*[!0-9]*) bal=0 ;; esac
        if [ "$bal" -ge "$want" ]; then printf '%s' "$bal"; return 0; fi
        sleep "$iv"
    done
    printf '%s' "$bal"
    return 1
}
