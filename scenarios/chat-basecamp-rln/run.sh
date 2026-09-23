#!/usr/bin/env bash
# scenarios/chat-basecamp-rln — logos-chat running INSIDE Basecamp on the
# forked logos-delivery, RLN registration paid from the app's own payer, plus
# one proof-gated chat message.
#
# Topology:
#   basecamp   the desktop app (dev #app build, QML inspector compiled in),
#              launched headless with a throwaway --user-dir; the harness
#              modules dir is copied in wholesale and the RLN stack +
#              delivery_module + chat_module are loaded through
#              MainUIBackend.loadCoreModule. Every module call goes through
#              the inspector's result-returning `evaluate` ->
#              backend.callCoreModuleMethod(...) — see harness/lib/basecamp.sh.
#   n1         an ordinary logoscore daemon (delivery-rln's n2 role, plus
#              chat peer B): same module stack + chat_module, in-process
#              bridge (from the RLN preset), a wallet of its own that is NEVER
#              funded — its best-effort registration degrades on purpose; it
#              receives basecamp's chat message only after its own module
#              validates the proof.
#
# The chat config channel is the fork's CHAT_DELIVERY_CONF_OVERRIDE env
# (chat-module branch rln/e2e-extra-conf): the complete legacy-flat conf —
# the same shape delivery-rln proves — rides the env into chat_module's
# start_delivery_bootstrap on BOTH sides. Nothing calls createNode by hand:
# chat owns its delivery bootstrap (duplicates are rejected).
#
# What it proves:
#   1. the product shape: chat -> delivery -> RLN modules co-resident inside
#      Basecamp (embedded logos-core, side-loaded module dirs), headless.
#   2. a membership arrives for the app, and the app pays for it. Which of
#      two paths produces it is no longer something this scenario can tell
#      apart, and it deliberately does not try: since liblogos_rln_module
#      0.8.0 `start` provisions a registry-wide membership on its own, and
#      scope_candidates lets a registry-wide record back any scope — so the
#      configured scope reads as satisfied either way. What IS asserted is the
#      part that matters to a product: the app derives its own payer, the
#      harness funds that account and nothing else, and the registry confirms
#      registered:true + a real leaf (chain oracle via n1). Attribution to an
#      explicit call is tested by delivery-basecamp-rln, which controls
#      `start` and turns provisioning off.
#   3. the message path: chat send_message -> delivery publish (proof
#      attached by the fork's prover leg) -> gossipsub -> n1's validator ->
#      in-process bridge validate_proof -> chat message_received on n1 with
#      the plaintext (decrypt + full pipeline).
#
# Required (beyond docs/contract.md):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ master
#   LOGOS_DELIVERY_CHECKOUT   logos-delivery @ master (submodules checked out)
#   CHAT_MODULE_CHECKOUT      logos-chat-module @ rln/e2e-extra-conf
#   BASECAMP_CHECKOUT         logos-basecamp (or BASECAMP_APP binary)
#
# Env knobs:
#   E2E_RATE_LIMIT=100          registration rate limit / user-message-limit
#   E2E_CHAT_RLN_PORT=61890     tcp ports are PORT+1 (n1), PORT+2 (basecamp)
#   E2E_INSPECTOR_PORT=3768     basecamp QML inspector port (must be free)
#   E2E_FUND_LATE=1             run the whole bring-up with an EMPTY payer and
#                               fund only afterwards — the sequence a real user
#                               follows; needs liblogos_rln_module >= 0.8.1
#   E2E_AWAIT_FUNDING_S=120     budget for seeing it parked at awaiting_funding
#   E2E_BASECAMP_SETTLE_S=20    post-launch settle before driving the app
#   E2E_EVENT_TIMEOUT_S=30      per-event wait budget
#   E2E_MESH_WAIT_S=12          gossipsub mesh stabilization pause
#   E2E_SEND_ATTEMPTS=3         message-leg attempts (fresh-root window)
#   E2E_RECV_WAIT_S=15          per-attempt receive wait on n1
#   E2E_REG_WAIT_S=240          basecamp membership-pending wait budget
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain basecamp delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
BASE_PORT="${E2E_CHAT_RLN_PORT:-61890}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-15}"
REG_WAIT_S="${E2E_REG_WAIT_S:-240}"
CLUSTER_ID="198"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_PAYER E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC BASECAMP_APP; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md + scenario.env)"
done
if [ -z "${DELIVERY_LGX:-}" ]; then
    [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ] && [ -n "${LOGOS_DELIVERY_CHECKOUT:-}" ] \
        || die "chat-basecamp-rln needs BOTH delivery checkouts (rln/integration-fixes) or a prebuilt DELIVERY_LGX"
fi
basecamp_port_check

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODES_UP=0
DYING=0
UD="$E2E_RUN_DIR/basecamp-user"
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ]; then
        DYING=1
        basecamp_die_tails
        if [ "$NODES_UP" = 1 ]; then
            echo "---- n1 log tail ----" >&2
            node_logs n1 30 >&2 || true
        fi
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving basecamp (pid ${BASECAMP_PID:-none}) + n1 up, state in $E2E_RUN_DIR"
        return
    fi
    basecamp_stop
    [ "$NODES_UP" = 1 ] && daemon_stop_all
}
trap cleanup EXIT

# call delivery_module on a node + insist on StdLogosResult success; prints value.
must_call() {
    local node="$1" method="$2" label="$3"; shift 3
    local res
    res=$(node_call "$node" delivery_module "$method" "$@" | jres) || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" | jval ;;
        *) die "$node: $label failed: ${res:-<empty>}" ;;
    esac
}

CONFIG_HEX=$(python3 - "$E2E_CONFIG_ACCOUNT" <<'EOF'
import sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + A.index(c)
print(n.to_bytes(32, "big").hex())
EOF
) || die "cannot decode config account '$E2E_CONFIG_ACCOUNT'"
REGISTRY_ID="logos:${E2E_TARGET}:$CONFIG_HEX"
RLN_ID=$(delivery_rln_identifier)
say "registry: $REGISTRY_ID (scope rate $RATE_LIMIT)"

# The COMPLETE legacy-flat delivery conf (delivery-rln's proven shape) —
# chat's CHAT_DELIVERY_CONF_OVERRIDE replaces the config wholesale, so
# everything must be here. COMPACT (no spaces): the n1 copy rides the
# whitespace-split E2E_DAEMON_ENV.
# The conf carries NO rln key at all — the same conf delivery-rln passes.
#
# Two removals, and the second is the one that is easy to get wrong. The LEZ
# keys (rln-relay-lez / -registry-id / -identifier) are gone from upstream
# outright, and an unknown key is refused. But `rln-relay: true` had to go too:
# what survives in api/conf/messaging_conf.nim is the ETHEREUM RLN surface, so
# that flag makes the conf builder demand a chain id and a contract address —
# "RLN Relay Conf building failed: RLN Relay Chain Id is not specified". The
# LEZ backend is mounted by the plugin createNode installs from the preset,
# not by a conf
# flag. The rate limit is a register_membership option and the epoch size is a
# preset field, so nothing is lost with them.
chat_delivery_cfg() {
    local port="$1" peers="$2" extra="${3:-}"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true%s%s}' \
        "$port" "$CLUSTER_ID" "$extra" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

# The scope, as the RLN preset carries it. Staged before the daemon starts and
# before the app launches: each reads the path from its own environment, and
# createNode is what resolves it.
RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC"

# ---------- n1: verifier daemon (chain oracle + chat peer B) -----------------
section "n1: logoscore daemon (verifier + chat peer B)"
V_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 1 ))" "" "")
# n1 gets a wallet of its own (config only, never funded) rather than the
# deployment's shared payer: its best-effort registration is meant to
# degrade, and sharing basecamp's paying account would both fund it and race
# one nonce against the registration this scenario actually measures.
daemon_self_paying n1 "$E2E_RUN_DIR/wallet-n1"
E2E_DAEMON_ENV="CHAT_DELIVERY_CONF_OVERRIDE=$V_CONF $(delivery_rln_presets_env "$RLN_PRESETS_FILE")" daemon_start n1 \
    || die "daemon_start n1 failed"
NODES_UP=1
daemon_load_modules n1 liblogos_lez_rln_module liblogos_rln_module \
    delivery_module chat_module || die "n1: load-module failed"
say "n1: all 4 modules loaded (module-owned keystore custody, no unlock call)"

section "n1 wallet (chain oracle; its own home, never funded)"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "chain head: $CHAIN_HEAD"
wallet_open n1 || die "n1: wallet open failed"
wallet_sync n1 >/dev/null || die "n1: wallet sync failed"

# Pre-warm n1's module. `"provision": false` keeps n1 the thing this scenario
# describes: a verifier with no membership, whose register leg is meant to
# degrade. Since 0.8.0 `start` would otherwise spawn a provisioning task on
# n1's deliberately unfunded payer, which does not fail — it parks in
# awaiting_funding for fifteen minutes and muddies the degradation notice
# asserted below.
PREWARM=$(node_call n1 liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"],\"provision\":false}" | jres | jval) || PREWARM=""
case "$PREWARM" in
    *'"started":true'*) say "n1: rln module pre-warmed" ;;
    *) die "n1: rln module start (pre-warm) failed: ${PREWARM:-<empty>}" ;;
esac

section "n1 chat up (in-process rln bridge + chat peer B)"
node_watch_start n1 delivery_module
node_watch_start n1 chat_module
INIT=$(node_call n1 chat_module init "str:" | jres) || INIT=""
case "$INIT" in
    *'"success":true'*) say "n1: chat init accepted (conf via CHAT_DELIVERY_CONF_OVERRIDE)" ;;
    *) die "n1: chat init failed: ${INIT:-<empty>}" ;;
esac
# chat owns the delivery bootstrap: its init calls createNode AND start
# back-to-back, so unlike delivery-rln there is no window to wait in between.
# The wait here is therefore an ASSERTION, not a gate — by the time it runs
# start has already happened, and if the backend had not been ready for it the
# nodeStarted wait below is what fails. What this still buys is the scope
# check: that the preset the node resolved is the one this scenario staged.
delivery_wait_rln_ready n1
node_wait_event n1 delivery_module nodeStarted "$(( EVT_TIMEOUT * 4 ))" >/dev/null \
    || die "n1: no nodeStarted within $(( EVT_TIMEOUT * 4 ))s (chat bootstrap wedged?)"
B_ADDR=""
for _t in $(seq 1 30); do
    B_ADDR=$(node_call n1 chat_module get_address | jres | tr -d '"') || B_ADDR=""
    [ -n "$B_ADDR" ] && [ "${B_ADDR#\{}" = "$B_ADDR" ] && break
    B_ADDR=""
    sleep 2
done
[ -n "$B_ADDR" ] || die "n1: chat get_address never returned an address"
PEERID=$(must_call n1 getNodeInfo "getNodeInfo MyPeerId" MyPeerId)
[ -n "$PEERID" ] || die "n1: empty MyPeerId"
N1_MADDR="/ip4/127.0.0.1/tcp/$(( BASE_PORT + 1 ))/p2p/$PEERID"
say "n1: chat B up — addr $B_ADDR, maddr $N1_MADDR"

# n1 (unfunded, on purpose) degraded instead of breaking bring-up.
N1_REG="degradation notice not logged yet (register still in flight)"
if node_logs n1 | grep -q "RLN membership registration failed"; then
    N1_REG="degraded gracefully (notice logged)"
    say "n1: unfunded registration degraded gracefully (notice logged)"
else
    say "n1: no degradation notice yet (register still in flight — non-fatal)"
fi

# ---------- basecamp ---------------------------------------------------------
section "basecamp up (headless, side-loaded modules)"
# No rln-relay-registry-options at all: the registry is single-asset and
# nothing in the options names who pays any more. Who pays is the account the
# module derives in its own wallet home, which the harness funds below — not
# LEZ_RLN_PAYER on a copy of the staged home, which made the app sign as the
# deployment's own payer and put two processes on one nonce.
BC_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 2 ))" "$N1_MADDR" "")
basecamp_wallet_home "$E2E_RUN_DIR/wallet-basecamp"
basecamp_launch "$UD" "$E2E_RUN_DIR/wallet-basecamp" "$BC_CONF" \
    "$(delivery_rln_presets_env "$RLN_PRESETS_FILE")"

section "basecamp: load the module stack"
basecamp_load_modules liblogos_lez_rln_module liblogos_rln_module delivery_module chat_module

section "basecamp wallet (open + sync)"
basecamp_wallet_open_sync "$E2E_RUN_DIR/wallet-basecamp"

section "basecamp payer (derived by the module, funded by the harness)"
BC_PAYER=$(basecamp_payer) || die "basecamp: no payer"
if [ -n "${E2E_FUND_LATE:-}" ]; then
    # The production sequence: install delivery, start it, fund the account
    # whenever you get round to it. Everything below runs with an empty payer
    # and the transfer happens after chat is fully up — see the late-funding
    # section.
    say "basecamp: payer $BC_PAYER — funding deliberately withheld until after bring-up (E2E_FUND_LATE)"
else
    basecamp_fund || die "basecamp: funding failed"
    say "basecamp: payer $BC_PAYER funded — an account that held nothing until this transfer"
fi

# ---------- basecamp RLN + bridge + chat -------------------------------------
section "basecamp: rln pre-warm + bridge + chat init"
START_ARGS=$(jq -cn --arg c "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" '[$c]')
RSTART=$(bc_call liblogos_rln_module start "$START_ARGS") || RSTART=""
case "$RSTART" in
    *'"started":true'*) say "basecamp: rln module started" ;;
    *) die "basecamp: rln module start failed: ${RSTART:-<empty>}" ;;
esac
BINIT=$(bc_call chat_module init '[""]') || BINIT=""
case "$BINIT" in
    *'"success":true'*) say "basecamp: chat init accepted (conf via CHAT_DELIVERY_CONF_OVERRIDE)" ;;
    *) die "basecamp: chat init failed: ${BINIT:-<empty>}" ;;
esac
delivery_wait_rln_ready_bc
ONLINE=""
for _t in $(seq 1 60); do
    ST=$(bc_call chat_module status) || ST=""
    case "$ST" in
        *'"delivery_state":"online"'*) ONLINE=1; break ;;
        *'"delivery_state":"error"'*) die "basecamp: chat delivery errored: $ST" ;;
    esac
    sleep 2
done
[ -n "$ONLINE" ] || die "basecamp: chat never reached delivery_state=online"
A_ADDR=$(bc_call chat_module get_address | tr -d '"')
say "basecamp: chat online — addr ${A_ADDR:-<none>}"

# ---------- registration asserts ---------------------------------------------
# ---------- late funding (only when E2E_FUND_LATE is set) --------------------
# What a Basecamp user actually does: install delivery, start it, and get the
# native balance later — a bridge or an exchange, so hours, not minutes. Until
# liblogos_rln_module 0.8.1 that failed at fifteen minutes and failed for good,
# because the provisioning task is only ever entered from start(): fund at
# minute sixteen and the node never registered.
#
# So the whole bring-up above just ran against an EMPTY payer. Delivery is
# expected to have come up anyway — logos-delivery logs a notice, not an error,
# and gates sending rather than starting — and provisioning is expected to be
# parked, naming the account and the amount.
if [ -n "${E2E_FUND_LATE:-}" ]; then
    section "late funding (basecamp ran its whole bring-up with an empty payer)"
    grep -q "no usable RLN membership" "$E2E_RUN_DIR/basecamp.log" 2>/dev/null \
        && say "basecamp: delivery came up and logged the unfunded notice, as it should (sends gated, start not)"
    PARKED=""
    PROV=""
    for _t in $(seq 1 "$(polls "${E2E_AWAIT_FUNDING_S:-120}" "$E2E_POLL_INTERVAL_S")"); do
        PROV=$(bc_call liblogos_rln_module get_membership_state \
            "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" '[$r,$i]')" \
            | jfield provisioning) || PROV=""
        say "  basecamp provisioning poll $_t: ${PROV:-<none>}"
        case "$PROV" in
            *awaiting_funding*) PARKED=1; break ;;
            *refused*) die "basecamp: provisioning REFUSED rather than waiting — \
this is the 0.8.0 behaviour the unbounded wait replaced: $PROV" ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    [ -n "$PARKED" ] \
        || die "basecamp: provisioning never reported awaiting_funding (last: ${PROV:-<none>})"
    say "basecamp: parked at awaiting_funding with an empty payer — it names the account and the amount"
    basecamp_fund || die "basecamp: late funding failed"
    say "basecamp: funded AFTER the whole bring-up — the module must now recover with no restart"
fi

section "registration (the app pays; chat's boot and start's provisioning both reach here)"
STATE=""
GMS=""
for _t in $(seq 1 "$(polls "$REG_WAIT_S" 5)"); do
    GMS=$(bc_call liblogos_rln_module get_membership_state \
        "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" '[$r,$i]')") || GMS=""
    STATE=$(printf '%s' "$GMS" | grep -oE '"state":"[a-z_]+"' | head -1 | cut -d'"' -f4)
    case "$STATE" in
        pending|active|grace_period) break ;;
        failed) die "basecamp registration FAILED: $GMS" ;;
    esac
    sleep 5
done
case "$STATE" in
    pending|active|grace_period) say "basecamp membership state: $STATE" ;;
    *) die "basecamp never reached a live membership state (last: '${STATE:-<none>}' — $GMS)" ;;
esac
MEMS=$(bc_call liblogos_rln_module get_memberships "$(jq -cn --arg r "$REGISTRY_ID" '[$r]')") || MEMS=""
# Exactly one. Two paths can register here — chat's own boot under the configured
# scope, and `start`'s provisioning under the registry-wide one — and if both
# do, the app holds two leaves and two slices of the registry's rate-limit
# budget for one node, paid for twice. get_membership_state would not notice:
# a scoped record simply wins the scope_candidates preference. Count instead.
NMEMS=$(printf '%s' "$MEMS" | jq -r '.memberships | length' 2>/dev/null) || NMEMS=""
[ "$NMEMS" = 1 ] \
    || die "basecamp holds ${NMEMS:-<unreadable>} memberships on this registry, expected 1 — chat's register leg and start's provisioning both landed, which spends twice and takes two leaves: $MEMS"
IDC=$(printf '%s' "$MEMS" | jq -r '.memberships[0].credential.identity_commitment' 2>/dev/null) || IDC=""
[ -n "$IDC" ] && [ "$IDC" != "null" ] || die "cannot extract identity_commitment: $MEMS"

# WHICH path produced it. The module says so itself when provisioning is what
# registered — "provision <registry>: registered a registry-wide membership" —
# and says nothing there when chat's own register leg got in first. Report the
# answer rather than assert one: both are legitimate outcomes of this config,
# and which wins is a race the scenario does not control.
if grep -q "registered a registry-wide membership" "$E2E_RUN_DIR/basecamp.log" 2>/dev/null; then
    REG_PATH="provisioned by start (registry-wide scope)"
else
    REG_PATH="chat's own register leg (configured scope)"
fi
say "basecamp membership came from: $REG_PATH"
say "basecamp identity commitment: ${IDC:0:18}…"

# Chain oracle via n1 (the delivery-rln barrier: registered:true + real leaf,
# NOT waiting for ACTIVE).
confirm_and_ready n1 "$IDC" "" basecamp \
    || die "registry never confirmed basecamp's membership (registered:true)"
say "on-chain: registered:true at leaf $E2E_ACTUAL_LEAF"

# ---------- message leg -------------------------------------------------------
section "message leg (proof-gated chat, basecamp -> n1)"
# generate_proof selects only a USABLE membership (active/grace_period), so
# the message leg needs the pending -> active transition the chain applies
# after its confirmation window — the same wait delivery-rln makes before
# its send leg. (The registration assertion above is already satisfied.)
say "waiting for basecamp's membership to become active (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    GMS=$(bc_call liblogos_rln_module get_membership_state \
        "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" '[$r,$i]')") || GMS=""
    STATE=$(printf '%s' "$GMS" | grep -oE '"state":"[a-z_]+"' | head -1 | cut -d'"' -f4)
    say "  state poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed) die "basecamp membership FAILED after registration: $GMS" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
case "$STATE" in
    active|grace_period) say "basecamp membership $STATE" ;;
    *) die "basecamp membership never became active (last: ${STATE:-<none>})" ;;
esac
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"

# n1's valid-root window must be warm before its validator sees the message
# (the delivery-rln wallet-churn lesson).
ROOTS_WARM_BUDGET_S="${E2E_ROOTS_WARM_BUDGET_S:-300}"
ROOTS_T0=$(date +%s)
while :; do
    ROOTS_N1=$(node_call n1 liblogos_rln_module get_valid_roots "$REGISTRY_ID" 2>/dev/null | jres) || ROOTS_N1=""
    case "$ROOTS_N1" in *'"valid_roots":["'*) break ;; esac
    [ $(( $(date +%s) - ROOTS_T0 )) -ge "$ROOTS_WARM_BUDGET_S" ] \
        && die_node n1 "registry read path never warmed in ${ROOTS_WARM_BUDGET_S}s — last: ${ROOTS_N1:-<empty>}"
    sleep 5
done
say "n1 root window warm after $(( $(date +%s) - ROOTS_T0 ))s"

CC=$(bc_call chat_module create_conversation "$(jq -cn --arg a "$B_ADDR" '[$a]')") || CC=""
case "$CC" in
    *'"success":true'*) say "basecamp: conversation to B created" ;;
    *) die "basecamp: create_conversation failed: ${CC:-<empty>}" ;;
esac
node_wait_event n1 chat_module conversation_created "$(( EVT_TIMEOUT * 2 ))" >/dev/null \
    || die "n1 chat never saw the conversation invite (mesh? proof gate? see n1 log)"
say "n1: conversation invite crossed the RLN-gated transport"

LC=$(bc_call chat_module list_conversations) || LC=""
CONVO=$(printf '%s' "$LC" | jq -r '.[0].convo_id' 2>/dev/null) || CONVO=""
[ -n "$CONVO" ] && [ "$CONVO" != "null" ] || die "cannot extract convo_id: $LC"

RECEIVED=0
ATTEMPT=0
while [ "$ATTEMPT" -lt "$SEND_ATTEMPTS" ]; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    PAYLOAD="rln-gated chat ping $ATTEMPT"
    SM=$(bc_call chat_module send_message \
        "$(jq -cn --arg c "$CONVO" --arg t "$PAYLOAD" '[$c,$t]')") || SM=""
    case "$SM" in
        *'"success":true'*) : ;;
        *) die "basecamp: send_message failed: ${SM:-<empty>}" ;;
    esac
    if node_wait_event n1 chat_module message_received "$RECV_WAIT_S" "$PAYLOAD" >/dev/null; then
        RECEIVED=1
        say "attempt $ATTEMPT: n1 chat received the plaintext — decrypt + proof gate crossed"
        break
    fi
    say "attempt $ATTEMPT: not received on n1 (fresh-root window?) — retrying"
    sleep 3
done
[ "$RECEIVED" = 1 ] \
    || die "n1 never received a chat message in $SEND_ATTEMPTS attempts"

# The transport leg is the proof-gated delivery topic (chat rides
# /logos-chat/1/<addr>/proto); n1 mounts RLN from the preset, so messageReceived only
# surfaces after its in-process bridge validated the proof.
node_wait_event n1 delivery_module messageReceived 5 "/logos-chat/1/" >/dev/null \
    || say "note: no delivery messageReceived event matched the chat topic (event may predate the watch) — chat receipt already proves the pipeline"

echo
echo "e2e: PASS — chat-basecamp-rln (target $E2E_TARGET)"
echo "e2e:   product   chat_module -> delivery_module -> RLN stack co-resident INSIDE Basecamp (headless, side-loaded, embedded logos-core)"
echo "e2e:   driving   inspector evaluate -> backend.callCoreModuleMethod (loadCoreModule + every module call)"
echo "e2e:   config    the fork's CHAT_DELIVERY_CONF_OVERRIDE carried the conf; every rln key is gone from it and the scope came from the RLN preset"
echo "e2e:   register  $REG_PATH, paid from the app's OWN payer $BC_PAYER: state=$STATE, on-chain registered:true at leaf $E2E_ACTUAL_LEAF (oracle: n1)"
echo "e2e:   degrade   n1's unfunded best-effort register: $N1_REG; node validates fine"
echo "e2e:   message   basecamp send_message -> proof attached -> gossipsub -> n1 validate (in-process bridge) -> chat message_received (attempt $ATTEMPT/$SEND_ATTEMPTS)"
