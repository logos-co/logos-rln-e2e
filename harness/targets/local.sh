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
#                              instead of provisioning a fresh one; an extra
#                              registry's deployment is reused from
#                              <dir>-<name> when present.
#   E2E_DEVNET_TIMEOUT_S=900   readiness budget for the sequencer.
#   E2E_LOCAL_PROFILE=<name>   provision-input profile under profiles/
#                              (default local-default): tree.txt pins the
#                              tree id, wallet.storage.json is adopted so
#                              account ids repeat; tree-<name>.txt pins each
#                              extra registry of E2E_REGISTRIES. `fresh` =
#                              random trees + fresh wallet (the pre-profile
#                              behavior).
#                              Deterministic given a fixed lez-rln pin: the
#                              config account is a PDA of tree id + guest
#                              blobs (verify.sh guards guest drift).
#   E2E_PAYER=<account-id>     the funded account provisioning draws fees from.
#                              Normally left unset: host mode mints one and
#                              funds it at genesis (by its public key, which
#                              mint_payer prints beside the id). Set it in
#                              external mode, where this harness does not
#                              control genesis.
#   E2E_REGISTRIES=<names>     set by run.sh from the scenario: every name
#                              beyond `default` is one more tree provisioned
#                              on the default deployment's programs (one
#                              deploy, several registries — the shape a mix
#                              tree beside a delivery tree takes), staged
#                              under $E2E_RUN_DIR/registries/<name> and
#                              reached through harness/lib/registry.sh.
#   (There is no provision policy left to choose. Registration takes the
#   native asset and one account pays for it, so there is no funding mode, no
#   faucet cap and no free-quota registrar.)
#   The contract's poll budgets honour a pre-set env; the defaults below are
#   the contract's local values.
#
# LEZ charges a fee on every public transaction and funds accounts only in the
# genesis block, so no account created after the chain starts holds native
# balance until something transfers to it. The payer is therefore minted
# BEFORE the devnet and funded at genesis, which is why target_up mints into
# the provisioning wallet first and hands dev.sh the payer's public key (an
# rc1 genesis funds by key, not by account id).
#
# That account now pays for registrations as well as for provisioning: the
# registry takes the native asset, so the account that signs a Register also
# pays its price and its fee. A node running its own wallet gets funded FROM
# this account — see wallet_fund.
#
# Readiness is JSON-RPC getLastBlockId >= 1, never a port probe: the listener
# accepts connections before the chain produces its first block.
#
# target_down kills the dev.sh process tree unless E2E_KEEP=1.

# shellcheck source=harness/lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/registry.sh"

_LOCAL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_LOCAL_DEVNET_PID=""
_LOCAL_PAYER_WS=""

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

# Mint the fee payer into the wallet provisioning will adopt, and print its id
# on the first line and its public key on the second (mint_payer's output).
#
# The profile's wallet is copied first and the payer added to it, so the pinned
# account ids stay exactly as they were and the payer travels with them. A
# wallet that already carries a payer keeps the one it has.
_local_mint_payer() {
    local lez="$1" ws="$2" profile pdir
    mkdir -p "$ws"
    profile="${E2E_LOCAL_PROFILE:-local-default}"
    if [ "$profile" != "fresh" ]; then
        pdir="$_LOCAL_HERE/profiles/$profile"
        [ -f "$pdir/wallet.storage.json" ] && cp "$pdir/wallet.storage.json" "$ws/storage.json"
    fi
    HOME="$ws" LEE_WALLET_HOME_DIR="$ws" LEE_WALLET_PASSWORD="" \
        "$lez/lez-rln/target/release/mint_payer" 2>"$ws/mint.err" && return 0

    # A wallet written before LEZ v0.4.0-rc1 (one carrying a Private entry, or
    # none of rc1's private root) does not parse any more, so a pinned profile
    # does not survive the bump. Say so here rather than letting it surface
    # later as a wallet that will not open.
    if grep -q "Failed to parse storage file\|must have private root" "$ws/mint.err" 2>/dev/null; then
        die "profiles/$profile/wallet.storage.json predates LEZ v0.4.0-rc1 and cannot be opened.
  Regenerate it: run a local scenario with E2E_LOCAL_PROFILE=fresh E2E_KEEP=1,
  then copy the run's wallet-home/storage.json.seed over it."
    fi
    cat "$ws/mint.err" >&2
    return 1
}

_local_start_devnet() {
    local lez="$1" fund="${2:-}" log="$E2E_RUN_DIR/devnet.log"
    [ -f "$lez/dev.sh" ] || die "no logos-lez-rln checkout at $lez (set LEZ_RLN_CHECKOUT)"
    command -v cargo >/dev/null || die "dev.sh needs cargo — install Rust (https://rustup.rs)"
    say "starting devnet: $lez/dev.sh (log: $log)"
    # Monitor mode puts the job in its own process group, so target_down can
    # signal cargo and the sequencer it spawns as one tree.
    set -m
    (cd "$lez" && LEZ_RLN_GENESIS_FUND="$fund" exec bash ./dev.sh) </dev/null >>"$log" 2>&1 &
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
    # The listener only: a client of the port (another tool's wallet mid-call)
    # is not the stale sequencer.
    stale=$(lsof -ti "tcp:${port:-3040}" -sTCP:LISTEN 2>/dev/null || true)
    for p in $stale; do
        kill "$p" 2>/dev/null || true
    done
}

# Provisioning runs run_setup + derive_accounts out of the checkout and deploys
# the guest blobs, so those must be built before a fresh local deployment.
# fund_account is checked here too though provisioning never calls it: a
# self-paying node needs it, and the alternative is discovering that ten
# minutes into a deployment, after the only slow step.
_local_require_build() {
    local lez="$1" missing=""
    [ -x "$lez/lez-rln/target/release/run_setup" ] || missing="$missing lez-rln/target/release/run_setup"
    [ -x "$lez/lez-rln/target/release/derive_accounts" ] || missing="$missing lez-rln/target/release/derive_accounts"
    [ -x "$lez/lez-rln/target/release/mint_payer" ] || missing="$missing lez-rln/target/release/mint_payer"
    [ -x "$lez/lez-rln/target/release/fund_account" ] || missing="$missing lez-rln/target/release/fund_account"
    ls "$lez"/lez-rln/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/*.bin >/dev/null 2>&1 \
        || missing="$missing lez-rln/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/*.bin"
    [ -z "$missing" ] && return 0
    die "logos-lez-rln is not built for provisioning — missing:$missing

  build it (order matters — the host build strips the deploy blobs):
    cd $lez/lez-rln
    cargo risczero build --manifest-path methods/guest/Cargo.toml
    PYO3_PYTHON=\$(command -v python3) cargo build --release \\
        --bin run_setup --bin derive_accounts --bin mint_payer --bin fund_account"
}

# Usage: _local_profile_tree <registry-name>
# The profile's pinned tree for a registry — tree.txt for `default`,
# tree-<name>.txt otherwise — or nothing under the `fresh` profile (random).
# An unpinned default is allowed (random); an unpinned extra is an error, so
# a scenario's second registry id is stable across runs like the first.
_local_profile_tree() {
    local name="$1" profile pdir f
    profile="${E2E_LOCAL_PROFILE:-local-default}"
    [ "$profile" != "fresh" ] || return 0
    pdir="$_LOCAL_HERE/profiles/$profile"
    [ -d "$pdir" ] || die "no profile at profiles/$profile (E2E_LOCAL_PROFILE=fresh for a random tree)"
    f="$pdir/tree.txt"
    [ "$name" = default ] || f="$pdir/tree-$name.txt"
    if [ ! -f "$f" ]; then
        [ "$name" = default ] && return 0
        die "profiles/$profile has no tree-$name.txt for registry '$name' (E2E_REGISTRIES)"
    fi
    tr -d ' \n\r' < "$f"
}

# Usage: _local_provision <lez> <outroot> <name> <tree|""> <adopt-wallet|""> [registry]
# One deployment named <name>, its tree pinned to <tree> (random when empty),
# signed by the payer in <adopt-wallet>, provisioned under the profile's
# registry-<registry>.env (default: `default`). LEZ_RLN_{REGISTRATION,MERKLE}_PROGRAM_ID
# in the environment make run_setup reuse those programs: one deploy, more
# trees.
# Usage: _local_profile_env <registry-name>
# The profile's provisioning environment for a registry
# (registry-<name>.env: the rate-limit bounds its config is initialised
# with), or nothing when the profile is `fresh` or has no such file.
_local_profile_env() {
    local name="$1" profile pdir f
    profile="${E2E_LOCAL_PROFILE:-local-default}"
    [ "$profile" != "fresh" ] || return 0
    pdir="$_LOCAL_HERE/profiles/$profile"
    f="$pdir/registry-$name.env"
    [ -f "$f" ] || return 0
    printf '%s' "$f"
}

_local_provision() {
    local lez="$1" outroot="$2" name="$3" tree="${4:-}" adopt="${5:-}" registry="${6:-default}"
    local log="$E2E_RUN_DIR/provision-$name.log" treedesc="<fresh>" envfile
    # Seeded non-empty: bash 3.2 + set -u errors on expanding an empty array,
    # even in an append. --payer is required by provision.sh now, and is
    # always set by target_up above, so it is the natural seed.
    local -a flags=(--payer "${E2E_PAYER:?_local_provision needs E2E_PAYER}")
    _local_require_build "$lez"
    mkdir -p "$outroot"
    if [ -n "$tree" ]; then
        treedesc="${tree:0:8}…"
        flags=("${flags[@]}" --tree "$tree")
    fi
    # Adopt the wallet holding the payer key — a fresh provisioning wallet
    # holds none and could not sign a deploy.
    [ -z "$adopt" ] || flags=("${flags[@]}" --adopt-wallet "$adopt")
    envfile=$(_local_profile_env "$registry")
    [ -z "$envfile" ] || say "registry $registry: provisioning env $(grep -v '^#' "$envfile" | tr '\n' ' ')"

    say "provisioning $name on $E2E_SEQUENCER (tree $treedesc; run_setup — several minutes; log: $log)"
    (cd "$lez" && { [ -z "$envfile" ] || { set -a; . "$envfile"; set +a; }; } \
        && bash tools/deployments/provision.sh \
        --name "$name" --sequencer "$E2E_SEQUENCER" --outdir "$outroot" \
        "${flags[@]}") >>"$log" 2>&1 || {
        [ -f "$log" ] && tail -40 "$log" >&2
        die "provision.sh failed for $name — see $log"
    }
}

# Usage: _local_stage <lez> <deployment-dir> <home>
# stage.sh the deployment into a wallet home a run can mutate.
_local_stage() {
    local lez="$1" dep_dir="$2" home="$3"
    bash "$lez/tools/deployments/stage.sh" "$dep_dir" "$home" \
        || die "stage.sh failed for $dep_dir"
    # stage.sh emits the wallet as a seed; the run mutates its own copy.
    cp "$home/storage.json.seed" "$home/storage.json" \
        || die "no storage.json.seed in $home"
    # The descriptor itself, for what stage.sh does not flatten (the
    # registry's rate-limit bounds — registry_bounds in lib/registry.sh).
    cp "$dep_dir/deployment.json" "$home/deployment.json" \
        || die "no deployment.json in $dep_dir"
}

target_up() {
    section "target: local"
    for tool in curl jq python3; do
        command -v "$tool" >/dev/null || die "missing tool: $tool"
    done

    local lez devnet t0 dep_dir adopt name reg_dep tree minted
    lez="${LEZ_RLN_CHECKOUT:-$_LOCAL_HERE/../logos-lez-rln}"
    [ -d "$lez" ] && lez="$(cd "$lez" && pwd)"
    devnet="${E2E_DEVNET:-host}"
    E2E_SEQUENCER="${E2E_SEQUENCER:-http://127.0.0.1:3040/}"

    t0=$(date +%s)
    # The payer must exist before the chain does — see the note at the top of
    # this file. External mode does not control genesis, so it takes E2E_PAYER.
    _LOCAL_PAYER_WS="$E2E_RUN_DIR/payer-wallet"
    if [ "$devnet" = "host" ]; then
        _local_require_build "$lez"
        minted=$(_local_mint_payer "$lez" "$_LOCAL_PAYER_WS") \
            || die "could not mint the fee payer"
        E2E_PAYER=$(printf '%s\n' "$minted" | sed -n 1p)
        E2E_PAYER_PK=$(printf '%s\n' "$minted" | sed -n 2p)
        [ -n "$E2E_PAYER" ] && [ "${#E2E_PAYER_PK}" = 64 ] \
            || die "mint_payer printed no '<account id>' + '<public key>' pair: $minted"
        say "fee payer: $E2E_PAYER (funded at genesis by key ${E2E_PAYER_PK:0:8}…)"
    fi

    case "$devnet" in
        host)
            _local_start_devnet "$lez" "$E2E_PAYER_PK"
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
        # The attached chain may have been restarted since the deployment was
        # made, taking every account with it.
        require_registry "$E2E_SEQUENCER" "$dep_dir/deployment.json" "deployment $dep_dir"
        say "reusing deployment $dep_dir"
    else
        [ -z "$dep_dir" ] || die "E2E_DEPLOYMENT_DIR is only honoured with E2E_DEVNET=external (a fresh devnet knows no earlier tree)"
        # The payer wallet already carries the profile's accounts (see
        # _local_mint_payer), so adopt that rather than the profile file.
        adopt=""
        [ ! -f "$_LOCAL_PAYER_WS/storage.json" ] || adopt="$_LOCAL_PAYER_WS/storage.json"
        [ "${E2E_LOCAL_PROFILE:-local-default}" = fresh ] || say "provision profile: ${E2E_LOCAL_PROFILE:-local-default}"
        tree=$(_local_profile_tree default) || exit 1
        _local_provision "$lez" "$E2E_RUN_DIR/deployments" local-e2e "$tree" "$adopt" default
        dep_dir="$E2E_RUN_DIR/deployments/local-e2e"
    fi
    # The guest-drift guard: a rebuilt guest re-derives a different config for
    # the same tree_id, which otherwise surfaces as a chain bug.
    bash "$lez/tools/deployments/verify.sh" "$dep_dir" || die "verify.sh failed for $dep_dir"
    say "timing: provision $(( $(date +%s) - t0 ))s"

    t0=$(date +%s)
    E2E_DEPLOYMENT_DIR="$dep_dir"
    E2E_WALLET_HOME="$E2E_RUN_DIR/wallet-home"
    _local_stage "$lez" "$dep_dir" "$E2E_WALLET_HOME"

    E2E_TREE_ID=$(grep -oE 'LEZ_RLN_TREE_ID_HEX=[0-9a-f]{64}' "$E2E_WALLET_HOME/env.sh" | cut -d= -f2)
    E2E_CONFIG_ACCOUNT=$(tr -d '\n\r' < "$E2E_WALLET_HOME/config_account.txt")

    [ -n "$E2E_TREE_ID" ] && [ -n "$E2E_CONFIG_ACCOUNT" ] \
        || die "staged fixtures incomplete in $E2E_WALLET_HOME"
    say "timing: stage $(( $(date +%s) - t0 ))s"

    # Every registry of the run under registries/<name>: `default` is the
    # home above; each extra is one more tree initialised on the default
    # deployment's programs, paid by the same payer, staged beside it.
    E2E_REGISTRIES="${E2E_REGISTRIES:-default}"
    case " $E2E_REGISTRIES " in *" default "*) ;; *) E2E_REGISTRIES="default $E2E_REGISTRIES" ;; esac
    mkdir -p "$E2E_RUN_DIR/registries"
    ln -sfn "$E2E_WALLET_HOME" "$E2E_RUN_DIR/registries/default"
    # The payer key: the minted wallet in host mode, the reused deployment's
    # wallet in external mode (stage.sh asserted it holds the payer).
    adopt="$_LOCAL_PAYER_WS/storage.json"
    [ -f "$adopt" ] || adopt="$dep_dir/storage.json"
    for name in $E2E_REGISTRIES; do
        [ "$name" != default ] || continue
        t0=$(date +%s)
        reg_dep="$E2E_RUN_DIR/deployments/local-e2e-$name"
        # A reused deployment's extras live beside it (the layout this target
        # writes): reuse them too. provision.sh cannot re-run on a tree the
        # chain already initialised (run_setup returns early with no
        # treasury line and the script dies on it).
        if [ "$devnet" = external ] && [ -n "${E2E_DEPLOYMENT_DIR:-}" ] \
            && [ -f "$dep_dir-$name/deployment.json" ] && [ -f "$dep_dir-$name/storage.json" ]; then
            require_registry "$E2E_SEQUENCER" "$dep_dir-$name/deployment.json" "registry $name"
            reg_dep="$dep_dir-$name"
            say "reusing deployment $reg_dep"
        else
            (
                tree=$(_local_profile_tree "$name") || exit 1
                export LEZ_RLN_REGISTRATION_PROGRAM_ID LEZ_RLN_MERKLE_PROGRAM_ID
                LEZ_RLN_REGISTRATION_PROGRAM_ID=$(jq -re .registration_program_id "$dep_dir/deployment.json")
                LEZ_RLN_MERKLE_PROGRAM_ID=$(jq -re .merkle_program_id "$dep_dir/deployment.json")
                _local_provision "$lez" "$E2E_RUN_DIR/deployments" "local-e2e-$name" "$tree" "$adopt" "$name"
            ) || exit 1
        fi
        bash "$lez/tools/deployments/verify.sh" "$reg_dep" || die "verify.sh failed for $reg_dep"
        _local_stage "$lez" "$reg_dep" "$E2E_RUN_DIR/registries/$name"
        [ "$(jq -re .registration_program_id "$reg_dep/deployment.json")" = \
          "$(jq -re .registration_program_id "$dep_dir/deployment.json")" ] \
            || die "registry $name did not reuse the default deployment's programs"
        say "registry $name: tree $(registry_tree "$name" | cut -c1-8)… config $(registry_config_account "$name") rate $(registry_bounds "$name" | tr ' ' -) (provision $(( $(date +%s) - t0 ))s)"
    done

    E2E_CONFIRM_TIMEOUT_S="${E2E_CONFIRM_TIMEOUT_S:-120}"
    E2E_POLL_INTERVAL_S="${E2E_POLL_INTERVAL_S:-5}"
    E2E_EPOCH_SIZE_SEC="${E2E_EPOCH_SIZE_SEC:-60}"
    E2E_ROOT_WINDOW_TIMEOUT_S="${E2E_ROOT_WINDOW_TIMEOUT_S:-60}"
    # E2E_PAYER too: a scenario runs as its own process, and the modules it
    # loads cannot pay a fee from the freshly created holdings they sign with.
    export E2E_SEQUENCER E2E_DEPLOYMENT_DIR E2E_WALLET_HOME E2E_TREE_ID \
        E2E_CONFIG_ACCOUNT E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
        E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S E2E_PAYER E2E_REGISTRIES
    say "deployment: tree ${E2E_TREE_ID:0:8}… config $E2E_CONFIG_ACCOUNT payer $E2E_PAYER (registries: $E2E_REGISTRIES)"
}

target_down() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        [ -n "$_LOCAL_DEVNET_PID" ] \
            && say "E2E_KEEP=1: devnet pid $_LOCAL_DEVNET_PID up at $E2E_SEQUENCER (log $E2E_RUN_DIR/devnet.log)"
        say "E2E_KEEP=1: deployment ${E2E_DEPLOYMENT_DIR:-<none>}, wallet home ${E2E_WALLET_HOME:-<none>}"
        # E2E_PAYER belongs in this line: external mode does not mint one (it
        # does not control genesis), so a reattach without it dies on an
        # unbound variable before the scenario starts.
        say "E2E_KEEP=1: reattach with E2E_DEVNET=external E2E_DEPLOYMENT_DIR=${E2E_DEPLOYMENT_DIR:-<none>} E2E_PAYER=${E2E_PAYER:-<none>}"
        return 0
    fi
    [ -n "$_LOCAL_DEVNET_PID" ] || return 0
    say "stopping devnet (pid $_LOCAL_DEVNET_PID)"
    _local_kill_devnet "$_LOCAL_DEVNET_PID"
    _LOCAL_DEVNET_PID=""
_LOCAL_PAYER_WS=""
}
