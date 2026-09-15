# shellcheck shell=bash
# harness/lib/relay.sh — the bootstrap relay: a delivery node in a container
# that the host peers meet at and never dial past.
#
# It is an ordinary harness node. daemon_register_container puts it behind the
# same node_call/node_logs/daemon_load_modules/daemon_stop seam as a host
# daemon, so a scenario registers and drives it with the SAME functions it
# uses for n1 and n2 — there is no second register path here.
#
# Env beyond docs/contract.md:
#   E2E_RELAY_IMAGE   image to run (default logos-rln-e2e:relay; build it with
#                     tools/build-e2e-image.sh)
#   E2E_RELAY_NAME    container name (default e2e-relay)
#   E2E_RELAY_PORT    libp2p tcp port, published on 127.0.0.1 (default 61890)
#   E2E_RELAY_RLN     1 (default) the relay holds a membership and validates
#                     what it forwards; 0 it relays blind. This is a SCENARIO
#                     switch, not an image one — delivery_module depends on
#                     liblogos_rln_module either way, so the same image serves
#                     both and 0 simply never calls configureRln.

. "$(dirname "${BASH_SOURCE[0]}")/daemon.sh"
. "$(dirname "${BASH_SOURCE[0]}")/wallet.sh"

E2E_RELAY_IMAGE="${E2E_RELAY_IMAGE:-logos-rln-e2e:relay}"
E2E_RELAY_NAME="${E2E_RELAY_NAME:-e2e-relay}"
E2E_RELAY_PORT="${E2E_RELAY_PORT:-61890}"
E2E_RELAY_RLN="${E2E_RELAY_RLN:-1}"
RELAY_CFG_DIR=/var/lib/logos/config

# Print $E2E_SEQUENCER as the CONTAINER must address it. A local target serves
# on 127.0.0.1, which inside a container is the container itself;
# host.docker.internal is the host, and --add-host makes that name resolve on
# Linux too. The rewrite is on the URL passed as LEZ_RLN_SEQUENCER — no wallet
# config file is written from out here, because the module writes its own.
relay_sequencer_url() {
    local url="${1:-${E2E_SEQUENCER:?relay_sequencer_url: E2E_SEQUENCER unset}}"
    printf '%s' "$url" | sed -E 's#://(127\.0\.0\.1|localhost|0\.0\.0\.0)(:|/|$)#://host.docker.internal\2#'
}

# Usage: relay_up <node>
# Start the container, wait for its daemon, and adopt it as <node>.
relay_up() {
    local node="${1:?relay_up <node>}" seq key _t
    docker image inspect "$E2E_RELAY_IMAGE" >/dev/null 2>&1 \
        || die "relay: no image $E2E_RELAY_IMAGE — build it: bash tools/build-e2e-image.sh"
    docker rm -f "$E2E_RELAY_NAME" >/dev/null 2>&1 || true

    # ${a[@]+"${a[@]}"}: bash 3.2 treats an empty array as unset under set -u
    # (see compat.sh — stock macOS bash is the floor here).
    local -a env_args=()
    if [ "$E2E_RELAY_RLN" = 1 ]; then
        seq=$(relay_sequencer_url)
        # The container gets a funded KEY, not a wallet: with an empty
        # LEE_WALLET_HOME_DIR the module writes its own config (gas limit
        # included) and imports this key as the fee payer. Handing it a
        # storage.json would make a second writer of a module-owned file.
        key=$(wallet_payer_key "${E2E_WALLET_HOME:?relay: E2E_WALLET_HOME unset}/storage.json.seed" \
                "${E2E_PAYER:?relay: E2E_PAYER unset (the local target mints one)}") \
            || die "relay: no secret key for payer $E2E_PAYER — it cannot pay a fee, and that surfaces much later as 'Incorrect fee'"
        env_args+=(-e "LEZ_RLN_SEQUENCER=$seq"
                   -e "LEZ_RLN_TREE_ID_HEX=${E2E_TREE_ID:?relay: E2E_TREE_ID unset}"
                   -e "LEZ_RLN_PAYER=$E2E_PAYER"
                   -e "LEZ_RLN_PAYER_KEY=$key")
        say "relay: sequencer $seq, payer $E2E_PAYER"
    else
        say "relay: RLN off (E2E_RELAY_RLN=0) — forwarding without validating"
    fi

    # The run dir is mounted at the SAME absolute path so argfile's @/abs/path
    # arguments resolve identically on both sides of the seam.
    mkdir -p "${E2E_RUN_DIR:?relay: E2E_RUN_DIR unset}/args"
    docker run -d --name "$E2E_RELAY_NAME" \
        --add-host=host.docker.internal:host-gateway \
        -p "127.0.0.1:$E2E_RELAY_PORT:$E2E_RELAY_PORT" \
        -v "$E2E_RUN_DIR:$E2E_RUN_DIR" \
        -e "LOGOSCORE_CONFIG_DIR=$RELAY_CFG_DIR" \
        ${env_args[@]+"${env_args[@]}"} \
        "$E2E_RELAY_IMAGE" >/dev/null \
        || die "relay: docker run failed"
    daemon_register_container "$node" "$E2E_RELAY_NAME" "$RELAY_CFG_DIR"

    for _t in $(seq 1 30); do
        if docker exec "$E2E_RELAY_NAME" logoscore --json list-modules >/dev/null 2>&1; then
            say "$node: relay daemon up (image $E2E_RELAY_IMAGE, port $E2E_RELAY_PORT)"
            [ "$E2E_RELAY_RLN" = 1 ] && relay_check_chain "$node"
            return 0
        fi
        sleep 1
    done
    die_node "$node" "relay daemon never answered list-modules"
}

# The container reaching the chain is worth proving BEFORE modules load: a
# wallet that cannot see the sequencer just sits in "syncing" and the failure
# surfaces as an unrelated timeout much later.
relay_check_chain() {
    local node="$1" seq body
    seq=$(relay_sequencer_url)
    body=$(docker exec "$(node_container "$node")" curl -sS --max-time 20 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getLastBlockId","params":[]}' \
        "$seq" 2>/dev/null) || body=""
    case "$body" in
        *result*) say "$node: sequencer reachable from the container ($seq)" ;;
        *) die_node "$node" "relay cannot reach the sequencer at $seq — got: ${body:-<nothing>}" ;;
    esac
}

# Usage: relay_maddr <node>
# The multiaddr the HOST peers dial. The container publishes its port on
# loopback, so the host address is 127.0.0.1 — never the 172.17 bridge IP,
# which is not routable from the host on Docker Desktop.
relay_maddr() {
    local node="${1:?relay_maddr <node>}" peerid
    peerid=$(node_call "$node" delivery_module getNodeInfo MyPeerId | jres | jval)
    [ -n "$peerid" ] || die_node "$node" "relay: empty MyPeerId"
    printf '/ip4/127.0.0.1/tcp/%s/p2p/%s' "$E2E_RELAY_PORT" "$peerid"
}

relay_down() { daemon_stop "${1:?relay_down <node>}"; }
