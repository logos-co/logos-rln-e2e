#!/usr/bin/env bash
# scenarios/delivery-cli — what an operator actually does, end to end.
#
# Every other scenario stages modules the harness's way: nix build from the
# pins, install_lgx file-copies the -dev variant into one shared modules dir,
# and the pinned logoscore loads it. A node operator does none of that. They
# download the released logosctl, start its daemon, add a published catalog,
# install modules by name, fund the account the node tells them about, and
# send. Nothing tested that path until now — which means the published
# artifacts, the catalog's metadata, the package manager's dependency
# resolution and the portable module ABI were all unexercised.
#
# So n1 here is built by the operator's toolchain and nothing else: a released
# logosctl (harness/lib/usertools.sh) is its daemon, its client, and — through
# the package modules it bundles — its catalog and installer. Installing
# liblogos_rln_module from the logos-rln-modules catalog pulls
# liblogos_lez_rln_module in as a dependency.
#
# n2 is an ordinary harness node on the flake pins. That asymmetry is
# deliberate: the send crosses the PUBLISHED stack into the stack main builds,
# so this doubles as an interop check. A regression on either side fails it.
#
# The one thing the operator cannot get from a catalog yet is delivery_module
# at an RLN-capable version — the official catalog stops at 0.2.1, which
# predates the RLN bridge. n1 therefore installs the same rev the peer runs
# from a local bundle, built PORTABLE (variants/<platform>, not
# <platform>-dev) because a released logosctl loads nothing else.
#
# What it asserts:
#   - the package manager's own inventory reports all three modules
#     installed, with versions;
#   - the node publishes a payer account and, once funded, registers itself —
#     an active membership with a leaf index, which is the "is there a
#     membership" question an operator actually asks;
#   - rlnState reaches Ready on the resolved scope, on both stacks;
#   - a send is accepted, and it cost a proof: a generate-proof request for
#     that send, and messagePropagated for its requestId.
#
# What it reports without asserting:
#   - the epoch budget the send spent;
#   - whether the peer received it. A first send on a freshly published root
#     can legitimately be ignored while the receiver's window catches up; the
#     claim here is about the sender's path, so a miss is information, not a
#     failure. delivery-rln is the scenario that asserts delivery.
#
# The catalog can lag main, because a module is published when someone runs
# the release workflow and not when main moves. So this may well install a
# module older than the one the peer builds — which is the operator's reality
# and part of what the scenario is for, not a defect to pin around.
#
# It is also why membership is asserted on `state` and never on a client-side
# expiry computation: a lagging module can predate a fix in how durations are
# RENDERED while still decoding the chain correctly, and an assertion that
# reads expiry would fail for a reason that has nothing to do with the
# operator's path.
#
# Env beyond docs/contract.md:
#   E2E_CLI_PORT=61990        tcp ports are PORT+1 (operator), PORT+2 (peer)
#   E2E_CLI_RECV_WAIT_S=20    how long the peer is given to show a receipt
#                             (reported, never asserted)
#   E2E_EVENT_TIMEOUT_S=30    per-event wait budget
#   E2E_MESH_WAIT_S=12        gossipsub mesh stabilization pause
#   E2E_USERTOOLS_DIR         release cache (see harness/lib/usertools.sh)
#   E2E_LOGOSCTL_RELEASE      the logosctl release n1 runs
#   E2E_RLN_CATALOG           the catalog the RLN modules resolve from
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain delivery usertools; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

BASE_PORT="${E2E_CLI_PORT:-61990}"
RECV_WAIT_S="${E2E_CLI_RECV_WAIT_S:-20}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
TOPIC="/logos-rln-e2e/1/delivery-cli/proto"
CLUSTER_ID="198"
OPERATOR=n1
PEER=n2
NODES_ALL="$OPERATOR $PEER"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_PAYER E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC DELIVERY_LGX_PORTABLE; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done

NODES_UP=0
DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ "$NODES_UP" = 1 ]; then
        DYING=1
        local n
        for n in $NODES_ALL; do
            echo "---- $n log tail ----" >&2
            node_logs "$n" 30 >&2 || true
        done
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving nodes up, state in $E2E_RUN_DIR"
        say "E2E_KEEP=1: the operator's logosctl session is $(node_cfg_dir "$OPERATOR") (LOGOSCTL_CONFIG_DIR)"
        return
    fi
    [ "$NODES_UP" = 1 ] && daemon_stop_all
}
trap cleanup EXIT

REGISTRY_ID=$(delivery_registry_id)
RLN_ID=$(delivery_rln_identifier)
say "registry: $REGISTRY_ID"

# The presets file is how RLN reaches a node: createNode resolves it, and it
# is read from the daemon's own environment, so it must exist before any
# daemon starts. Both stacks get the same file and therefore the same scope —
# two nodes that disagree here reject each other's proofs.
RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC"
E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} $(delivery_rln_presets_env "$RLN_PRESETS_FILE")"
export E2E_DAEMON_ENV

# ---------- daemons ----------------------------------------------------------
section "daemons: operator on a released logosctl, peer on the pins"
UT_LOGOSCTL=$(ut_logosctl)
say "logosctl: $("$UT_LOGOSCTL" --version 2>&1 | head -1) ($UT_LOGOSCTL)"
# Each node gets a wallet of its OWN: only the staged wallet_config.json is
# copied, so the registry module creates a fresh wallet and derives a payer
# nothing else holds. Sharing storage.json would give both nodes the same
# derived account and they would race one nonce.
for n in $NODES_ALL; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
done
daemon_stack_ctl "$OPERATOR" "$UT_LOGOSCTL"
for n in $NODES_ALL; do
    daemon_start "$n" || die "daemon_start $n failed"
done
NODES_UP=1

# ---------- the operator's install ------------------------------------------
# Through the operator's running daemon: logosctl's package commands are its
# bundled package_manager / package_downloader modules.
section "operator install: published catalog, by name"
ut_catalog_add "$OPERATOR"
# One name for the RLN pair: liblogos_rln_module declares
# liblogos_lez_rln_module as a dependency, and the installer is expected to
# follow it — asserting the version below is asserting that it did.
ut_package_install "$OPERATOR" liblogos_rln_module
ut_install_file "$OPERATOR" "$DELIVERY_LGX_PORTABLE"

# Read the inventory back from the package manager rather than from the
# files: what it believes is installed is the thing under test.
CLI_RLN_V=$(ut_installed_version "$OPERATOR" liblogos_rln_module)
CLI_LEZ_V=$(ut_installed_version "$OPERATOR" liblogos_lez_rln_module)
CLI_DELIVERY_V=$(ut_installed_version "$OPERATOR" delivery_module)
[ -n "$CLI_RLN_V" ] || die_node "$OPERATOR" "logosctl does not report liblogos_rln_module installed"
[ -n "$CLI_LEZ_V" ] || die_node "$OPERATOR" "logosctl does not report liblogos_lez_rln_module installed — the catalog dependency was not followed"
[ -n "$CLI_DELIVERY_V" ] || die_node "$OPERATOR" "logosctl does not report delivery_module installed"
say "installed: liblogos_rln_module $CLI_RLN_V, liblogos_lez_rln_module $CLI_LEZ_V (catalog), delivery_module $CLI_DELIVERY_V (pin, portable)"

# One load, not three: the operator installed a dependency chain and the
# daemon is expected to resolve it. Asserting that here is asserting the
# catalog's dependency metadata survived the round trip.
daemon_load_modules "$OPERATOR" delivery_module
LOADED=$(NODE_CLI_TIMEOUT_S=15 node_cli "$OPERATOR" --json module ls --loaded 2>/dev/null) || LOADED=""
for _mod in liblogos_lez_rln_module liblogos_rln_module delivery_module; do
    case "$LOADED" in
        *"\"$_mod\""*) ;;
        *) die_node "$OPERATOR" "loading delivery_module left $_mod unloaded — the catalog's dependency \
metadata did not survive the round trip. loaded: ${LOADED:-<empty>}" ;;
    esac
done
say "$OPERATOR: delivery_module pulled its RLN dependency chain in on load"
daemon_load_modules "$PEER" liblogos_lez_rln_module liblogos_rln_module delivery_module

# ---------- the account an operator has to fund ------------------------------
section "wallets: the node names the account, the operator funds it"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "chain head $CHAIN_HEAD"
for n in $NODES_ALL; do
    wallet_open "$n" || die_node "$n" "wallet open failed"
    wallet_sync "$n" >/dev/null || die_node "$n" "wallet sync failed"
    # This is the operator's step and the only one the module stack cannot do
    # for itself: no program mints native balance, so an external transfer is
    # the sole way. The account id comes from the node, not from the harness.
    say "$n: payer $(wallet_payer "$n") holds $(wallet_native_balance "$n") native — funding it"
    wallet_fund "$n" >/dev/null || die_node "$n" "funding its payer failed"
    say "$n: payer now holds $(wallet_native_balance "$n") native"
done

# ---------- registration -----------------------------------------------------
# The module registers itself once funded; the harness only paid. start() both
# kicks that off and pre-warms the root window.
section "registration (the node registers itself)"
for n in $NODES_ALL; do
    delivery_prewarm "$n" "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}"
done
for n in $NODES_ALL; do
    delivery_await_provisioned "$n" "$REGISTRY_ID" "$RLN_ID"
    say "$n: membership $(gv MHASH "$n") at leaf $(gv LEAF "$n")"
done
# The operator's question, asked the operator's way: is there a membership on
# this registry, and is it usable? State, not expiry — the published lez
# module predates the ms-clock fix in duration rendering.
OP_STATE=$(node_call "$OPERATOR" liblogos_rln_module get_membership_state \
    "$REGISTRY_ID" "$(argfile mstate_op "$RLN_ID")" | jres)
case "$(printf '%s' "$OP_STATE" | jfield state)" in
    active|grace_period) say "$OPERATOR: registered membership confirmed: $OP_STATE" ;;
    *) die_node "$OPERATOR" "no usable membership after provisioning: ${OP_STATE:-<empty>}" ;;
esac

# ---------- nodes up ---------------------------------------------------------
section "delivery nodes"
for n in $NODES_ALL; do
    node_watch_start "$n" delivery_module
done
# The peer comes up first and the operator dials IT — the fleet is already
# there when an operator joins, never the other way round.
delivery_node_up "$PEER" "$(( BASE_PORT + 2 ))" "$CLUSTER_ID" "" "$EVT_TIMEOUT"
delivery_node_up "$OPERATOR" "$(( BASE_PORT + 1 ))" "$CLUSTER_ID" "$(gv MADDR "$PEER")" "$EVT_TIMEOUT"

say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
for n in $NODES_ALL; do
    delivery_must_call "$n" subscribe "subscribe" "$TOPIC" >/dev/null
done
say "both nodes subscribed to $TOPIC"
# Only the peer validates what arrives, so only its read path has to be warm.
delivery_wait_roots_warm "$PEER" "$REGISTRY_ID"

# ---------- the send ---------------------------------------------------------
section "send"
QUOTA_BEFORE=$(delivery_quota "$OPERATOR" "$REGISTRY_ID" "$RLN_ID" "before")
say "$OPERATOR quota before: $QUOTA_BEFORE"

REQID=$(delivery_must_call "$OPERATOR" send "send" "$TOPIC" \
    "$(argfile payload "hello from the operator's own install")")
[ -n "$REQID" ] || die_node "$OPERATOR" "send returned no requestId"
say "$OPERATOR: send accepted, requestId $REQID"

# It cost a proof. The generate request is the delivery side asking the RLN
# module for one; without it the message went out unproven and the rate limit
# is decorative.
GEN=$(node_wait_event "$OPERATOR" delivery_module \
    "$(delivery_rln_evt rlnGenerateProofRequest)" "$EVT_TIMEOUT") || GEN=""
[ -n "$GEN" ] || die_node "$OPERATOR" "no generate-proof request within ${EVT_TIMEOUT}s — the send carried no RLN proof"
say "$OPERATOR: proof generated for the send"

PROP=$(node_wait_event "$OPERATOR" delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") || PROP=""
if [ -z "$PROP" ]; then
    ERR=$(node_wait_event "$OPERATOR" delivery_module messageError 1 "$REQID") || ERR=""
    [ -z "$ERR" ] || die_node "$OPERATOR" "send failed: $ERR"
    die_node "$OPERATOR" "no messagePropagated for $REQID within ${EVT_TIMEOUT}s"
fi
MSG_HASH=$(printf '%s' "$PROP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("arg1",""))') || MSG_HASH=""
say "$OPERATOR: propagated (hash ${MSG_HASH:-<unread>})"

# ---------- reported, not asserted -------------------------------------------
section "reported"
QUOTA_AFTER=$(delivery_quota "$OPERATOR" "$REGISTRY_ID" "$RLN_ID" "after")
say "quota after: $QUOTA_AFTER (before: $QUOTA_BEFORE)"
if [ -n "$MSG_HASH" ] && node_wait_event "$PEER" delivery_module messageReceived "$RECV_WAIT_S" "$MSG_HASH" >/dev/null; then
    say "the peer received it — published stack -> pinned stack delivered end to end"
else
    say "the peer did not show a receipt within ${RECV_WAIT_S}s. Not a failure here: a first send on a \
freshly published root is ignored while the receiver's window catches up, and this scenario claims the \
sender's path. delivery-rln is the one that asserts delivery."
fi

say ""
say "delivery-cli PASS — installed liblogos_rln_module $CLI_RLN_V + liblogos_lez_rln_module $CLI_LEZ_V \
from the catalog and delivery_module $CLI_DELIVERY_V from the pin, with a released logosctl"
say "  membership     $(gv MHASH "$OPERATOR") at leaf $(gv LEAF "$OPERATOR")"
say "  paid by        $(wallet_payer "$OPERATOR") (funded by the operator, registered by the node)"
say "  send           $REQID proved and propagated to the pinned-stack peer"
