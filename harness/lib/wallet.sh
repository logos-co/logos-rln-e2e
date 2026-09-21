# shellcheck shell=bash
# harness/lib/wallet.sh — wallet open/sync/funding helpers, over the node_call
# seam (host daemon now, container later).
#
# Env beyond docs/contract.md:
#   E2E_REGISTRY_MOD  registry-provider module id (default
#                     liblogos_lez_rln_module)
#   E2E_FUND_AMOUNT   native balance wallet_fund sends a node's own payer
#                     (default 5e9). Size it from the FEE RESERVE (~6.5e8 per
#                     transaction), not the registry price (~1e6): the reserve
#                     dominates, and an account funded from the price alone
#                     cannot transact at all.
#   SYNC_STEP         blocks per sync_to_block call (default 3000)

. "$(dirname "${BASH_SOURCE[0]}")/daemon.sh"
. "$(dirname "${BASH_SOURCE[0]}")/chain.sh"

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
            *'"state":"ready"'*) return 0 ;;
            # Branch on state, not on ready: "pending" is worth waiting on,
            # "failed" never resolves. An empty reply is the module not yet
            # answering calls at all, which is also worth waiting on.
            ''|*'"state":"pending"'*) sleep "$iv" ;;
            *) die_node "$node" "registry wallet failed to come up: $st" ;;
        esac
    done
    die_node "$node" "registry wallet never became ready (last: ${st:-<empty>})"
}

# Kept under their old names so scenarios read unchanged; both now mean "wait
# for the module's own wallet to be usable".
#
# wallet_open takes a node and nothing else. It USED to accept a wallet-home
# directory and silently discard it, so callers that carefully copied a home
# per node were in fact all sharing the staged one. Choosing a home is
# daemon_wallet_home's job and has to happen before daemon_start, since the
# module reads it from the daemon's environment at load.
wallet_open() {
    [ "$#" -le 1 ] \
        || die "wallet_open takes a node only — set a per-node home with daemon_wallet_home before daemon_start"
    wallet_ready "$1"
}
wallet_sync() { wallet_ready "$1"; }

# The account the registry module signs and pays with. Since the registry
# became single-asset one account does everything: it signs the Register tx,
# pays rate_limit x price_per_unit of NATIVE balance and pays the fee. The
# module derives it at bring-up when nothing configured one, and publishes it
# here precisely so something outside can fund it.
# Usage: wallet_payer <node>
wallet_payer() {
    local node="${1:?wallet_payer <node>}" payer
    payer=$(node_call "$node" "$E2E_REGISTRY_MOD" wallet_status | jres | jfield payer) || payer=""
    [ -n "$payer" ] || die_node "$node" "the registry module published no payer account"
    printf '%s' "$payer"
}

# Live NATIVE balance of <account>, or of the node's own payer when omitted.
# Prints a decimal string; "" when the module could not answer.
#
# "" is NOT zero and must not be compared as such: an unreachable sequencer
# would read as a broke account, and a caller waiting to afford a registration
# would stop waiting.
# Usage: wallet_native_balance <node> [account]
wallet_native_balance() {
    local node="${1:?wallet_native_balance <node> [account]}" acct="${2:-}" reply
    reply=$(node_call "$node" "$E2E_REGISTRY_MOD" get_native_balance \
        "$(argfile "native_balance_$node" "$acct")" | jres) || reply=""
    printf '%s' "$reply" | jfield balance
}

# Transfer native balance into an account, named by id.
#
# No program can mint native balance, so this is the one step the module stack
# cannot do for itself — it waits for exactly this transfer before it
# registers. The signing is lez-rln's `fund_account` rather than anything here:
# the transaction carries chain-read nonces and a v0.2.5 FeeDeclaration, and
# rebuilding that in bash would be reimplementing a format that changes with
# the chain.
#
# It takes an account rather than a node because not everything that derives a
# payer is a harness node: Basecamp embeds logos-core and is driven through the
# QML inspector, so node_call cannot reach it — see basecamp_fund.
# Usage: wallet_fund_account <account> <amount>
wallet_fund_account() {
    local to="${1:?wallet_fund_account <account> <amount>}"
    local amount="${2:?wallet_fund_account <account> <amount>}"
    local lez="${LEZ_RLN_CHECKOUT:-$E2E_ROOT/../logos-lez-rln}"
    local bin="$lez/lez-rln/target/release/fund_account"
    [ -x "$bin" ] || die "no fund_account at $bin — build it:
    (cd $lez/lez-rln && cargo build --release --bin fund_account)"
    ( cd "$lez/lez-rln" && LEE_WALLET_HOME_DIR="$E2E_WALLET_HOME" \
        NSSA_WALLET_HOME_DIR="$E2E_WALLET_HOME" LEZ_RLN_PAYER="$E2E_PAYER" \
        "$bin" --to "$to" --amount "$amount" ) >/dev/null \
        || die "fund_account failed (from $E2E_PAYER to $to)"
}

# Fund a node's payer, then wait for the balance to land.
#
# Amount defaults to E2E_FUND_AMOUNT, sized for several registrations: the fee
# RESERVE (~6.5e8 per transaction) dominates the registry price (~1e6), so an
# amount chosen from the price alone funds an account that cannot transact.
# Usage: wallet_fund <node> [amount]
wallet_fund() {
    local node="${1:?wallet_fund <node> [amount]}" amount="${2:-${E2E_FUND_AMOUNT:-5000000000}}"
    # Only a self-paying node has an account of its own to fund. Anywhere else
    # the module was handed the deployment's shared payer, so this would
    # transfer that account's balance to itself and then wait for it to grow —
    # a hang with no cause in the log. Refuse instead of doing nothing slowly.
    [ "$(node_self_paying "$node")" = 1 ] \
        || die_node "$node" "wallet_fund needs a node with its own payer — call daemon_self_paying before daemon_start"

    # wallet_payer dies on an empty answer, but this call is a command
    # substitution: the die runs in the subshell, prints, and leaves the parent
    # running with payer="". The observed result was two failures — the real
    # one, then `fund_account --to ''` — with the second reading like the
    # cause. Check here so the first message is the only one.
    local payer
    payer=$(wallet_payer "$node") || exit 1
    [ -n "$payer" ] || die_node "$node" "no payer to fund"
    say "$node: funding its payer $payer with $amount native"
    wallet_fund_account "$payer" "$amount"

    wallet_wait_native "$node" "$amount"
}

# Poll until the node's payer holds at least <want> native.
# Prints the last balance seen; 1 when the budget runs out.
# Usage: wallet_wait_native <node> <want>
wallet_wait_native() {
    local node="$1" want="$2" bal="" _w tries
    local iv="${E2E_POLL_INTERVAL_S:-5}"
    tries=$(( ${E2E_CONFIRM_TIMEOUT_S:-180} / iv ))
    [ "$tries" -lt 1 ] && tries=1
    for _w in $(seq 1 "$tries"); do
        bal=$(wallet_native_balance "$node")
        # An empty answer is "could not ask", not "holds nothing" — keep
        # waiting rather than treating a failed read as a verdict.
        case "$bal" in
            ''|*[!0-9]*) sleep "$iv"; continue ;;
        esac
        if [ "$bal" -ge "$want" ]; then printf '%s' "$bal"; return 0; fi
        sleep "$iv"
    done
    printf '%s' "${bal:-0}"
    return 1
}
