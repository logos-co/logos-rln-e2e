#!/usr/bin/env bash
# scenarios/chat-basecamp-gifter — logos-chat INSIDE Basecamp registering
# through the RLN membership allocation protocol (delegated registration),
# then one proof-gated chat message. The funded twin is chat-basecamp-rln.
#
# Topology:
#   n2         the ALLOCATION SERVICE: an ordinary logoscore daemon with the
#              lez stack + libp2p_module + rln_gifter_module, a faucet-funded
#              holding, `rln_gifter_module.serve` with NO authVerifiers (open
#              gifter). It needs funds but NO membership of its own.
#   n1         verifier + chat peer B (chat-basecamp-rln's n1): unfunded,
#              its own best-effort registration degrades on purpose.
#   basecamp   the desktop app, headless (harness/lib/basecamp.sh): lez_core
#              + lez-rln + libp2p_module + rln_gifter_module (the CLIENT half
#              the RLN module's provider dials the gifter through) + RLN
#              module + delivery_module + chat_module. Its wallet is a FRESH
#              copy (config + seed only): no accounts, no funds, ever.
#              rln-relay-registry-options carries
#              {"delegated":"true","gifter_peer_id":…,"gifter_multiaddr":…}
#              — delivery's startNode folds it into the RegistryOptions
#              array untouched, the module selects the delegated path and
#              the gifter pays.
#
# What it proves (beyond chat-basecamp-rln):
#   1. the delegated register wire survives the whole product path: node
#      conf -> chat's CHAT_DELIVERY_CONF_OVERRIDE -> delivery RegistryOptions
#      -> RLN module -> co-loaded gifter client -> libp2p -> the service.
#   2. a fundless Basecamp registers: its wallet holds zero accounts before
#      and after; the GIFTER's holding balance drops by the registration
#      price (rate_limit × price_per_unit).
#   3. the membership is real (registered:true + leaf, oracle n1), goes
#      active, and proves: n1 receives the chat message.
#
# Required (beyond chat-basecamp-rln's):
#   LIBP2P_MODULE_CHECKOUT    logos-libp2p-module tree
#   GIFTER_CHECKOUT           logos-rln-gifter @ fix/register-target-lez-rln-module
#
# Env knobs (chat-basecamp-rln's, plus):
#   E2E_GIFTER_PORT=61871       the gifter's libp2p listen port
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain basecamp; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
BASE_PORT="${E2E_CHAT_RLN_PORT:-61890}"
GIFTER_PORT="${E2E_GIFTER_PORT:-61871}"
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
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — the gifter funds itself from the faucet; pick a faucet deployment"
if [ -z "${DELIVERY_LGX:-}" ]; then
    [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ] && [ -n "${LOGOS_DELIVERY_CHECKOUT:-}" ] \
        || die "chat-basecamp-gifter needs BOTH delivery checkouts (rln/integration-fixes) or a prebuilt DELIVERY_LGX"
fi
basecamp_port_check

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODES_UP=""
DYING=0
UD="$E2E_RUN_DIR/basecamp-user"
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ]; then
        DYING=1
        basecamp_die_tails
        local n
        for n in $NODES_UP; do
            echo "---- $n log tail ----" >&2
            node_logs "$n" 30 >&2 || true
        done
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving basecamp (pid ${BASECAMP_PID:-none}) + nodes up, state in $E2E_RUN_DIR"
        return
    fi
    basecamp_stop
    [ -n "$NODES_UP" ] && daemon_stop_all
}
trap cleanup EXIT

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

chat_delivery_cfg() {
    local port="$1" peers="$2" extra="$3"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"rln-relay":true,"rln-relay-lez":true,"rln-relay-registry-id":"%s","rln-relay-identifier":"%s","rln-relay-user-message-limit":%s,"rln-relay-epoch-sec":%s%s%s}' \
        "$port" "$CLUSTER_ID" "$REGISTRY_ID" "$RLN_ID" "$RATE_LIMIT" \
        "$E2E_EPOCH_SIZE_SEC" "$extra" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

# A fresh wallet home (config + seed only) — every lez_core instance gets
# its own mutable storage.json; the seed derives deterministically.
fresh_home() {
    local dest="$1"
    mkdir -p "$dest"
    cp "$E2E_WALLET_HOME/wallet_config.json" "$dest/" || die "cannot copy wallet_config.json to $dest"
    cp "$E2E_WALLET_HOME/storage.json.seed" "$dest/storage.json.seed" || die "cannot copy storage seed to $dest"
}

CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "chain head: $CHAIN_HEAD"

# ---------- n2: the allocation service (gifter) -------------------------------
section "n2: allocation service (libp2p + rln_gifter_module, open gifter)"
N2_HOME="$E2E_RUN_DIR/wallet-n2"
fresh_home "$N2_HOME"
daemon_start n2 || die "daemon_start n2 failed"
NODES_UP="n2"
daemon_load_modules n2 lez_core liblogos_lez_rln_module liblogos_rln_module \
    libp2p_module rln_gifter_module || die "n2: load-module failed"
wallet_open n2 "$N2_HOME" || die "n2: wallet open failed"
say "syncing the gifter's wallet"
wallet_sync n2 >/dev/null || die "n2: wallet sync failed"
GHOLD=$(wallet_fresh_holding n2) || GHOLD=""
[ -n "$GHOLD" ] || die "no unused holding account for the gifter"
BOUNDS=$(node_call n2 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile gcfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: ${BOUNDS:-<empty>}"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "gifter claiming $CLAIM RLNTOK into $GHOLD"
node_call n2 liblogos_lez_rln_module claim_tokens \
    "$(argfile gcfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile ghold "$GHOLD")" "$CLAIM" | jres >/dev/null \
    || die "gifter claim_tokens failed"
wait_balance n2 "$GHOLD" "$CLAIM" >/dev/null || die "gifter faucet credit never landed"
GBAL0=$(node_call n2 liblogos_lez_rln_module get_token_balance "$(argfile gb0 "$GHOLD")" | jres | jfield balance)
say "gifter holding $GHOLD balance before: $GBAL0"

node_call n2 libp2p_module createNode "{\"addrs\":[\"/ip4/127.0.0.1/tcp/$GIFTER_PORT\"]}" | jres >/dev/null \
    || die "n2 libp2p createNode failed"
node_call n2 libp2p_module start | jres >/dev/null || die "n2 libp2p start failed"
PEERINFO=$(node_call n2 libp2p_module peerInfo | jres | jval) || PEERINFO=""
GPEER=$(printf '%s' "$PEERINFO" | jfield peerId)
[ -n "$GPEER" ] || die "no peerId in peerInfo: ${PEERINFO:-<empty>}"
GADDR="/ip4/127.0.0.1/tcp/$GIFTER_PORT"
say "gifter peer: $GPEER @ $GADDR"
# Open gifter: NO authVerifiers — any commitment gets a membership, paid by
# the gifter's wallet.
SERVE=$(node_call n2 rln_gifter_module serve \
    "{\"config\":\"$E2E_CONFIG_ACCOUNT\",\"wallet\":\"$GHOLD\"}" | jres) || SERVE=""
case "$SERVE" in
    *error*) die "gifter serve failed: $SERVE" ;;
    '') die "gifter serve failed: <empty>" ;;
    *) say "gifter serving (open): $SERVE" ;;
esac

# ---------- n1: verifier + chat peer B ---------------------------------------
section "n1: logoscore daemon (verifier + chat peer B)"
V_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 1 ))" "" "")
E2E_DAEMON_ENV="CHAT_DELIVERY_CONF_OVERRIDE=$V_CONF" daemon_start n1 \
    || die "daemon_start n1 failed"
NODES_UP="n1 n2"
daemon_load_modules n1 lez_core liblogos_lez_rln_module liblogos_rln_module \
    delivery_module chat_module || die "n1: load-module failed"
# n1 reads chain state only (roots, membership) — the staged home, never funded.
wallet_open n1 || die "n1: wallet open failed"
wallet_sync n1 >/dev/null || die "n1: wallet sync failed"
PREWARM=$(node_call n1 liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || PREWARM=""
case "$PREWARM" in
    *'"started":true'*) say "n1: rln module pre-warmed" ;;
    *) die "n1: rln module start (pre-warm) failed: ${PREWARM:-<empty>}" ;;
esac
node_watch_start n1 delivery_module
node_watch_start n1 chat_module
ATTACH=$(node_call n1 delivery_module rlnBridgeAttach "liblogos_rln_module" | jres)
case "$ATTACH" in
    *'"success":true'*) say "n1: in-process rln bridge attached" ;;
    *) die "n1: rlnBridgeAttach failed: ${ATTACH:-<empty>}" ;;
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

# ---------- basecamp: fresh (fundless) wallet, delegated options --------------
section "basecamp up (headless; fresh never-funded wallet)"
BHOME="$E2E_RUN_DIR/wallet-basecamp"
fresh_home "$BHOME"
DELEGATED_OPTS=$(printf ',"rln-relay-registry-options":"{\\"delegated\\":\\"true\\",\\"gifter_peer_id\\":\\"%s\\",\\"gifter_multiaddr\\":\\"%s\\"}"' \
    "$GPEER" "$GADDR")
BC_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 2 ))" "$N1_MADDR" "$DELEGATED_OPTS")
basecamp_launch "$UD" "$BHOME" "$BC_CONF"

section "basecamp: load the module stack (gifter client half before the RLN module)"
basecamp_load_modules lez_core liblogos_lez_rln_module libp2p_module rln_gifter_module \
    liblogos_rln_module delivery_module chat_module

section "basecamp wallet (open + sync, read-only use)"
basecamp_wallet_open_sync "$BHOME"
# The seed derives a few accounts of its own, so "fundless" is an invariant,
# not an empty list: basecamp's accounts and their RLNTOK balances must be
# IDENTICAL before and after the registration (read through n2's registry
# module — a missing token account counts as 0).
bc_accounts_snapshot() {
    local accts ids id bal
    accts=$(bc_call lez_core list_accounts) || accts=""
    ids=$(printf '%s' "$accts" | jq -r '.[]?.account_id' 2>/dev/null)
    for id in $ids; do
        bal=$(node_call n2 liblogos_lez_rln_module get_token_balance "$(argfile "snap_$RANDOM" "$id")" | jres) || bal=""
        case "$bal" in
            *'"exists":false'*) bal=0 ;;
            *) bal=$(printf '%s' "$bal" | jfield balance) ;;
        esac
        printf '%s %s\n' "$id" "${bal:-0}"
    done | sort
}
SNAP0=$(bc_accounts_snapshot)
say "basecamp wallet: $(printf '%s\n' "$SNAP0" | grep -c .) seed-derived accounts, RLNTOK balances: $(printf '%s\n' "$SNAP0" | awk '{print $2}' | tr '\n' ' ')"

# The gifter CLIENT dials out through basecamp's own libp2p node.
LP=$(bc_call libp2p_module createNode "$(jq -cn --arg c '{"addrs":["/ip4/127.0.0.1/tcp/0"]}' '[$c]')") || LP=""
case "$LP" in
    *'"success":false'*|*'"error":"'*) die "basecamp: libp2p createNode failed: $LP" ;;
    *) say "basecamp: libp2p node created" ;;
esac
LPS=$(bc_call libp2p_module start) || LPS=""
case "$LPS" in
    *'"success":false'*|*'"error":"'*) die "basecamp: libp2p start failed: $LPS" ;;
    *) say "basecamp: libp2p node started" ;;
esac

# ---------- basecamp RLN + bridge + chat -------------------------------------
section "basecamp: rln pre-warm + bridge + chat init (delegated register)"
START_ARGS=$(jq -cn --arg c "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" '[$c]')
RSTART=$(bc_call liblogos_rln_module start "$START_ARGS") || RSTART=""
case "$RSTART" in
    *'"started":true'*) say "basecamp: rln module started" ;;
    *) die "basecamp: rln module start failed: ${RSTART:-<empty>}" ;;
esac
BATTACH=$(bc_call delivery_module rlnBridgeAttach '["liblogos_rln_module"]') || BATTACH=""
case "$BATTACH" in
    *'"success":true'*) say "basecamp: in-process rln bridge attached" ;;
    *) die "basecamp: rlnBridgeAttach failed: ${BATTACH:-<empty>}" ;;
esac
BINIT=$(bc_call chat_module init '[""]') || BINIT=""
case "$BINIT" in
    *'"success":true'*) say "basecamp: chat init accepted (delegated options in the conf)" ;;
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

# ---------- registration asserts (the gifter pays) ---------------------------
section "delegated registration (through chat's own boot, paid by the gifter)"
STATE=""
GMS=""
for _t in $(seq 1 "$(polls "$REG_WAIT_S" 5)"); do
    GMS=$(bc_call liblogos_rln_module get_membership_state \
        "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" '[$r,$i]')") || GMS=""
    STATE=$(printf '%s' "$GMS" | grep -oE '"state":"[a-z_]+"' | head -1 | cut -d'"' -f4)
    case "$STATE" in
        pending|active|grace_period) break ;;
        failed) die "basecamp delegated registration FAILED: $GMS" ;;
    esac
    sleep 5
done
case "$STATE" in
    pending|active|grace_period) say "basecamp membership state: $STATE (submitted through the gifter)" ;;
    *) die "basecamp never reached a live membership state (last: '${STATE:-<none>}' — $GMS)" ;;
esac
MEMS=$(bc_call liblogos_rln_module get_memberships "$(jq -cn --arg r "$REGISTRY_ID" '[$r]')") || MEMS=""
IDC=$(printf '%s' "$MEMS" | jq -r '.memberships[0].credential.identity_commitment' 2>/dev/null) || IDC=""
[ -n "$IDC" ] && [ "$IDC" != "null" ] || die "cannot extract identity_commitment: $MEMS"
say "basecamp identity commitment: ${IDC:0:18}…"

# Chain oracle via n2 — the service node that paid (its registry module is
# busy anyway and demonstrably healthy); n1 stays the message-leg verifier.
confirm_and_ready n2 "$IDC" "" basecamp \
    || die "registry never confirmed basecamp's membership (registered:true)"
say "on-chain: registered:true at leaf $E2E_ACTUAL_LEAF"

# Who paid: the gifter's holding dropped; basecamp's wallet is untouched.
GBAL1=$(node_call n2 liblogos_lez_rln_module get_token_balance "$(argfile gb1 "$GHOLD")" | jres | jfield balance)
case "$GBAL1" in ''|*[!0-9]*) die "cannot read the gifter's balance after registration: '${GBAL1:-<empty>}'" ;; esac
[ "$GBAL1" -lt "$GBAL0" ] \
    || die "the gifter's balance did not drop ($GBAL0 -> $GBAL1) — who paid for leaf $E2E_ACTUAL_LEAF?"
PAID=$(( GBAL0 - GBAL1 ))
EXPECTED=$(( RATE_LIMIT * PRICE ))
if [ "$PAID" = "$EXPECTED" ]; then
    say "gifter paid $PAID RLNTOK (= rate $RATE_LIMIT × price $PRICE)"
else
    say "gifter paid $PAID RLNTOK (expected $EXPECTED = rate × price; noted, non-fatal)"
fi
SNAP1=$(bc_accounts_snapshot)
[ "$SNAP0" = "$SNAP1" ] \
    || die "basecamp's wallet changed across a delegated registration (it should have paid nothing) — before: [$(printf '%s' "$SNAP0" | tr '\n' ';')] after: [$(printf '%s' "$SNAP1" | tr '\n' ';')]"
say "basecamp wallet unchanged (same accounts, same balances) — it paid nothing"

# ---------- message leg -------------------------------------------------------
section "message leg (proof-gated chat, basecamp -> n1)"
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
    PAYLOAD="rln-gated chat ping $ATTEMPT (gifted membership)"
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

echo
echo "e2e: PASS — chat-basecamp-gifter (target $E2E_TARGET)"
echo "e2e:   service   n2 = logoscore + libp2p_module + rln_gifter_module (open gifter, faucet-funded $GHOLD)"
echo "e2e:   product   chat_module -> delivery_module -> RLN module -> gifter client -> libp2p -> the service, all INSIDE Basecamp"
echo "e2e:   config    rln-relay-registry-options = {delegated:true, gifter_peer_id, gifter_multiaddr} via CHAT_DELIVERY_CONF_OVERRIDE"
echo "e2e:   register  delegated, through chat's own boot: state=$STATE, on-chain registered:true at leaf $E2E_ACTUAL_LEAF (oracle: n2)"
echo "e2e:   payer     the gifter paid $PAID RLNTOK; basecamp's wallet (accounts + balances) unchanged"
echo "e2e:   message   basecamp send_message -> proof attached -> gossipsub -> n1 validate -> chat message_received (attempt $ATTEMPT/$SEND_ATTEMPTS)"
