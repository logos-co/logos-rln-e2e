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
    # lez_core's open grew a third statistics_path arg with the v0.2.2 bump;
    # the file need not pre-exist. open's REPLY is unreliable in both
    # directions, so the probe below is the real verdict:
    #  - v0.2.2 open probes every sequencer inside the call
    #    (MultiSequencerClient::new), and a cold testnet LB (~15s first
    #    request) blows the QtRO reply timeout while the method keeps
    #    running daemon-side — RPC_FAILED here, wallet open moments later;
    #  - a bad storage.json fails only in the daemon log while the reply
    #    envelope stays "ok", and every later call hits "Null wallet handle".
    node_call "$node" "$E2E_WALLET_MOD" open "$home/wallet_config.json" "$home/storage.json" \
        "$home/statistics.json" >/dev/null || true
    local probe _t
    for _t in 1 2 3 4 5 6 7 8 9; do
        probe=$(node_call "$node" "$E2E_WALLET_MOD" get_last_synced_block | jres | jval)
        case "$probe" in
            ''|*[!0-9]*) sleep 10 ;;
            *) return 0 ;;
        esac
    done
    die_node "$node" "wallet never became usable after open (get_last_synced_block: '${probe:-<empty>}') — storage.json schema vs wallet module version, or the sequencer probe in open is stuck"
}

# Sync to the chain head in SYNC_STEP chunks (a single jump over a long chain
# times the sequencer poll out). Prints the block actually reached; returns 1
# when the head is NOT reached within E2E_SYNC_STALL_S of zero progress.
#
# The wallet answers no reads mid-chunk and the CLI call can time out while
# the chunk keeps running daemon-side, so "height unchanged after a chunk" is
# NOT "done": an unanswered probe means BUSY (wait), an answered-but-unchanged
# height means IDLE (the chunk ended early — re-issue it). The old
# stop-on-no-progress shape left n1 parked at block 3000 with a "synced"
# verdict, after which its lez-rln module wedged on the stale wallet.
# Usage: wallet_sync <node>
wallet_sync() {
    local node="$1" head cur tgt next now last_progress last_issue=0
    local stall_s="${E2E_SYNC_STALL_S:-600}" reissue_s="${E2E_SYNC_REISSUE_S:-30}"
    head=$(chain_head) || die "wallet_sync: cannot probe chain head"
    cur=$(node_call "$node" "$E2E_WALLET_MOD" get_last_synced_block | jres | jval)
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    tgt="$cur"
    last_progress=$(date +%s)
    while [ "$cur" -lt "$head" ]; do
        now=$(date +%s)
        if [ "$cur" -ge "$tgt" ]; then
            tgt=$((cur + SYNC_STEP))
            [ "$tgt" -gt "$head" ] && tgt="$head"
            node_call "$node" "$E2E_WALLET_MOD" sync_to_block "$tgt" >/dev/null 2>&1
            last_issue=$now
        fi
        next=$(node_call "$node" "$E2E_WALLET_MOD" get_last_synced_block | jres | jval)
        case "$next" in ''|*[!0-9]*) next="" ;; esac
        now=$(date +%s)
        if [ -n "$next" ] && [ "$next" -gt "$cur" ]; then
            cur="$next"
            last_progress=$now
        elif [ $(( now - last_progress )) -ge "$stall_s" ]; then
            printf '%s' "$cur"
            return 1
        elif [ -z "$next" ]; then
            sleep 5   # BUSY: the wallet serves no reads mid-chunk
        else
            # IDLE without progress: re-issue the chunk, at most every reissue_s.
            if [ $(( now - last_issue )) -ge "$reissue_s" ]; then
                node_call "$node" "$E2E_WALLET_MOD" sync_to_block "$tgt" >/dev/null 2>&1
                last_issue=$now
            fi
            sleep 2
        fi
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
