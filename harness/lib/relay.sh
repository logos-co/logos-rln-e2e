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
# The image's RLN modules are PUBLISHED artifacts pulled at build time, while
# the host peers load whatever this run just built. Nothing keeps those two in
# step, and when they drift the container simply behaves like the older module:
# the failure surfaces as a missing field several calls later, reading like a
# module bug rather than a stale image. Dockerfile.relay has promised this check
# by name since it was written; it did not exist.
#
# Compared only when RLN is on — an E2E_RELAY_RLN=0 relay forwards without
# loading the registry at all, so its versions cannot matter.
_relay_check_image_pins() {
    local label want have m
    for m in lez-rln rln; do
        case "$m" in
            lez-rln) label=liblogos_lez_rln_module ;;
            rln)     label=liblogos_rln_module ;;
        esac
        [ -f "$E2E_MODULES_DIR/$label/manifest.json" ] || continue
        want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' \
            "$E2E_MODULES_DIR/$label/manifest.json" 2>/dev/null)
        have=$(docker image inspect "$E2E_RELAY_IMAGE" \
            --format "{{index .Config.Labels \"org.logos.$m-module.version\"}}" 2>/dev/null)
        [ -n "$want" ] || continue
        # A Go template prints `<no value>` for a key a map does not hold, so
        # that string is the absent case, not a version.
        [ "$have" = "<no value>" ] && have=""
        # No label at all is not "nothing to compare" — it is an image this
        # repo's build script did not stamp, so nothing says which modules are
        # inside it. That is the very state the check exists to refuse: a bare
        # `docker build -f harness/container/Dockerfile.relay .` produces one,
        # carrying whatever the ARG defaults happen to say.
        [ -n "$have" ] || die "relay: $E2E_RELAY_IMAGE carries no \
org.logos.$m-module.version label, so what it holds is unknown.

  Build it with the script that stamps the labels:

    bash tools/build-e2e-image.sh"
        [ "$want" = "$have" ] && continue
        die "relay: $E2E_RELAY_IMAGE carries $label $have, this run built $want.

  The image pulls PUBLISHED module artifacts; a version this run has not
  released cannot be in it. Either publish $label $want and rebuild the image:

    bash tools/build-e2e-image.sh

  or run the relay without RLN, which loads no registry module at all:

    E2E_RELAY_RLN=0 ./run.sh delivery-relay-rln --target local"
    done
}

relay_up() {
    local node="${1:?relay_up <node>}" seq home _t
    docker image inspect "$E2E_RELAY_IMAGE" >/dev/null 2>&1 \
        || die "relay: no image $E2E_RELAY_IMAGE — build it: bash tools/build-e2e-image.sh"
    [ "$E2E_RELAY_RLN" = 1 ] && _relay_check_image_pins
    docker rm -f "$E2E_RELAY_NAME" >/dev/null 2>&1 || true

    # ${a[@]+"${a[@]}"}: bash 3.2 treats an empty array as unset under set -u
    # (see compat.sh — stock macOS bash is the floor here).
    local -a env_args=()
    if [ "$E2E_RELAY_RLN" = 1 ]; then
        seq=$(relay_sequencer_url)
        # The relay gets a wallet of its OWN: the staged wallet_config.json
        # and nothing else, so the module creates a fresh wallet there and
        # derives a payer only it holds. The harness then funds that account,
        # exactly as it funds a host peer's.
        #
        # Two earlier shapes are worth not repeating. Handing it only
        # LEZ_RLN_PAYER_KEY does not work even though the import reports
        # success: an account's identity is not recoverable from its `sk`
        # alone (the seed carries `ssk` too, and the FFI import takes one
        # key), so the wallet holds a DIFFERENT account than LEZ_RLN_PAYER
        # names and the first charged transaction fails with "Fee payer's
        # signing key is not held by this wallet". And copying the staged
        # storage.json works but is not per-node: derivation is deterministic
        # from the seed, so the relay would derive the same account as every
        # peer that copied the same wallet.
        home="$E2E_RUN_DIR/wallet-$node"
        # The same helper the host peers use, rather than the same three lines
        # written again: it builds the home AND records that this node pays
        # for itself, which is what wallet_fund checks before it will fund a
        # node's own payer. Built by hand, the home was right and the flag was
        # missing, so funding the relay died on a guard describing exactly the
        # setup it already had.
        daemon_self_paying "$node" "$home"
        # The staged config names the sequencer the HOST reaches (127.0.0.1),
        # which inside a container is the container. An existing
        # wallet_config.json is authoritative — the module will not rewrite it
        # from LEZ_RLN_SEQUENCER — so left alone the wallet dials its own
        # loopback and every account read fails with "client error (Connect)"
        # while wallet_status still says ready. It is copied rather than left
        # to the module to self-provision because the gas limit staged
        # alongside it is what a registration needs.
        python3 - "$home/wallet_config.json" "$seq" <<'EOF' || die "relay: cannot point the wallet config at $seq"
import json, sys
path, seq = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["sequencer_addr"] = seq
for entry in cfg.get("sequencers", []):
    entry["sequencer_addr"] = seq
json.dump(cfg, open(path, "w"), indent=2)
EOF
        env_args+=(-e "LEZ_RLN_SEQUENCER=$seq"
                   -e "LEZ_RLN_TREE_ID_HEX=${E2E_TREE_ID:?relay: E2E_TREE_ID unset}"
                   -e "LEE_WALLET_HOME_DIR=$home"
                   -e "NSSA_WALLET_HOME_DIR=$home")
        # Deliberately does not name E2E_PAYER: this node derives its own and the
        # harness funds it, so printing the deployment payer here described the
        # arrangement this commit replaced.
        say "relay: sequencer $seq, wallet home $home (derives its own payer)"
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
