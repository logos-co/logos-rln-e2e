#!/usr/bin/env bash
# scenarios/delivery-rln-gifter — RLN membership by allocation (delegated
# registration), then one proof-gated delivery message. chat-basecamp-gifter
# without chat and Basecamp: the same allocation protocol, driven from a plain
# delivery node.
#
# Topology:
#   g    the allocation service: liblogos_lez_rln_module + liblogos_rln_module
#        + libp2p_module + rln_gifter_module, its own payer funded with native
#        balance, `rln_gifter_module.serve` with no authVerifiers (an open
#        gifter). The gifter names that payer as register_member's payer, so g
#        signs the Register, pays the price and pays the fee.
#   n1   the sender: the RLN stack + delivery_module, plus libp2p_module and
#        rln_gifter_module (the client half the RLN module dials the gifter
#        through). Its wallet is created fresh and never funded.
#   n2   the receiver: the RLN stack + delivery_module, never funded, no
#        membership. It validates what arrives.
#
# What it proves:
#   1. delegated registration end to end: register_membership with
#      {delegated, gifter_peer_id, gifter_multiaddr} -> RLN module -> gifter
#      client -> libp2p -> the service -> register_member on the gifter's
#      payer; the membership goes active and the registry confirms it.
#   2. who paid: n1's payer holds 0 before and after; the gifter's balance
#      drops by at least the registry price (rate_limit x price_per_unit),
#      plus the fee.
#   3. the leaves agree with the chain: the one n1's RLN module reports, and
#      the one the gifter itself answers a request with (a second gift asked
#      for directly, since the RLN module re-reads the chain and would hide a
#      wrong answer).
#   4. the gifted membership is usable: n1's send carries a proof, and n2
#      receives the message.
#
# Required:
#   LIBP2P_LGX or LIBP2P_MODULE_CHECKOUT   libp2p_module (upstream master has
#                                          mountProtocol/protocolRequest; the
#                                          delivery flake exports it as
#                                          libp2p_module-lgx)
#   GIFTER_LGX or GIFTER_CHECKOUT          logos-rln-gifter with
#                                          fix/register-target-lez-rln-module
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100          the gifted membership's rate limit
#   E2E_GIFTER_RLN_PORT=62100   tcp ports: +1 n1, +2 n2, +10 the gifter's libp2p,
#                               +11 n1's libp2p
#   E2E_EVENT_TIMEOUT_S=30      per-event wait budget
#   E2E_MESH_WAIT_S=12          gossipsub mesh stabilization pause
#   E2E_RECV_WAIT_S=30          how long n2 is given to show the message
#   E2E_REG_WAIT_S=600          budget for the delegated membership to go active
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
BASE_PORT="${E2E_GIFTER_RLN_PORT:-62100}"
GIFTER_PORT=$(( BASE_PORT + 10 ))
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-30}"
REG_WAIT_S="${E2E_REG_WAIT_S:-600}"
TOPIC="/logos-rln-e2e/1/delivery-rln-gifter/proto"
CLUSTER_ID="198"
NODES_ALL="g n1 n2"

cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving nodes up, state in $E2E_RUN_DIR"
        return
    fi
    daemon_stop_all
}
trap cleanup EXIT

REGISTRY_ID=$(delivery_registry_id)
RLN_ID=$(delivery_rln_identifier)
say "registry $REGISTRY_ID; rln identifier $RLN_ID"
RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC"
E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} $(delivery_rln_presets_env "$RLN_PRESETS_FILE")"
export E2E_DAEMON_ENV

# ---------- daemons ------------------------------------------------------------
# Every node gets a wallet of its own: a fresh home with only the staged config,
# so each module derives a payer nothing else holds. Only g's is ever funded.
section "daemons"
for n in $NODES_ALL; do
    daemon_self_paying "$n" "$E2E_RUN_DIR/wallet-$n"
    daemon_start "$n" || die "daemon_start $n failed"
done
daemon_load_modules g liblogos_lez_rln_module liblogos_rln_module \
    libp2p_module rln_gifter_module || die "g: load-module failed"
daemon_load_modules n1 liblogos_lez_rln_module liblogos_rln_module \
    libp2p_module rln_gifter_module delivery_module || die "n1: load-module failed"
daemon_load_modules n2 liblogos_lez_rln_module liblogos_rln_module \
    delivery_module || die "n2: load-module failed"
for n in $NODES_ALL; do
    wallet_open "$n" || die "$n: wallet open failed"
    wallet_sync "$n" >/dev/null || die "$n: wallet sync failed"
done

# ---------- the allocation service (g) ------------------------------------------
section "allocation service (g)"
BOUNDS=$(node_call g liblogos_lez_rln_module get_registry_bounds \
    "$(argfile gcfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in the registry bounds: ${BOUNDS:-<empty>}"
GPAYER=$(wallet_payer g) || die "g published no payer"
wallet_fund g >/dev/null || die "funding the gifter's payer $GPAYER never landed"
GBAL0=$(wallet_native_balance g "$GPAYER")
case "$GBAL0" in ''|*[!0-9]*) die "cannot read the gifter's balance: '${GBAL0:-<empty>}'" ;; esac
say "gifter payer $GPAYER holds $GBAL0 native; registry price $PRICE per unit"

node_call g libp2p_module createNode "{\"addrs\":[\"/ip4/127.0.0.1/tcp/$GIFTER_PORT\"]}" | jres >/dev/null \
    || die "g: libp2p createNode failed"
node_call g libp2p_module start | jres >/dev/null || die "g: libp2p start failed"
GPEER=$(node_call g libp2p_module peerInfo | jres | jval | jfield peerId) || GPEER=""
[ -n "$GPEER" ] || die "g: no peerId from libp2p peerInfo"
GADDR="/ip4/127.0.0.1/tcp/$GIFTER_PORT"
say "gifter peer $GPEER @ $GADDR"
SERVE=$(node_call g rln_gifter_module serve \
    "{\"config\":\"$E2E_CONFIG_ACCOUNT\",\"wallet\":\"$GPAYER\"}" | jres) || SERVE=""
case "$SERVE" in
    ''|*error*) die "gifter serve failed: ${SERVE:-<empty>}" ;;
    *) say "gifter serving (open): $SERVE" ;;
esac

# ---------- n1, n2: never funded ----------------------------------------------------
section "n1, n2: fresh wallets, never funded"
N1PAYER=$(wallet_payer n1) || die "n1 published no payer"
[ "$N1PAYER" != "$GPAYER" ] || die "n1's payer is the gifter's ($GPAYER) — its wallet is not its own"
N1BAL0=$(wallet_native_balance n1 "$N1PAYER")
[ "$N1BAL0" = "0" ] || die "n1's payer $N1PAYER should start empty, holds '${N1BAL0:-<empty>}'"
say "n1 payer $N1PAYER holds 0 native"
# provision:false: neither node may self-provision. n1's membership comes from
# the gifter; n2 only receives. Without it, `start` would park a provisioning
# task on each empty payer.
for n in n1 n2; do
    PREWARM=$(node_call "$n" liblogos_rln_module start \
        "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"],\"provision\":false}" \
        | jres | jval) || PREWARM=""
    case "$PREWARM" in
        *'"started":true'*) say "$n: rln module started (provision off)" ;;
        *) die "$n: rln module start failed: ${PREWARM:-<empty>}" ;;
    esac
done

# ---------- delegated registration ----------------------------------------------------
section "delegated registration (n1 asks, the gifter pays)"
# The gifter client dials the service through n1's OWN libp2p node
# (protocolRequest), so that node has to be up first.
node_call n1 libp2p_module createNode "{\"addrs\":[\"/ip4/127.0.0.1/tcp/$(( BASE_PORT + 11 ))\"]}" | jres >/dev/null \
    || die "n1: libp2p createNode failed"
node_call n1 libp2p_module start | jres >/dev/null || die "n1: libp2p start failed"
say "n1: libp2p up on 127.0.0.1:$(( BASE_PORT + 11 ))"
OPTS=$(jq -cn --arg r "$RATE_LIMIT" --arg p "$GPEER" --arg m "$GADDR" \
    '[{key:"rate_limit",value:$r},{key:"delegated",value:"true"},{key:"gifter_peer_id",value:$p},{key:"gifter_multiaddr",value:$m}]')
DREG=$(node_call n1 liblogos_rln_module register_membership "$REGISTRY_ID" \
    "$(argfile rid "$RLN_ID")" "$OPTS" | jres) || DREG=""
case "$DREG" in
    *'"state":"pending"'*|*'"state":"active"'*) say "n1: delegated register_membership accepted" ;;
    *) die_node n1 "delegated register_membership failed: ${DREG:-<empty>}" ;;
esac
STATE=""
MS=""
for _t in $(seq 1 "$(polls "$REG_WAIT_S" "$E2E_POLL_INTERVAL_S")"); do
    MS=$(node_call n1 liblogos_rln_module get_membership_state "$REGISTRY_ID" \
        "$(argfile st "$RLN_ID")" | jres) || MS=""
    STATE=$(printf '%s' "$MS" | jfield state)
    say "  n1 poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed)
            MEMS=$(node_call n1 liblogos_rln_module get_memberships "$REGISTRY_ID" | jres) || MEMS=""
            die_node n1 "delegated registration FAILED: $(printf '%s' "$MEMS" \
                | jq -c '[.memberships[] | {state, failed_reason}]' 2>/dev/null || printf '%s' "$MS")" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
case "$STATE" in
    active|grace_period) ;;
    *) die_node n1 "the gifted membership never went active within ${REG_WAIT_S}s (last: ${STATE:-<none>} — $MS)" ;;
esac
say "n1: gifted membership $STATE at leaf $(printf '%s' "$MS" | jfield leaf_index)"

MEMS=$(node_call n1 liblogos_rln_module get_memberships "$REGISTRY_ID" | jres) || MEMS=""
IDC=$(printf '%s' "$MEMS" | jq -r '.memberships[0].credential.identity_commitment' 2>/dev/null) || IDC=""
[ -n "$IDC" ] && [ "$IDC" != "null" ] || die "cannot read n1's identity commitment: ${MEMS:-<empty>}"
confirm_and_ready n2 "$IDC" "" n1 || die "the registry never confirmed n1's commitment ${IDC:0:18}… (read via n2)"
say "on chain: registered at leaf $E2E_ACTUAL_LEAF (read via n2)"
MLEAF=$(printf '%s' "$MS" | jfield leaf_index)
[ "$MLEAF" = "$E2E_ACTUAL_LEAF" ] \
    || die_node n1 "n1's RLN module reports leaf ${MLEAF:-<none>}, the registry holds $E2E_ACTUAL_LEAF"

# ---------- who paid ------------------------------------------------------------------
section "who paid"
GBAL1=$(wallet_native_balance g "$GPAYER")
case "$GBAL1" in ''|*[!0-9]*) die "cannot read the gifter's balance after: '${GBAL1:-<empty>}'" ;; esac
PAID=$(( GBAL0 - GBAL1 ))
EXPECTED=$(( RATE_LIMIT * PRICE ))
[ "$PAID" -ge "$EXPECTED" ] \
    || die "the gifter paid $PAID native, less than the registry price $EXPECTED (rate $RATE_LIMIT x price $PRICE)"
say "gifter paid $PAID native = price $EXPECTED + fee $(( PAID - EXPECTED ))"
N1BAL1=$(wallet_native_balance n1 "$N1PAYER")
[ "$N1BAL1" = "0" ] || die "n1's payer moved across a delegated registration (0 -> ${N1BAL1:-<empty>})"
say "n1 payer still holds 0 native — it paid nothing"

# ---------- the gifter's own answer -------------------------------------------------------
# Asked for directly through n1's gifter client, for a fixed commitment no one
# holds the secret of: the leaf in the reply must be the chain's.
section "the gifter's answer is the chain's leaf"
GIDC="000000000000000000000000000000000000000000000000000000000000002a"
GREPLY=$(node_call n1 rln_gifter_module request "$(jq -cn --arg p "$GPEER" --arg m "$GADDR" --arg i "$GIDC" \
    --argjson r "$RATE_LIMIT" '{gifterPeerId:$p, gifterMultiaddr:$m, identityCommitment:$i, rate:$r}')" | jres) || GREPLY=""
GLEAF=$(printf '%s' "$GREPLY" | jfield leaf_index)
[ -n "$GLEAF" ] || die_node g "gifter request for ${GIDC:0:8}… returned no leaf: ${GREPLY:-<empty>}"
GMEM=$(node_call n2 liblogos_lez_rln_module get_membership "$(argfile gm_cfg "$E2E_CONFIG_ACCOUNT")" \
    "$(argfile gm_idc "$GIDC")" | jres) || GMEM=""
CLEAF=$(printf '%s' "$GMEM" | jfield leaf_index)
[ "$(printf '%s' "$GMEM" | jq -r '.registered' 2>/dev/null)" = "true" ] \
    || die "the gifter answered leaf $GLEAF, but the registry has no membership for ${GIDC:0:8}…: $GMEM"
[ "$GLEAF" = "$CLEAF" ] || die_node g "the gifter answered leaf $GLEAF, the registry holds $CLEAF"
say "gifter answered leaf $GLEAF for a direct request; the registry holds $CLEAF"

# ---------- the message ---------------------------------------------------------------
section "delivery: n1 -> n2 on the gifted membership"
for n in n1 n2; do
    node_watch_start "$n" delivery_module
done
delivery_node_up n2 "$(( BASE_PORT + 2 ))" "$CLUSTER_ID" "" "$EVT_TIMEOUT"
delivery_node_up n1 "$(( BASE_PORT + 1 ))" "$CLUSTER_ID" "$(gv MADDR n2)" "$EVT_TIMEOUT"
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
for n in n1 n2; do
    delivery_must_call "$n" subscribe "subscribe" "$TOPIC" >/dev/null
done
delivery_wait_roots_warm n2 "$REGISTRY_ID"

REQID=$(delivery_must_call n1 send "send" "$TOPIC" "$(argfile payload "sent on a gifted membership")")
[ -n "$REQID" ] || die_node n1 "send returned no requestId"
GEN=$(node_wait_event n1 delivery_module "$(delivery_rln_evt rlnGenerateProofRequest)" "$EVT_TIMEOUT") || GEN=""
[ -n "$GEN" ] || die_node n1 "no generate-proof request within ${EVT_TIMEOUT}s — the send carried no RLN proof"
PROP=$(node_wait_event n1 delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") || PROP=""
if [ -z "$PROP" ]; then
    ERR=$(node_wait_event n1 delivery_module messageError 1 "$REQID") || ERR=""
    die_node n1 "no messagePropagated for $REQID within ${EVT_TIMEOUT}s${ERR:+: $ERR}"
fi
MSG_HASH=$(printf '%s' "$PROP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("arg1",""))') || MSG_HASH=""
say "n1: proof generated, propagated (hash ${MSG_HASH:-<unread>})"
node_wait_event n2 delivery_module messageReceived "$RECV_WAIT_S" "$MSG_HASH" >/dev/null \
    || die_node n2 "n2 did not receive $MSG_HASH within ${RECV_WAIT_S}s"
say "n2 received it"

say "PASS — delivery-rln-gifter (target $E2E_TARGET): a never-funded node got its membership from the gifter \
(paid $PAID by $GPAYER) and sent a proof-gated message on it"
