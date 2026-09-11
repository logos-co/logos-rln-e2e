# shellcheck shell=bash
# harness/lib/bootstrap.sh — a logos-docker container as the relay both peers
# meet at.
#
# The scenario's peers are host processes; this is the one node that is a
# container, so it gets its own call seam (`bootstrap_call`) rather than
# node_call's: logoscore inside the image is driven through `docker exec`, and
# the client needs --config-dir because the image's CMD moves the daemon's
# config dir away from the client's default (logos-docker#15).
#
# The relay mounts RLN and validates the proof on every message it forwards, so
# it needs a membership of its own — the delivery library gates `start` on
# get_membership_state being active. That means a wallet, a faucet claim and a
# registration inside the container, all against the same registry and the same
# rln identifier as the peers. E2E_BOOTSTRAP_RLN=0 leaves it a plain relay,
# which is what separates "the relay dropped it" from "the receiver did".
#
# The container's wallet is created fresh rather than staged from the
# deployment: lez_core 0.4.1 rejects any storage.json written by a pre-v0.2.5-rc2
# lez, which is every committed fixture. create_new leaves the wallet open but
# writes nothing until save().
#
# Env beyond docs/contract.md:
#   E2E_BOOTSTRAP_IMAGE   image to run (default logos:demo-pins)
#   E2E_BOOTSTRAP_PORT    the node's libp2p TCP port inside the container
#   E2E_BOOTSTRAP_NAME    container name
#   E2E_BOOTSTRAP_RLN     1 mounts RLN on the relay; 0 (default) relays blind
#
# RLN on the relay is written and ready but defaults OFF, because the image
# cannot reach the chain: its lez_core is 0.4.1, built on execution-zone
# v0.2.5-rc2, and syncing against the deployed testnet fails with
# "Parse error: Unexpected variant tag" — the programs on that chain predate the
# bump. A wallet 0.4.1 creates itself fails the same way, so this is chain
# decoding, not the old-fixture format. Flip it to 1 once the testnet is
# redeployed on v0.2.5-rc2, or once the image can be built against lez_core
# 0.4.0 (its lez_core comes from the RLN catalog, which publishes only 0.4.1).

. "$(dirname "${BASH_SOURCE[0]}")/json.sh"

E2E_BOOTSTRAP_IMAGE="${E2E_BOOTSTRAP_IMAGE:-logos:demo-pins}"
E2E_BOOTSTRAP_PORT="${E2E_BOOTSTRAP_PORT:-61000}"
E2E_BOOTSTRAP_NAME="${E2E_BOOTSTRAP_NAME:-rln-e2e-bootstrap-$$}"
E2E_BOOTSTRAP_RLN="${E2E_BOOTSTRAP_RLN:-0}"
BOOTSTRAP_CFG_DIR=/var/lib/logos/config
BOOTSTRAP_WALLET=/home/ubuntu/wallet
BOOTSTRAP_UP=0

bootstrap_call() {
    local mod="$1" meth="$2"; shift 2
    _with_timeout "${CALL_TIMEOUT:-180}" docker exec "$E2E_BOOTSTRAP_NAME" \
        logoscore --config-dir "$BOOTSTRAP_CFG_DIR" --json call "$mod" "$meth" "$@" 2>/dev/null
}

# Short-timeout client call for readiness/lifecycle, where the registry-read
# budget would turn a dead container into an hours-long hang.
bootstrap_cli() {
    local secs="$1"; shift
    _with_timeout "$secs" docker exec "$E2E_BOOTSTRAP_NAME" \
        logoscore --config-dir "$BOOTSTRAP_CFG_DIR" --json "$@" 2>/dev/null
}

bootstrap_logs() { docker logs "$E2E_BOOTSTRAP_NAME" 2>&1 | tail -"${1:-40}"; }
bootstrap_multiaddr() { gv BOOTSTRAP addr; }

_bootstrap_polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

# Fresh wallet, faucet claim, membership — the peers' path, over docker exec.
# Usage: _bootstrap_register <registry_id> <rln_identifier> <rate_limit>
_bootstrap_register() {
    local registry="$1" rlnid="$2" rate="$3" head cur next tgt
    local holding bounds price claim reg state state_json _t

    docker exec "$E2E_BOOTSTRAP_NAME" mkdir -p "$BOOTSTRAP_WALLET" \
        || die "bootstrap: cannot create $BOOTSTRAP_WALLET"
    printf '{"sequencer_addr":"%s","sequencers":[{"sequencer_addr":"%s"}],"seq_poll_timeout":"30s","seq_tx_poll_max_blocks":15,"seq_poll_max_retries":10,"seq_block_poll_max_amount":100}\n' \
        "$E2E_SEQUENCER" "$E2E_SEQUENCER" \
        | docker exec -i "$E2E_BOOTSTRAP_NAME" sh -c "cat > $BOOTSTRAP_WALLET/wallet_config.json" \
        || die "bootstrap: cannot write wallet_config.json"

    say "bootstrap: creating a wallet"
    bootstrap_call lez_core create_new "$BOOTSTRAP_WALLET/wallet_config.json" \
        "$BOOTSTRAP_WALLET/storage.json" "$BOOTSTRAP_WALLET/stats.json" bootstrap-e2e \
        | jres >/dev/null || die "bootstrap: create_new failed"
    # create_new leaves it open in memory; nothing is on disk until save().
    bootstrap_call lez_core save | jres >/dev/null || die "bootstrap: wallet save failed"

    head=$(chain_head) || die "bootstrap: cannot probe chain head"
    cur=$(bootstrap_call lez_core get_last_synced_block | jres | jval)
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    while [ "$cur" -lt "$head" ]; do
        tgt=$(( cur + ${SYNC_STEP:-3000} ))
        [ "$tgt" -gt "$head" ] && tgt="$head"
        bootstrap_call lez_core sync_to_block "$tgt" >/dev/null 2>&1
        next=$(bootstrap_call lez_core get_last_synced_block | jres | jval)
        case "$next" in ''|*[!0-9]*) break ;; esac
        [ "$next" = "$cur" ] && break
        cur="$next"
    done
    say "bootstrap: wallet synced to $cur"

    for _t in $(seq 1 "${E2E_DERIVE_TRIES:-30}"); do
        holding=$(bootstrap_call lez_core create_account_public | jres)
        case "$holding" in ''|ERR|None) sleep 2; continue ;; esac
        case "$(bootstrap_call liblogos_lez_rln_module get_token_balance "str:$holding" | jres)" in
            *'"exists":false'*) break ;;
        esac
        holding=""
    done
    [ -n "$holding" ] || die "bootstrap: no unused holding account"

    bounds=$(bootstrap_call liblogos_lez_rln_module get_registry_bounds "str:$E2E_CONFIG_ACCOUNT" | jres)
    price=$(printf '%s' "$bounds" | jfield price_per_unit)
    [ -n "$price" ] || die "bootstrap: no price_per_unit in bounds: ${bounds:-<empty>}"
    claim=$(( rate * price * 2 ))
    say "bootstrap: claiming $claim RLNTOK from the faucet"
    bootstrap_call liblogos_lez_rln_module claim_tokens "str:$E2E_CONFIG_ACCOUNT" \
        "str:$holding" "$claim" | jres >/dev/null || die "bootstrap: claim_tokens failed"

    for _t in $(seq 1 "$(_bootstrap_polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        case "$(bootstrap_call liblogos_lez_rln_module get_token_balance "str:$holding" | jres | jfield balance)" in
            ''|*[!0-9]*) ;;
            *) [ "$(bootstrap_call liblogos_lez_rln_module get_token_balance "str:$holding" | jres | jfield balance)" -ge "$claim" ] && break ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done

    say "bootstrap: register_membership(rate $rate)"
    reg=$(bootstrap_call liblogos_rln_module register_membership "$registry" "str:$rlnid" \
        "[{\"key\":\"rate_limit\",\"value\":\"$rate\"},{\"key\":\"funding_holding_account_id\",\"value\":\"$holding\"}]" | jres)
    case "$reg" in
        *'"state":"pending"'*) ;;
        *) die "bootstrap: register_membership failed: ${reg:-<empty>}" ;;
    esac

    say "bootstrap: polling get_membership_state to active…"
    state=""
    for _t in $(seq 1 "$(_bootstrap_polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        state_json=$(bootstrap_call liblogos_rln_module get_membership_state "$registry" "str:$rlnid" | jres)
        state=$(printf '%s' "$state_json" | jfield state)
        case "$state" in
            active|grace_period) break ;;
            failed) die "bootstrap: registration FAILED: $state_json" ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    case "$state" in
        active|grace_period) say "bootstrap: membership $state at leaf $(printf '%s' "$state_json" | jfield leaf_index)" ;;
        *) die "bootstrap: membership never became active (last: ${state:-<none>})" ;;
    esac
}

# Usage: bootstrap_up <cluster-id> <num-shards> <registry-id> <rln-identifier> <rate-limit>
bootstrap_up() {
    local cluster="$1" shards="$2" registry="$3" rlnid="$4" rate="$5" cfg raw addr _t verdict
    command -v docker >/dev/null || die "bootstrap: docker not on PATH"
    docker image inspect "$E2E_BOOTSTRAP_IMAGE" >/dev/null 2>&1 \
        || die "bootstrap: image '$E2E_BOOTSTRAP_IMAGE' not present — build it from logos-co/logos-docker with the pins this repo locks"

    say "bootstrap: starting $E2E_BOOTSTRAP_NAME from $E2E_BOOTSTRAP_IMAGE"
    # rln_core derives its PDAs from the tree id, same as the host daemons.
    docker run -d --name "$E2E_BOOTSTRAP_NAME" \
        -e LEZ_RLN_TREE_ID_HEX="$E2E_TREE_ID" "$E2E_BOOTSTRAP_IMAGE" >/dev/null \
        || die "bootstrap: docker run failed"
    BOOTSTRAP_UP=1

    for _t in $(seq 1 60); do
        bootstrap_cli 5 list-modules >/dev/null 2>&1 && break
        sleep 2
    done
    bootstrap_cli 5 list-modules >/dev/null 2>&1 \
        || die "bootstrap: daemon never answered RPC ($(bootstrap_logs 10))"

    # The image ships the modules but loads none; delivery_module pulls the RLN
    # chain in behind it.
    say "bootstrap: load-module delivery_module"
    bootstrap_cli 60 load-module delivery_module >/dev/null 2>&1 \
        || die "bootstrap: load-module delivery_module failed ($(bootstrap_logs 15))"

    if [ "$E2E_BOOTSTRAP_RLN" = 1 ]; then
        _bootstrap_register "$registry" "$rlnid" "$rate"
        # Same fire-and-wait-on-the-log shape the peers use: configureRln
        # outlives logosctl's fixed 20 s transport deadline.
        bootstrap_call delivery_module configureRln \
            "{\"registry-id\":\"$registry\",\"rln-identifier\":\"$rlnid\",\"epoch-size-sec\":$E2E_EPOCH_SIZE_SEC}" \
            >/dev/null 2>&1 || true
        verdict=""
        for _t in $(seq 1 "$(_bootstrap_polls "${E2E_CONFIGURE_RLN_TIMEOUT_S:-180}" 5)"); do
            if bootstrap_logs 200 | grep -q "rln served in-process"; then verdict=ok; break; fi
            if bootstrap_logs 200 | grep -q "rln bridge unavailable"; then verdict=nobridge; break; fi
            sleep 5
        done
        [ "$verdict" = ok ] || die "bootstrap: configureRln never reported (${verdict:-timeout})"
        say "bootstrap: RLN mounted — it validates every message it relays"
    else
        say "bootstrap: RLN off (E2E_BOOTSTRAP_RLN=0) — relaying without validating"
    fi

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
        *) die "bootstrap: start failed: ${raw:-<empty>} ($(bootstrap_logs 15))" ;;
    esac

    addr=$(bootstrap_call delivery_module getNodeInfo MyMultiaddresses | jres | jval)
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
