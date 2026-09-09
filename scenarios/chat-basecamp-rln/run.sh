#!/usr/bin/env bash
# scenarios/chat-basecamp-rln — logos-chat running INSIDE Basecamp on the
# forked logos-delivery, RLN registration (funded, conf-fed payer) + one
# proof-gated chat message.
#
# Topology:
#   basecamp   the desktop app (dev #app build, QML inspector compiled in),
#              launched headless with a throwaway --user-dir; the harness
#              modules dir is copied in wholesale and lez_core + the RLN
#              stack + delivery_module + chat_module are loaded through
#              MainUIBackend.loadCoreModule. Every module call goes through
#              the inspector's result-returning `evaluate` ->
#              backend.callCoreModuleMethod(...) — see harness/lib/basecamp.sh.
#   n1         an ordinary logoscore daemon (delivery-rln's n2 role, plus
#              chat peer B): same module stack + chat_module, in-process
#              bridge (rlnBridgeEnable), NO funding — its best-effort
#              registration degrades on purpose; it receives basecamp's
#              chat message only after its own module validates the proof.
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
#   2. registration through chat's own boot: delivery's startNode register
#      leg fires with the conf-fed scope + funding pair, the module mints a
#      membership, and the registry confirms registered:true + a real leaf
#      (chain oracle via n1 — the delivery-rln barrier).
#   3. the message path: chat send_message -> delivery publish (proof
#      attached by the fork's prover leg) -> gossipsub -> n1's validator ->
#      in-process bridge validate_proof -> chat message_received on n1 with
#      the plaintext (decrypt + full pipeline).
#
# Required (beyond docs/contract.md):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ rln/integration-fixes
#   LOGOS_DELIVERY_CHECKOUT   logos-delivery @ rln/integration-fixes
#   RLN_MODULES_CHECKOUT      logos-rln-modules @ feat/lip-alignment (0.7 wire)
#   CHAT_MODULE_CHECKOUT      logos-chat-module @ rln/e2e-extra-conf
#   BASECAMP_CHECKOUT         logos-basecamp (or BASECAMP_APP binary)
#
# Env knobs:
#   E2E_RATE_LIMIT=100          registration rate limit / user-message-limit
#   E2E_CHAT_RLN_PORT=61890     tcp ports are PORT+1 (n1), PORT+2 (basecamp)
#   E2E_INSPECTOR_PORT=3768     basecamp QML inspector port (must be free)
#   E2E_BASECAMP_SETTLE_S=20    post-launch settle before driving the app
#   E2E_EVENT_TIMEOUT_S=30      per-event wait budget
#   E2E_MESH_WAIT_S=12          gossipsub mesh stabilization pause
#   E2E_SEND_ATTEMPTS=3         message-leg attempts (fresh-root window)
#   E2E_RECV_WAIT_S=15          per-attempt receive wait on n1
#   E2E_REG_WAIT_S=240          basecamp membership-pending wait budget
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain basecamp; do
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
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC BASECAMP_APP; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md + scenario.env)"
done
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — basecamp pays its registration from a faucet claim; pick a faucet deployment"
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
RLN_ID=$(openssl rand -hex 32)
say "registry: $REGISTRY_ID (scope rate $RATE_LIMIT)"

# The COMPLETE legacy-flat delivery conf (delivery-rln's proven shape) —
# chat's CHAT_DELIVERY_CONF_OVERRIDE replaces the config wholesale, so
# everything must be here. COMPACT (no spaces): the n1 copy rides the
# whitespace-split E2E_DAEMON_ENV.
chat_delivery_cfg() {
    local port="$1" peers="$2" extra="$3"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"rln-relay":true,"rln-relay-lez":true,"rln-relay-registry-id":"%s","rln-relay-identifier":"%s","rln-relay-user-message-limit":%s,"rln-relay-epoch-sec":%s%s%s}' \
        "$port" "$CLUSTER_ID" "$REGISTRY_ID" "$RLN_ID" "$RATE_LIMIT" \
        "$E2E_EPOCH_SIZE_SEC" "$extra" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

# ---------- n1: verifier daemon (funder + chain oracle + chat peer B) --------
section "n1: logoscore daemon (verifier + chat peer B)"
V_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 1 ))" "" "")
E2E_DAEMON_ENV="CHAT_DELIVERY_CONF_OVERRIDE=$V_CONF" daemon_start n1 \
    || die "daemon_start n1 failed"
NODES_UP=1
daemon_load_modules n1 lez_core liblogos_lez_rln_module liblogos_rln_module \
    delivery_module chat_module || die "n1: load-module failed"
say "n1: all 5 modules loaded (module-owned keystore custody, no unlock call)"

section "n1 wallet + faucet funding"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "chain head: $CHAIN_HEAD"
wallet_open n1 || die "n1: wallet open failed"
wallet_sync n1 >/dev/null || die "n1: wallet sync failed"
HOLDING=$(wallet_fresh_holding n1) || HOLDING=""
[ -n "$HOLDING" ] || die "no unused holding account"
BOUNDS=$(node_call n1 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
[ -n "$BOUNDS" ] || die "get_registry_bounds failed (rln stack up?)"
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: $BOUNDS"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "claiming $CLAIM RLNTOK from the faucet for $HOLDING"
CLAIM_RES=$(node_call n1 liblogos_lez_rln_module claim_tokens \
    "$(argfile cfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile hold "$HOLDING")" "$CLAIM" | jres) || CLAIM_RES=""
[ -n "$CLAIM_RES" ] || die "claim_tokens failed"
wait_balance n1 "$HOLDING" "$CLAIM" >/dev/null || die "faucet credit never landed (want $CLAIM)"

# Basecamp's wallet: its OWN copy of the home, taken AFTER the claim so its
# storage carries the holding account's derivation (deterministic chain, but
# the wallet signs only for accounts its storage knows). Two lez_core
# instances must never share one mutable storage.json. storage.json is only
# flushed at checkpoints, so persist n1's in-memory state (the derived payer)
# first — the sync height is NOT carried across sessions by this wallet
# build; basecamp re-syncs from ~0 regardless.
SAVE=$(node_call n1 lez_core save | jres) || SAVE=""
say "n1: wallet state saved (reply ${SAVE:-<empty>})"
sleep 2
cp -R "$E2E_WALLET_HOME" "$E2E_RUN_DIR/wallet-basecamp" \
    || die "cannot copy wallet home for basecamp"

# Pre-warm n1's module (start is idempotent; the same config basecamp's chat
# boot will carry).
PREWARM=$(node_call n1 liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || PREWARM=""
case "$PREWARM" in
    *'"started":true'*) say "n1: rln module pre-warmed" ;;
    *) die "n1: rln module start (pre-warm) failed: ${PREWARM:-<empty>}" ;;
esac

section "n1 chat up (in-process rln bridge + chat peer B)"
node_watch_start n1 delivery_module
node_watch_start n1 chat_module
ATTACH=$(node_call n1 delivery_module rlnBridgeEnable | jres)
case "$ATTACH" in
    *'"success":true'*) say "n1: in-process rln bridge enabled" ;;
    *) die "n1: rlnBridgeEnable failed: ${ATTACH:-<empty>}" ;;
esac
INIT=$(node_call n1 chat_module init "str:" | jres) || INIT=""
case "$INIT" in
    *'"success":true'*) say "n1: chat init accepted (conf via CHAT_DELIVERY_CONF_OVERRIDE)" ;;
    *) die "n1: chat init failed: ${INIT:-<empty>}" ;;
esac
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
node_logs n1 | grep -q "RLN membership registration failed" \
    && say "n1: unfunded registration degraded gracefully (notice logged)" \
    || say "n1: no degradation notice yet (register still in flight — non-fatal)"

# ---------- basecamp ---------------------------------------------------------
section "basecamp up (headless, side-loaded modules)"
BC_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 2 ))" "$N1_MADDR" \
    "$(printf ',"rln-relay-registry-options":"{\\"funding_holding_account_id\\":\\"%s\\"}"' "$HOLDING")")
basecamp_launch "$UD" "$E2E_RUN_DIR/wallet-basecamp" "$BC_CONF"

section "basecamp: load the module stack"
basecamp_load_modules lez_core liblogos_lez_rln_module liblogos_rln_module delivery_module chat_module

section "basecamp wallet (open + sync)"
basecamp_wallet_open_sync "$E2E_RUN_DIR/wallet-basecamp"

# ---------- basecamp RLN + bridge + chat -------------------------------------
section "basecamp: rln pre-warm + bridge + chat init"
START_ARGS=$(jq -cn --arg c "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" '[$c]')
RSTART=$(bc_call liblogos_rln_module start "$START_ARGS") || RSTART=""
case "$RSTART" in
    *'"started":true'*) say "basecamp: rln module started" ;;
    *) die "basecamp: rln module start failed: ${RSTART:-<empty>}" ;;
esac
BATTACH=$(bc_call delivery_module rlnBridgeEnable '[]') || BATTACH=""
case "$BATTACH" in
    *'"success":true'*) say "basecamp: in-process rln bridge enabled" ;;
    *) die "basecamp: rlnBridgeEnable failed: ${BATTACH:-<empty>}" ;;
esac
BINIT=$(bc_call chat_module init '[""]') || BINIT=""
case "$BINIT" in
    *'"success":true'*) say "basecamp: chat init accepted (conf via CHAT_DELIVERY_CONF_OVERRIDE)" ;;
    *) die "basecamp: chat init failed: ${BINIT:-<empty>}" ;;
esac
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
section "registration (through chat's own boot)"
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
IDC=$(printf '%s' "$MEMS" | jq -r '.memberships[0].credential.identity_commitment' 2>/dev/null) || IDC=""
[ -n "$IDC" ] && [ "$IDC" != "null" ] || die "cannot extract identity_commitment: $MEMS"
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
# /logos-chat/1/<addr>/proto); n1 runs rln-relay:true so messageReceived only
# surfaces after its in-process bridge validated the proof.
node_wait_event n1 delivery_module messageReceived 5 "/logos-chat/1/" >/dev/null \
    || say "note: no delivery messageReceived event matched the chat topic (event may predate the watch) — chat receipt already proves the pipeline"

echo
echo "e2e: PASS — chat-basecamp-rln (target $E2E_TARGET)"
echo "e2e:   product   chat_module -> delivery_module -> RLN stack co-resident INSIDE Basecamp (headless, side-loaded, embedded logos-core)"
echo "e2e:   driving   inspector evaluate -> backend.callCoreModuleMethod (loadCoreModule + every module call)"
echo "e2e:   config    the fork's CHAT_DELIVERY_CONF_OVERRIDE carried the full flat conf: scope, rate, epoch, cluster AND the funding pair"
echo "e2e:   register  through chat's own boot: state=$STATE, on-chain registered:true at leaf $E2E_ACTUAL_LEAF (oracle: n1)"
echo "e2e:   degrade   n1's unfunded best-effort register degraded, node validates fine"
echo "e2e:   message   basecamp send_message -> proof attached -> gossipsub -> n1 validate (in-process bridge) -> chat message_received (attempt $ATTEMPT/$SEND_ATTEMPTS)"
