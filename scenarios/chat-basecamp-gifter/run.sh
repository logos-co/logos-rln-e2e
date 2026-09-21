#!/usr/bin/env bash
# scenarios/chat-basecamp-gifter — logos-chat INSIDE Basecamp registering
# through the RLN membership allocation protocol (delegated registration),
# then one proof-gated chat message. The funded twin is chat-basecamp-rln.
#
# Topology:
#   n2         the ALLOCATION SERVICE: an ordinary logoscore daemon with the
#              lez stack + libp2p_module + rln_gifter_module, its own payer
#              funded with NATIVE balance, `rln_gifter_module.serve` with NO
#              authVerifiers (open gifter). serve's `wallet` is that payer:
#              the registry is single-asset, so the account the gifter names
#              signs the Register tx, pays the price and pays the fee. It
#              needs funds but NO membership of its own.
#   n1         verifier + chat peer B (chat-basecamp-rln's n1): a wallet of
#              its own that is never funded, so its own best-effort
#              registration degrades on purpose.
#   basecamp   the desktop app, headless (harness/lib/basecamp.sh): lez-rln
#              + libp2p_module + rln_gifter_module (the CLIENT half the RLN
#              module's provider dials the gifter through) + RLN module +
#              delivery_module + chat_module. Its wallet home carries the
#              staged wallet_config.json and NOTHING else, so the module
#              derives a payer that has never held anything — asserted on
#              chain, before and after, rather than assumed.
#              The delegated options —
#              {"delegated":"true","gifter_peer_id":…,"gifter_multiaddr":…}
#              — go to register_membership directly; the module selects the
#              delegated path and the gifter pays. They used to ride the
#              delivery conf, which has no successor key (see the
#              registration section).
#
# What it proves (beyond chat-basecamp-rln):
#   1. the delegated register wire survives the product path it still has:
#      RegistryOptions -> RLN module -> co-loaded gifter client -> libp2p ->
#      the service, all inside Basecamp's embedded core. The leg from a
#      delivery conf is NOT covered any more and cannot be: upstream
#      logos-delivery dropped every LEZ conf key and the RLN preset carries
#      only registry-id / rln-identifier / epoch-size-sec, so there is no
#      route from a node conf to the allocation protocol to test.
#   2. a fundless Basecamp registers: its accounts' native balances are
#      identical before and after, its payer is not the gifter's, and the
#      GIFTER's native balance drops — by the registration price
#      (rate_limit × price_per_unit) plus the transaction's fee, which the
#      same account now pays out of the same asset.
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
for _lib in compat json lgx daemon wallet chain basecamp delivery; do
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
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_PAYER E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC BASECAMP_APP; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md + scenario.env)"
done
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
    local port="$1" peers="$2"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true%s}' \
        "$port" "$CLUSTER_ID" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

# The scope, as the RLN preset carries it. Staged before the daemon starts and
# before the app launches: each reads the path from its own environment, and
# createNode is what resolves it.
RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC"

CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "chain head: $CHAIN_HEAD"

# ---------- n2: the allocation service (gifter) -------------------------------
section "n2: allocation service (libp2p + rln_gifter_module, open gifter)"
# The gifter's own wallet — config only, no storage: the module derives a
# payer nothing else holds, which is what lets "the gifter paid" be checked
# rather than assumed. Handing it the deployment's shared payer would fund
# n1 and (via the same account) blur who paid for basecamp's membership.
N2_HOME="$E2E_RUN_DIR/wallet-n2"
daemon_self_paying n2 "$N2_HOME"
daemon_start n2 || die "daemon_start n2 failed"
NODES_UP="n2"
daemon_load_modules n2 liblogos_lez_rln_module liblogos_rln_module \
    libp2p_module rln_gifter_module || die "n2: load-module failed"
wallet_open n2 || die "n2: wallet open failed"
say "syncing the gifter's wallet"
wallet_sync n2 >/dev/null || die "n2: wallet sync failed"
BOUNDS=$(node_call n2 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile gcfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: ${BOUNDS:-<empty>}"
# The gifter is the only wallet here that must hold money: it pays for
# somebody else's membership out of its own NATIVE balance. basecamp is left
# alone on purpose — the whole point is that it never pays.
GPAYER=$(wallet_payer n2) || die "the gifter's registry module published no payer"
wallet_fund n2 >/dev/null || die "funding the gifter's payer $GPAYER never landed"
GBAL0=$(wallet_native_balance n2 "$GPAYER")
case "$GBAL0" in ''|*[!0-9]*) die "cannot read the gifter's native balance: '${GBAL0:-<empty>}'" ;; esac
say "gifter payer $GPAYER balance before: $GBAL0"

node_call n2 libp2p_module createNode "{\"addrs\":[\"/ip4/127.0.0.1/tcp/$GIFTER_PORT\"]}" | jres >/dev/null \
    || die "n2 libp2p createNode failed"
node_call n2 libp2p_module start | jres >/dev/null || die "n2 libp2p start failed"
PEERINFO=$(node_call n2 libp2p_module peerInfo | jres | jval) || PEERINFO=""
GPEER=$(printf '%s' "$PEERINFO" | jfield peerId)
[ -n "$GPEER" ] || die "no peerId in peerInfo: ${PEERINFO:-<empty>}"
GADDR="/ip4/127.0.0.1/tcp/$GIFTER_PORT"
say "gifter peer: $GPEER @ $GADDR"
# Open gifter: NO authVerifiers — any commitment gets a membership, paid by
# the account `wallet` names (the gifter node's own funded payer, which the
# gifter forwards as register_member's payer).
SERVE=$(node_call n2 rln_gifter_module serve \
    "{\"config\":\"$E2E_CONFIG_ACCOUNT\",\"wallet\":\"$GPAYER\"}" | jres) || SERVE=""
case "$SERVE" in
    *error*) die "gifter serve failed: $SERVE" ;;
    '') die "gifter serve failed: <empty>" ;;
    *) say "gifter serving (open): $SERVE" ;;
esac

# ---------- n1: verifier + chat peer B ---------------------------------------
section "n1: logoscore daemon (verifier + chat peer B)"
V_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 1 ))" "")
# n1 reads chain state and validates; it must never be able to pay for
# anything, so it gets a wallet of its own rather than the deployment's
# shared payer.
daemon_self_paying n1 "$E2E_RUN_DIR/wallet-n1"
E2E_DAEMON_ENV="CHAT_DELIVERY_CONF_OVERRIDE=$V_CONF $(delivery_rln_presets_env "$RLN_PRESETS_FILE")" daemon_start n1 \
    || die "daemon_start n1 failed"
NODES_UP="n1 n2"
daemon_load_modules n1 liblogos_lez_rln_module liblogos_rln_module \
    delivery_module chat_module || die "n1: load-module failed"
# n1 reads chain state only (roots, membership) — its own home, never funded.
wallet_open n1 || die "n1: wallet open failed"
wallet_sync n1 >/dev/null || die "n1: wallet sync failed"
# `"provision": false`: n1 is the verifier and holds no membership by design.
# Since liblogos_rln_module 0.8.0 `start` would otherwise park a provisioning
# task on its deliberately unfunded payer for fifteen minutes.
PREWARM=$(node_call n1 liblogos_rln_module start \
    "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"],\"provision\":false}" | jres | jval) || PREWARM=""
case "$PREWARM" in
    *'"started":true'*) say "n1: rln module pre-warmed" ;;
    *) die "n1: rln module start (pre-warm) failed: ${PREWARM:-<empty>}" ;;
esac
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

# ---------- basecamp: fresh (fundless) wallet, delegated options --------------
section "basecamp up (headless; fresh never-funded wallet)"
BHOME="$E2E_RUN_DIR/wallet-basecamp"
# Config only, no storage and no seed. Derivation is deterministic from the
# seed, so a home carrying the staged one derives the STAGED accounts — which
# is how "basecamp cannot pay for itself" used to rest on nothing but the
# gifter having derived a different account.
basecamp_wallet_home "$BHOME"
BC_CONF=$(chat_delivery_cfg "$(( BASE_PORT + 2 ))" "$N1_MADDR")
basecamp_launch "$UD" "$BHOME" "$BC_CONF" \
    "$(delivery_rln_presets_env "$RLN_PRESETS_FILE")"

section "basecamp: load the module stack (gifter client half before the RLN module)"
basecamp_load_modules liblogos_lez_rln_module libp2p_module rln_gifter_module \
    liblogos_rln_module delivery_module chat_module

section "basecamp wallet (open + sync, read-only use)"
basecamp_wallet_open_sync "$BHOME"
# basecamp must not be able to pay for itself. Payer derivation is
# deterministic, so two wallets that started from the same material land on
# the same account — and then "the gifter paid" would be unfalsifiable. The
# homes above are built to avoid that; assert it rather than trust it.
BC_PAYER=$(basecamp_payer) || die "basecamp: no payer"
[ "$BC_PAYER" != "$GPAYER" ] \
    || die "basecamp's payer IS the gifter's funded account ($GPAYER) — this run could not tell a delegated registration from a self-funded one"
say "basecamp payer: $BC_PAYER (not the gifter's $GPAYER)"

# "Fundless" is an invariant, not a hope. The account basecamp would pay from
# holds nothing before the delegated registration and must hold nothing after
# — read off the chain through n2, whose wallet can read any public account.
# "" is "could not ask", NOT zero, and fails rather than passing quietly.
bc_payer_balance() { wallet_native_balance n2 "$BC_PAYER"; }
BCBAL0=$(bc_payer_balance)
case "$BCBAL0" in ''|*[!0-9]*) die "cannot read basecamp's native balance: '${BCBAL0:-<empty>}'" ;; esac
[ "$BCBAL0" = 0 ] \
    || die "basecamp's payer $BC_PAYER already holds $BCBAL0 native — it could have paid for itself, and 'the gifter paid' would be unfalsifiable"
say "basecamp payer $BC_PAYER holds $BCBAL0 native — it cannot pay for anything"

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
BINIT=$(bc_call chat_module init '[""]') || BINIT=""
case "$BINIT" in
    *'"success":true'*) say "basecamp: chat init accepted (conf via CHAT_DELIVERY_CONF_OVERRIDE; the delegated options are NOT in it — see the registration section)" ;;
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

# ---------- registration asserts (the gifter pays) ---------------------------
# The delegated options used to ride the delivery conf as
# rln-relay-registry-options, and chat's bootstrap folded them into the
# registration. Upstream has no such key any more and the preset takes only
# registry-id / rln-identifier / epoch-size-sec (delivery_module_plugin.cpp:964),
# so there is no path from a delivery conf to the allocation protocol at all.
#
# What the protocol needs is unchanged — liblogos_rln_module reads
# "delegated"/"gifter_peer_id"/"gifter_multiaddr" straight off RegistryOptions
# (lib.rs:363) — so the scenario asks for it directly. What is lost is only the
# attribution: this no longer proves chat's boot can request a gifted
# membership, because on today's surface it cannot. Everything the allocation
# protocol itself claims is still proven below: the gifter pays, basecamp's own
# payer is never funded and never moves, and the membership is real on chain.
section "delegated registration (asked for directly; chat's conf can no longer carry it)"
DELEGATED_OPTS=$(jq -cn --arg r "$RATE_LIMIT" --arg p "$GPEER" --arg m "$GADDR" \
    '[{key:"rate_limit",value:$r},{key:"delegated",value:"true"},{key:"gifter_peer_id",value:$p},{key:"gifter_multiaddr",value:$m}]')
DREG=$(bc_call liblogos_rln_module register_membership \
    "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" --arg o "$DELEGATED_OPTS" '[$r,$i,$o]')") || DREG=""
case "$DREG" in
    *'"state":"pending"'*|*'"state":"active"'*) say "basecamp: delegated register_membership accepted" ;;
    *) die "basecamp: delegated register_membership failed: ${DREG:-<empty>}" ;;
esac
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

# Chain oracle: n1 first (the idle verifier), n2 as fallback. Either node's
# liblogos_lez_rln_module can be freshly WEDGED — the module is
# single-threaded and one blocked handler (n2: the gifter's own
# register_member sits in it right now; n1: a roots refresh against a busy
# wallet) starves every later call until the process is killed — so never
# bet the whole budget on one reader.
_CONFIRM_SAVED="$E2E_CONFIRM_TIMEOUT_S"
E2E_CONFIRM_TIMEOUT_S=300
ORACLE=n1
if ! confirm_and_ready n1 "$IDC" "" basecamp; then
    say "n1 oracle inconclusive within 300s — retrying via n2 (the payer)"
    ORACLE=n2
    confirm_and_ready n2 "$IDC" "" basecamp || {
        E2E_CONFIRM_TIMEOUT_S="$_CONFIRM_SAVED"
        die "registry never confirmed basecamp's membership (registered:true) via n1 OR n2"
    }
fi
E2E_CONFIRM_TIMEOUT_S="$_CONFIRM_SAVED"
say "on-chain: registered:true at leaf $E2E_ACTUAL_LEAF"

# Who paid: the gifter's native balance dropped; basecamp's wallet is
# untouched. The drop is at LEAST the registry price — one account now pays
# the price and the transaction's fee out of the same asset, so the exact
# figure is price + fee and only the floor is assertable.
GBAL1=$(wallet_native_balance n2 "$GPAYER")
case "$GBAL1" in ''|*[!0-9]*) die "cannot read the gifter's balance after registration: '${GBAL1:-<empty>}'" ;; esac
[ "$GBAL1" -lt "$GBAL0" ] \
    || die "the gifter's balance did not drop ($GBAL0 -> $GBAL1) — who paid for leaf $E2E_ACTUAL_LEAF?"
PAID=$(( GBAL0 - GBAL1 ))
EXPECTED=$(( RATE_LIMIT * PRICE ))
[ "$PAID" -ge "$EXPECTED" ] \
    || die "the gifter paid $PAID native, less than the registry price $EXPECTED (rate $RATE_LIMIT × price $PRICE) — leaf $E2E_ACTUAL_LEAF was not paid for out of this account"
say "gifter paid $PAID native = price $EXPECTED (rate $RATE_LIMIT × price $PRICE) + fee $(( PAID - EXPECTED ))"
BCBAL1=$(bc_payer_balance)
case "$BCBAL1" in ''|*[!0-9]*) die "cannot read basecamp's balance after registration: '${BCBAL1:-<empty>}'" ;; esac
[ "$BCBAL1" = "$BCBAL0" ] \
    || die "basecamp's payer moved across a delegated registration ($BCBAL0 -> $BCBAL1) — it should have paid nothing"
say "basecamp payer still holds $BCBAL1 native — it paid nothing"

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
echo "e2e:   service   n2 = logoscore + libp2p_module + rln_gifter_module (open gifter paying from its funded payer $GPAYER)"
echo "e2e:   product   chat_module -> delivery_module -> RLN module -> gifter client -> libp2p -> the service, all INSIDE Basecamp"
echo "e2e:   config    scope via the RLN preset; delegated options {delegated:true, gifter_peer_id, gifter_multiaddr} via register_membership — no delivery conf carries them any more"
echo "e2e:   register  delegated, asked for directly: state=$STATE, on-chain registered:true at leaf $E2E_ACTUAL_LEAF (oracle: $ORACLE)"
echo "e2e:   payer     the gifter paid $PAID native from $GPAYER; basecamp's own payer ($BC_PAYER) is a different account and still holds $BCBAL1"
echo "e2e:   message   basecamp send_message -> proof attached -> gossipsub -> n1 validate -> chat message_received (attempt $ATTEMPT/$SEND_ATTEMPTS)"
