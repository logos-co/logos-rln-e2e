# shellcheck shell=bash
# harness/lib/wallet.sh — wallet open/sync/funding helpers, over the node_call
# seam (host daemon now, container later).
#
# Env beyond docs/contract.md:
#   E2E_WALLET_MOD    wallet module id (default logos_execution_zone)
#   E2E_REGISTRY_MOD  registry-provider module id (default
#                     liblogos_lez_rln_module)
#   SYNC_STEP         blocks per sync_to_block call (default 3000)

. "$(dirname "${BASH_SOURCE[0]}")/daemon.sh"
. "$(dirname "${BASH_SOURCE[0]}")/chain.sh"

E2E_WALLET_MOD="${E2E_WALLET_MOD:-logos_execution_zone}"
E2E_REGISTRY_MOD="${E2E_REGISTRY_MOD:-liblogos_lez_rln_module}"
SYNC_STEP="${SYNC_STEP:-3000}"

# Usage: wallet_open <node> [wallet_home]
# storage.json is the mutable wallet; the staged fixture ships it as
# storage.json.seed so a re-run starts from the deployment's own accounts.
wallet_open() {
    local node="$1" home="${2:-${E2E_WALLET_HOME:-}}"
    [ -n "$home" ] || die "wallet_open: no wallet home (the target sets E2E_WALLET_HOME)"
    [ -f "$home/wallet_config.json" ] || die "wallet_open: no wallet_config.json in $home"
    if [ ! -f "$home/storage.json" ]; then
        cp "$home/storage.json.seed" "$home/storage.json" \
            || die "wallet_open: cannot seed $home/storage.json"
    fi
    node_call "$node" "$E2E_WALLET_MOD" open "$home/wallet_config.json" "$home/storage.json" >/dev/null \
        || die_node "$node" "wallet open failed"
}

# Sync to the chain head in SYNC_STEP chunks (a single jump over a long chain
# times the sequencer poll out). Prints the block actually reached; stops early
# when a chunk makes no progress.
# Usage: wallet_sync <node>
wallet_sync() {
    local node="$1" head cur tgt next
    head=$(chain_head) || die "wallet_sync: cannot probe chain head"
    cur=$(node_call "$node" "$E2E_WALLET_MOD" get_last_synced_block | jres | jval)
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    while [ "$cur" -lt "$head" ]; do
        tgt=$((cur + SYNC_STEP))
        [ "$tgt" -gt "$head" ] && tgt="$head"
        node_call "$node" "$E2E_WALLET_MOD" sync_to_block "$tgt" >/dev/null 2>&1
        next=$(node_call "$node" "$E2E_WALLET_MOD" get_last_synced_block | jres | jval)
        case "$next" in ''|*[!0-9]*) break ;; esac
        [ "$next" = "$cur" ] && break
        cur="$next"
    done
    printf '%s' "$cur"
}

# create_account_public derives accounts DETERMINISTICALLY from the wallet's
# key chain, so early derivations collide with accounts earlier runs already
# created on-chain — walk the chain until an account with no on-chain token
# data. Prints the account id; 1 when the walk is exhausted.
# Usage: wallet_fresh_holding <node>
wallet_fresh_holding() {
    local node="$1" acc bal_json _d
    for _d in $(seq 1 "${E2E_DERIVE_TRIES:-30}"); do
        acc=$(node_call "$node" "$E2E_WALLET_MOD" create_account_public | jres) || acc=""
        case "$acc" in ''|ERR|None) sleep 2; continue ;; esac
        bal_json=$(node_call "$node" "$E2E_REGISTRY_MOD" get_token_balance \
            "$(argfile fresh_holding "$acc")" | jres) || bal_json=""
        case "$bal_json" in
            *'"exists":false'*) printf '%s' "$acc"; return 0 ;;
        esac
    done
    return 1
}

# The faucet caps each ClaimTokens call at the deployment's claim cap —
# slice a large budget into chunks, confirming the running balance after
# each so a dropped claim fails at the right slice.
# Usage: wallet_claim_chunked <node> <config_account> <dest> <total> [chunk]
wallet_claim_chunked() {
    local node="$1" cfg="$2" dest="$3" total="$4" chunk="${5:-${E2E_CLAIM_CHUNK:-2000000}}"
    local claimed=0 take n=0
    while [ "$claimed" -lt "$total" ]; do
        take=$((total - claimed))
        [ "$take" -gt "$chunk" ] && take="$chunk"
        node_call "$node" "$E2E_REGISTRY_MOD" claim_tokens \
            "$(argfile claim_cfg "$cfg")" "$(argfile claim_dest "$dest")" "$take" | jres >/dev/null \
            || die_node "$node" "claim_tokens($take) failed"
        claimed=$((claimed + take))
        n=$((n + 1))
        wait_balance "$node" "$dest" "$claimed" >/dev/null \
            || die_node "$node" "faucet credit never reached $claimed (after claim $n)"
    done
    say "claimed $claimed RLNTOK into ${dest:0:12}… ($n claim(s))"
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
