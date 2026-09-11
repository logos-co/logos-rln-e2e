# shellcheck shell=bash
# harness/lib/bootstrap.sh — a logos-docker container as a relay bootstrap node.
#
# The scenario's peers are host processes; this is the one node that is a
# container, so it gets its own call seam (`bootstrap_call`) rather than
# node_call's: logoscore inside the image is driven through `docker exec`, and
# the client needs --config-dir because the image's CMD moves the daemon's
# config dir away from the client's default (logos-docker README documents the
# bare form, which answers NO_DAEMON).
#
# Relay only, no RLN: the bootstrap forwards, the two peers prove and validate.
# Giving it a membership would mean a third registration and a third faucet
# claim for a node whose job is to be a meeting point.
#
# Env beyond docs/contract.md:
#   E2E_BOOTSTRAP_IMAGE   image to run (default logos:demo-pins)
#   E2E_BOOTSTRAP_PORT    the node's libp2p TCP port inside the container
#   E2E_BOOTSTRAP_NAME    container name (default rln-e2e-bootstrap-$$)

. "$(dirname "${BASH_SOURCE[0]}")/json.sh"

E2E_BOOTSTRAP_IMAGE="${E2E_BOOTSTRAP_IMAGE:-logos:demo-pins}"
E2E_BOOTSTRAP_PORT="${E2E_BOOTSTRAP_PORT:-61000}"
E2E_BOOTSTRAP_NAME="${E2E_BOOTSTRAP_NAME:-rln-e2e-bootstrap-$$}"
BOOTSTRAP_CFG_DIR=/var/lib/logos/config
BOOTSTRAP_UP=0

bootstrap_call() {
    local mod="$1" meth="$2"; shift 2
    _with_timeout "${CALL_TIMEOUT:-180}" docker exec "$E2E_BOOTSTRAP_NAME" \
        logoscore --config-dir "$BOOTSTRAP_CFG_DIR" --json call "$mod" "$meth" "$@" 2>/dev/null
}

bootstrap_logs() { docker logs "$E2E_BOOTSTRAP_NAME" 2>&1 | tail -"${1:-40}"; }

# Print the bootstrap's dialable multiaddr; empty when it never came up.
bootstrap_multiaddr() { gv BOOTSTRAP addr; }

# Start the container, bring a relay node up in it, and stash its multiaddr.
# Usage: bootstrap_up <cluster-id> <num-shards>
bootstrap_up() {
    local cluster="$1" shards="$2" cfg raw addr _t
    command -v docker >/dev/null || die "bootstrap: docker not on PATH"
    docker image inspect "$E2E_BOOTSTRAP_IMAGE" >/dev/null 2>&1 \
        || die "bootstrap: image '$E2E_BOOTSTRAP_IMAGE' not present — build it from logos-co/logos-docker with the pins this repo locks"

    say "bootstrap: starting $E2E_BOOTSTRAP_NAME from $E2E_BOOTSTRAP_IMAGE"
    docker run -d --name "$E2E_BOOTSTRAP_NAME" "$E2E_BOOTSTRAP_IMAGE" >/dev/null \
        || die "bootstrap: docker run failed"
    BOOTSTRAP_UP=1

    # Wait on the daemon with a SHORT timeout — the call cap is sized for
    # registry reads, and spending it per probe turns a dead container into an
    # hours-long hang.
    for _t in $(seq 1 60); do
        _with_timeout 5 docker exec "$E2E_BOOTSTRAP_NAME" \
            logoscore --config-dir "$BOOTSTRAP_CFG_DIR" --json list-modules \
            >/dev/null 2>&1 && break
        sleep 2
    done
    _with_timeout 5 docker exec "$E2E_BOOTSTRAP_NAME" \
        logoscore --config-dir "$BOOTSTRAP_CFG_DIR" --json list-modules >/dev/null 2>&1 \
        || die "bootstrap: daemon never answered RPC ($(bootstrap_logs 10))"

    # The image ships the modules but loads none of them; delivery_module pulls
    # its RLN chain in behind it.
    say "bootstrap: load-module delivery_module"
    _with_timeout 60 docker exec "$E2E_BOOTSTRAP_NAME" \
        logoscore --config-dir "$BOOTSTRAP_CFG_DIR" --json load-module delivery_module \
        >/dev/null 2>&1 || die "bootstrap: load-module delivery_module failed ($(bootstrap_logs 15))"

    # Same layered shape the peers use; RLN is simply never configured here.
    cfg=$(cat <<JSON
{"mode":"core","preset":"","messagingOverrides":{
  "log-level":"DEBUG","listen-address":"0.0.0.0",
  "tcp-port":$E2E_BOOTSTRAP_PORT,
  "cluster-id":$cluster,"num-shards-in-network":$shards,
  "store":false}}
JSON
)
    raw=$(bootstrap_call delivery_module createNode "$cfg" | jres) || raw=""
    case "$raw" in
        *'"success":true'*) ;;
        *) die "bootstrap: createNode failed: ${raw:-<empty>}" ;;
    esac
    raw=$(bootstrap_call delivery_module start | jres) || raw=""
    case "$raw" in
        *'"success":true'*) ;;
        *) die "bootstrap: start failed: ${raw:-<empty>}" ;;
    esac

    addr=$(bootstrap_call delivery_module getNodeInfo MyMultiaddresses | jres | jval)
    # The container reports its bridge address directly; a 0.0.0.0 listen
    # address would still be advertised verbatim, so substitute when it is.
    case "$addr" in
        */ip4/0.0.0.0/*)
            local ip
            ip=$(docker inspect "$E2E_BOOTSTRAP_NAME" \
                --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
            addr=${addr//\/ip4\/0.0.0.0\//\/ip4\/$ip\/} ;;
    esac
    case "$addr" in
        /ip4/*) ;;
        *) die "bootstrap: no dialable multiaddr: ${addr:-<empty>}" ;;
    esac
    sv BOOTSTRAP addr "$addr"
    say "bootstrap: relaying at $addr"
}

bootstrap_down() {
    [ "$BOOTSTRAP_UP" = 1 ] || return 0
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving bootstrap container $E2E_BOOTSTRAP_NAME up"
        return 0
    fi
    docker rm -f "$E2E_BOOTSTRAP_NAME" >/dev/null 2>&1
    BOOTSTRAP_UP=0
}
