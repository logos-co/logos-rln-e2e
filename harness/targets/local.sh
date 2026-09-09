# shellcheck shell=bash
# harness/targets/local.sh — the local-sequencer target.
#
# target_up boots (or attaches to) a sequencer on 127.0.0.1:3040, provisions a
# fresh faucet-funded RLN deployment on it, stages that into a wallet home and
# exports the contract env (docs/contract.md) with the local poll budgets.
#
# Inputs beyond the contract:
#   E2E_DEVNET=host|external   host (default) runs logos-lez-rln's root dev.sh
#                              in the background: it clones the pinned
#                              sequencer source, wipes its rocksdb and starts
#                              sequencer_service on port 3040 (first boot
#                              cargo-builds it). external attaches to a
#                              sequencer already listening at E2E_SEQUENCER.
#   LEZ_RLN_CHECKOUT=<dir>     logos-lez-rln checkout carrying dev.sh and
#                              tools/deployments (default ../logos-lez-rln).
#   E2E_SEQUENCER=<url>        endpoint (default http://127.0.0.1:3040/).
#   E2E_DEPLOYMENT_DIR=<dir>   external mode only: reuse this deployment
#                              instead of provisioning a fresh one.
#   E2E_DEVNET_TIMEOUT_S=900   readiness budget for the sequencer.
#   E2E_LOCAL_PROFILE=<name>   provision-input profile under profiles/
#                              (default local-default): tree.txt pins the
#                              tree id, wallet.storage.json is adopted so
#                              account ids repeat. `fresh` = random tree +
#                              fresh wallet (the pre-profile behavior).
#                              Deterministic given a fixed lez-rln pin: the
#                              config account is a PDA of tree id + guest
#                              blobs (verify.sh guards guest drift).
#   E2E_PROVISION_FUNDING      provision policy → provision.sh flags
#   E2E_CLAIM_CAP                (faucet|wallet-key, per-claim cap,
#   E2E_REGISTRAR                free-registration registrar account,
#   E2E_FREE_QUOTA               its RegisterFree quota). Policy is
#                              immutable per tree — changing it under a
#                              pinned tree redeploys the same tree with the
#                              new policy on the fresh chain.
#   The contract's poll budgets honour a pre-set env; the defaults below are
#   the contract's local values.
#
# Readiness is JSON-RPC getLastBlockId >= 1, never a port probe: the listener
# accepts connections before the chain produces its first block.
#
# target_down kills the dev.sh process tree unless E2E_KEEP=1.

_LOCAL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_LOCAL_DEVNET_PID=""

# Chain head, or non-zero when the endpoint does not answer.
_local_chain_head() {
    local head
    head=$(curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' \
        "$1" 2>/dev/null | jq -re '.result // empty' 2>/dev/null) || return 1
    case "$head" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$head"
}

# _local_wait_chain <url> <budget_s> — block until the chain has a block.
_local_wait_chain() {
    local url="$1" budget="$2" waited=0 head
    while [ "$waited" -lt "$budget" ]; do
        head=$(_local_chain_head "$url") || head=""
        if [ -n "$head" ] && [ "$head" -ge 1 ] 2>/dev/null; then
            say "sequencer ready at $url (block $head)"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        if [ $((waited % 60)) -eq 0 ]; then
            say "  waiting for $url (${waited}s of ${budget}s)"
        fi
    done
    return 1
}

_local_start_devnet() {
    local lez="$1" log="$E2E_RUN_DIR/devnet.log"
    [ -f "$lez/dev.sh" ] || die "no logos-lez-rln checkout at $lez (set LEZ_RLN_CHECKOUT)"
    command -v cargo >/dev/null || die "dev.sh needs cargo — install Rust (https://rustup.rs)"
    say "starting devnet: $lez/dev.sh (log: $log)"
    # Monitor mode puts the job in its own process group, so target_down can
    # signal cargo and the sequencer it spawns as one tree.
    set -m
    (cd "$lez" && exec bash ./dev.sh) </dev/null >>"$log" 2>&1 &
    _LOCAL_DEVNET_PID=$!
    set +m
    # Off the job table: the group id stays valid for target_down, and the
    # shell stops reporting the job's death on the harness's own stdout.
    disown "$_LOCAL_DEVNET_PID" 2>/dev/null || true
}

_local_kill_devnet() {
    local pid="$1" waited=0 port stale p
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    while [ "$waited" -lt 10 ]; do
        _local_chain_head "$E2E_SEQUENCER" >/dev/null || return 0
        sleep 1
        waited=$((waited + 1))
    done
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    # The sequencer binary can outlive its cargo parent; dev.sh frees the port
    # the same way on its next start.
    port=$(printf '%s' "$E2E_SEQUENCER" | sed -n 's|.*://[^:/]*:\([0-9][0-9]*\).*|\1|p')
    stale=$(lsof -ti "tcp:${port:-3040}" 2>/dev/null || true)
    for p in $stale; do
        kill "$p" 2>/dev/null || true
    done
}

# Provisioning runs run_setup + derive_accounts out of the checkout and deploys
# the guest blobs, so both must be built before a fresh local deployment.
_local_require_build() {
    local lez="$1" missing=""
    [ -x "$lez/lez-rln/target/release/run_setup" ] || missing="$missing lez-rln/target/release/run_setup"
    [ -x "$lez/lez-rln/target/release/derive_accounts" ] || missing="$missing lez-rln/target/release/derive_accounts"
    ls "$lez"/lez-rln/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/*.bin >/dev/null 2>&1 \
        || missing="$missing lez-rln/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/*.bin"
    [ -z "$missing" ] && return 0
    die "logos-lez-rln is not built for provisioning — missing:$missing

  build it (order matters — the host build strips the deploy blobs):
    cd $lez/lez-rln
    cargo risczero build --manifest-path methods/guest/Cargo.toml
    PYO3_PYTHON=\$(command -v python3) cargo build --release --bin run_setup --bin derive_accounts"
}

_local_provision() {
    local lez="$1" outroot="$2" log="$E2E_RUN_DIR/provision.log"
    local profile pdir tree="" treedesc="<fresh>"
    # Seeded non-empty: bash 3.2 + set -u errors on expanding an empty array,
    # even in an append.
    local -a flags=(--funding "${E2E_PROVISION_FUNDING:-faucet}")
    _local_require_build "$lez"
    mkdir -p "$outroot"

    profile="${E2E_LOCAL_PROFILE:-local-default}"
    if [ "$profile" != "fresh" ]; then
        pdir="$_LOCAL_HERE/profiles/$profile"
        [ -d "$pdir" ] || die "no profile at profiles/$profile (E2E_LOCAL_PROFILE=fresh for a random tree)"
        if [ -f "$pdir/tree.txt" ]; then
            tree=$(tr -d ' \n\r' < "$pdir/tree.txt")
            treedesc="${tree:0:8}…"
            flags=("${flags[@]}" --tree "$tree")
        fi
        [ -f "$pdir/wallet.storage.json" ] \
            && flags=("${flags[@]}" --adopt-wallet "$pdir/wallet.storage.json")
        say "provision profile: $profile (tree $treedesc)"
    fi
    [ -n "${E2E_CLAIM_CAP:-}" ]  && flags=("${flags[@]}" --claim-cap "$E2E_CLAIM_CAP")
    [ -n "${E2E_REGISTRAR:-}" ]  && flags=("${flags[@]}" --registrar "$E2E_REGISTRAR")
    [ -n "${E2E_FREE_QUOTA:-}" ] && flags=("${flags[@]}" --quota "$E2E_FREE_QUOTA")

    say "provisioning on $E2E_SEQUENCER (run_setup — several minutes; log: $log)"
    (cd "$lez" && bash tools/deployments/provision.sh \
        --name local-e2e --sequencer "$E2E_SEQUENCER" --outdir "$outroot" \
        "${flags[@]}") >>"$log" 2>&1 || {
        [ -f "$log" ] && tail -40 "$log" >&2
        die "provision.sh failed — see $log"
    }
}

target_up() {
    section "target: local"
    for tool in curl jq python3; do
        command -v "$tool" >/dev/null || die "missing tool: $tool"
    done

    local lez devnet t0 dep_dir
    lez="${LEZ_RLN_CHECKOUT:-$_LOCAL_HERE/../logos-lez-rln}"
    [ -d "$lez" ] && lez="$(cd "$lez" && pwd)"
    devnet="${E2E_DEVNET:-host}"
    E2E_SEQUENCER="${E2E_SEQUENCER:-http://127.0.0.1:3040/}"

    t0=$(date +%s)
    case "$devnet" in
        host)
            _local_start_devnet "$lez"
            _local_wait_chain "$E2E_SEQUENCER" "${E2E_DEVNET_TIMEOUT_S:-900}" \
                || die "devnet never produced a block within ${E2E_DEVNET_TIMEOUT_S:-900}s — see $E2E_RUN_DIR/devnet.log"
            ;;
        external)
            _local_wait_chain "$E2E_SEQUENCER" 30 \
                || die "E2E_DEVNET=external but no sequencer answers getLastBlockId at $E2E_SEQUENCER"
            ;;
        *) die "E2E_DEVNET must be host|external, got '$devnet'" ;;
    esac
    say "timing: devnet-up $(( $(date +%s) - t0 ))s"

    t0=$(date +%s)
    dep_dir="${E2E_DEPLOYMENT_DIR:-}"
    if [ "$devnet" = "external" ] && [ -n "$dep_dir" ]; then
        [ -f "$dep_dir/deployment.json" ] && [ -f "$dep_dir/storage.json" ] \
            || die "E2E_DEPLOYMENT_DIR=$dep_dir has no deployment.json + storage.json"
        say "reusing deployment $dep_dir"
    else
        [ -z "$dep_dir" ] || die "E2E_DEPLOYMENT_DIR is only honoured with E2E_DEVNET=external (a fresh devnet knows no earlier tree)"
        _local_provision "$lez" "$E2E_RUN_DIR/deployments"
        dep_dir="$E2E_RUN_DIR/deployments/local-e2e"
    fi
    # The guest-drift guard: a rebuilt guest re-derives a different config for
    # the same tree_id, which otherwise surfaces as a chain bug.
    bash "$lez/tools/deployments/verify.sh" "$dep_dir" || die "verify.sh failed for $dep_dir"
    say "timing: provision $(( $(date +%s) - t0 ))s"

    t0=$(date +%s)
    E2E_DEPLOYMENT_DIR="$dep_dir"
    E2E_WALLET_HOME="$E2E_RUN_DIR/wallet-home"
    bash "$lez/tools/deployments/stage.sh" "$dep_dir" "$E2E_WALLET_HOME" \
        || die "stage.sh failed for $dep_dir"
    # stage.sh emits the wallet as a seed; the run mutates its own copy.
    cp "$E2E_WALLET_HOME/storage.json.seed" "$E2E_WALLET_HOME/storage.json" \
        || die "no storage.json.seed in $E2E_WALLET_HOME"

    E2E_TREE_ID=$(grep -oE 'LEZ_RLN_TREE_ID_HEX=[0-9a-f]{64}' "$E2E_WALLET_HOME/env.sh" | cut -d= -f2)
    E2E_CONFIG_ACCOUNT=$(tr -d '\n\r' < "$E2E_WALLET_HOME/config_account.txt")
    E2E_FUNDING=$(tr -d '\n\r' < "$E2E_WALLET_HOME/funding.txt")
    [ -n "$E2E_TREE_ID" ] && [ -n "$E2E_CONFIG_ACCOUNT" ] && [ -n "$E2E_FUNDING" ] \
        || die "staged fixtures incomplete in $E2E_WALLET_HOME"
    say "timing: stage $(( $(date +%s) - t0 ))s"

    E2E_CONFIRM_TIMEOUT_S="${E2E_CONFIRM_TIMEOUT_S:-120}"
    E2E_POLL_INTERVAL_S="${E2E_POLL_INTERVAL_S:-5}"
    E2E_EPOCH_SIZE_SEC="${E2E_EPOCH_SIZE_SEC:-60}"
    E2E_ROOT_WINDOW_TIMEOUT_S="${E2E_ROOT_WINDOW_TIMEOUT_S:-60}"
    export E2E_SEQUENCER E2E_DEPLOYMENT_DIR E2E_WALLET_HOME E2E_TREE_ID \
        E2E_CONFIG_ACCOUNT E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
        E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S
    say "deployment: tree ${E2E_TREE_ID:0:8}… config $E2E_CONFIG_ACCOUNT funding $E2E_FUNDING"
}

target_down() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        [ -n "$_LOCAL_DEVNET_PID" ] \
            && say "E2E_KEEP=1: devnet pid $_LOCAL_DEVNET_PID up at $E2E_SEQUENCER (log $E2E_RUN_DIR/devnet.log)"
        say "E2E_KEEP=1: deployment ${E2E_DEPLOYMENT_DIR:-<none>}, wallet home ${E2E_WALLET_HOME:-<none>}"
        say "E2E_KEEP=1: reattach with E2E_DEVNET=external E2E_DEPLOYMENT_DIR=${E2E_DEPLOYMENT_DIR:-<none>}"
        return 0
    fi
    [ -n "$_LOCAL_DEVNET_PID" ] || return 0
    say "stopping devnet (pid $_LOCAL_DEVNET_PID)"
    _local_kill_devnet "$_LOCAL_DEVNET_PID"
    _LOCAL_DEVNET_PID=""
}
