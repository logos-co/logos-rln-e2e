#!/usr/bin/env bash
# scenarios/mix-delivery-rln — a Delivery message with anonymity Required
# crosses three standalone Mix intermediates, with RLN on every hop and on
# every coordination frame. The intermediates follow the operator doc "Run a
# Logos Mixnet node from the CLI": one shared liblogos_rln_module backend per
# host, separate Relay and Mix memberships from one payer, a Delivery Relay
# node beside the Mix switch for proof-metadata coordination, and a host-side
# pump between the two.
#
# Every host runs the released logosctl and installs the way the doc does,
# from the published catalog where it can: liblogos_lez_rln_module by name;
# liblogos_rln_module, Mix and Delivery from file (portable builds). The
# catalog's liblogos_rln_module 0.10.0 predates rln-modules#27 and rejects Mix
# proofs ("external_nullifier: expected 32-byte hex alongside a bare proof");
# Mix and Delivery#148 are in no catalog. Then `module load` of the two top
# modules, their dependencies following.
#
# Seven hosts, each its own daemon, wallet and backend:
#   sender    Delivery light client, native Mix, anonymityLevel Required
#   m1 m2 m3  libp2p_mix_rln_module intermediate + Delivery Relay coord node
#   exit      Delivery Mix exit + Lightpush/Filter service
#   relay     Delivery Relay/Filter service
#   receiver  Delivery light client
#
# What it proves (network.py does the driving):
#   1. both memberships register one after the other and go active per host;
#      the Delivery nodes resolve the Relay scope from a manage-backend=false
#      preset (doc steps 2-4)
#   2. each intermediate publishes a full Mix peer record whose peer id is not
#      its Delivery node's (doc step 5), and every Mix participant holds the
#      other four records (doc step 7)
#   3. the exact payload reaches the receiver through the route, intermediates
#      publish proof metadata, and every Mix participant receives some (doc
#      steps 6 and 8)
#   4. both scopes report the registered rate limit on an intermediate, and its
#      Mix quota is being spent (doc step 8)
#   5. with the intermediates stopped, Required traffic does not arrive while a
#      direct control message does: the route, not plain Relay, carried (3)
#
# Env beyond docs/contract.md:
#   E2E_MIX_COVER_FRACTION  cover-traffic rate for the intermediates (0.01;
#                           not a production privacy setting)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain delivery usertools; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

NODES_ALL="sender m1 m2 m3 exit relay receiver"
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving nodes up, state in $E2E_RUN_DIR"
        return
    fi
    daemon_stop_all
}
trap cleanup EXIT

# The Mix scope is the LIP LOGOS-MIXNET profile's ("mix-rln-spam-protection/v1",
# zero-padded); the Relay scope is this run's own.
MIX_REGISTRY_ID=$(delivery_registry_id)
MIX_RLN_ID=6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000
RELAY_RLN_ID=$(delivery_rln_identifier)
export MIX_REGISTRY_ID MIX_RLN_ID RELAY_RLN_ID
say "registry $MIX_REGISTRY_ID; mix scope $MIX_RLN_ID; relay scope $RELAY_RLN_ID"

PRESETS="$E2E_RUN_DIR/relay-presets.json"
delivery_stage_rln_presets "$PRESETS" "$MIX_REGISTRY_ID" "$RELAY_RLN_ID" 10 "" \
    '"manage-backend": false, "max-epoch-gap": 3'
E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} $(delivery_rln_presets_env "$PRESETS")"
export E2E_DAEMON_ENV

UT_LOGOSCTL=$(ut_logosctl)
export UT_LOGOSCTL
say "logosctl: $("$UT_LOGOSCTL" --version 2>&1 | head -1)"

# Usage: host_install <node> <top-module>…
# Doc step 1: the registry provider by name, the rest from file, then one load
# per top module and an assertion that the dependency chain came up with it.
host_install() {
    local node="$1"; shift
    local files="$RLN_PORTABLE_LGX $DELIVERY_LGX" mod loaded v versions=""
    case " $* " in *" libp2p_mix_rln_module "*) files="$MIX_LGX $files" ;; esac
    ut_package_install "$node" liblogos_lez_rln_module
    # shellcheck disable=SC2086
    NODE_CLI_TIMEOUT_S="${E2E_USERTOOLS_TIMEOUT_S:-900}" node_cli "$node" package install $files -y >/dev/null \
        || die_node "$node" "package install from file failed: $files"
    for mod in liblogos_rln_module liblogos_lez_rln_module "$@"; do
        v=$(ut_installed_version "$node" "$mod")
        [ -n "$v" ] || die_node "$node" "logosctl does not report $mod installed"
        versions="$versions $mod $v;"
    done
    say "$node: installed$versions"
    for mod in "$@"; do daemon_load_modules "$node" "$mod"; done
    loaded=$(NODE_CLI_TIMEOUT_S=15 node_cli "$node" --json module ls --loaded 2>/dev/null) || loaded=""
    for mod in liblogos_lez_rln_module liblogos_rln_module "$@"; do
        case "$loaded" in
            *"\"$mod\""*) ;;
            *) die_node "$node" "after module load, $mod is not loaded: ${loaded:-<empty>}" ;;
        esac
    done
}

section "hosts"
for node in $NODES_ALL; do
    daemon_self_paying "$node" "$E2E_RUN_DIR/wallet-$node"
    daemon_stack_ctl "$node" "$UT_LOGOSCTL"
    daemon_start "$node"
    case "$node" in
        m1|m2|m3) host_install "$node" libp2p_mix_rln_module delivery_module ;;
        *)        host_install "$node" delivery_module ;;
    esac
    wallet_open "$node"
    wallet_sync "$node" >/dev/null
    wallet_fund "$node" >/dev/null
    say "$node: own wallet funded"
done

# A membership registered while CLOCK_50 still holds its genesis timestamp
# expires at the clock's first update, which lands on block 50.
section "chain clock"
for _t in $(seq 1 120); do
    head=$(chain_head || echo 0)
    [ "$head" -gt 50 ] && break
    sleep 2
done
[ "${head:-0}" -gt 50 ] || die "chain head ${head:-?} never passed block 50"
say "chain head $head"

section "network"
python3 "$HERE/network.py" || die "network: see above; node logs under $E2E_RUN_DIR/nodes"
say "PASS — mix-delivery-rln (target $E2E_TARGET)"
