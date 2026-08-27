#!/usr/bin/env bash
# scenarios/delivery-rln — end-to-end acceptance for logos-delivery's RLN
# integration (branch impl-plugable-rln-api-module + the rln/integration-fixes
# stack on BOTH logos-delivery and logos-delivery-module) against the REAL
# RLN module stack.
#
# The seam under test is event-out/respond-in: liblogosdelivery's rlnInvoke
# fires a C callback into delivery_module, which re-emits it as an
# rln*Request logos event; whoever handles it answers via
# delivery_module.rlnRespond(reqId, resultJson). THIS SCRIPT runs a
# background responder per node, bridging every request to
# liblogos_rln_module and feeding the real reply back.
#
# What it proves:
#   1. co-residency: the RLN stack + the RLN-enabled delivery_module load in
#      one daemon, on both nodes.
#   2. bring-up via the REAL config surface: rln-relay-lez /
#      rln-relay-registry-id / rln-relay-identifier /
#      rln-relay-user-message-limit ride createNode's flat conf (the
#      env-injection fork is retired), and the rlnRegisterRequest that
#      crosses is asserted byte-exact against what we configured.
#   3. keystore custody default: NO unlock call anywhere — the module
#      self-provisions its own secret (the headless deployment shape;
#      contract: docs/delivery-integration.md §1).
#   4. registration is REAL on n1 (pending -> active on the target chain),
#      answered inside the library's hard 10s rlnInvoke windows. n2's
#      register is answered with an err ON PURPOSE: a failed best-effort
#      registration must degrade (the node still starts, relays and
#      validates) instead of failing bring-up.
#   5. the message path, end to end: n1 send -> rlnGenerateProofRequest ->
#      module generate_proof (its proof_canonical bytes become
#      message.proof) -> gossipsub -> n2's validator ->
#      rlnVerifyProofRequest -> module validate_proof -> the lowercase
#      "valid" verdict crosses verbatim -> messageReceived on n2. A
#      fresh-root "invalid" on an early attempt is tolerated: the module
#      nudges its root window and a later send passes — the send leg
#      retries with fresh messages (each attempt spends a real slot).
#
# Required checkouts (the integration branches have no flake pins):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ rln/integration-fixes
#                             (validate_proof struct field + verdict docs)
#   LOGOS_DELIVERY_CHECKOUT   logos-delivery @ rln/integration-fixes
#                             (a48f8b8a + rln/api types + verdict parsing +
#                             errors->Ignore + the prover leg); submodules
#                             checked out
#   RLN_MODULES_CHECKOUT      logos-rln-modules with the 0.6.1 stack
#                             (proof_canonical on generate_proof replies)
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100            registration rate limit (also the
#                                 library's rln-relay-user-message-limit)
#   E2E_DELIVERY_RLN_PORT=61880   tcp ports are PORT+1, PORT+2
#   E2E_EVENT_TIMEOUT_S=30        per-event wait budget
#   E2E_MESH_WAIT_S=12            gossipsub mesh stabilization pause
#   E2E_SEND_ATTEMPTS=3           send-leg attempts (fresh-root window)
#   E2E_RECV_WAIT_S=12            per-attempt receive wait on n2
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
BASE_PORT="${E2E_DELIVERY_RLN_PORT:-61880}"
EVT_TIMEOUT="${E2E_EVENT_TIMEOUT_S:-30}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-12}"
TOPIC="/logos-rln-e2e/1/delivery-rln/proto"
CLUSTER_ID="198"
NODES_ALL="n1 n2"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — the responder pays the registration from a faucet claim; pick a faucet deployment"
# Without the delivery override this runs against pinned delivery master,
# which has no RLN seam — fail with the pointer instead of a confusing hang.
[ -n "${DELIVERY_LGX:-}" ] || [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ] \
    || die "delivery-rln needs the integration branches: set DELIVERY_MODULE_CHECKOUT + LOGOS_DELIVERY_CHECKOUT (rln/integration-fixes) or a prebuilt DELIVERY_LGX"

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODES_UP=0
DYING=0
RESPONDER_PIDS=""
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ "$NODES_UP" = 1 ]; then
        DYING=1
        local n
        for n in $NODES_ALL; do
            echo "---- $n log tail ----" >&2
            node_logs "$n" 30 >&2 || true
            if [ -s "$E2E_RUN_DIR/responder-$n.log" ]; then
                echo "---- $n responder tail ----" >&2
                tail -15 "$E2E_RUN_DIR/responder-$n.log" >&2 || true
            fi
        done
    fi
    exit 1
}
cleanup() {
    local p
    for p in $RESPONDER_PIDS; do kill "$p" 2>/dev/null; done
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving nodes up, state in $E2E_RUN_DIR"
        return
    fi
    [ "$NODES_UP" = 1 ] && daemon_stop_all
}
trap cleanup EXIT

# call delivery_module on a node + insist on StdLogosResult success; prints
# the value.
must_call() {
    local node="$1" method="$2" label="$3"; shift 3
    local res
    res=$(node_call "$node" delivery_module "$method" "$@" | jres) || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" | jval ;;
        *) die "$node: $label failed: ${res:-<empty>}" ;;
    esac
}

# arg<N> of a compact event JSON line.
evt_arg() {
    printf '%s' "$1" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["data"].get("arg"+sys.argv[1],""))' "$2"
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
say "registry: $REGISTRY_ID (bring-up scope, rate $RATE_LIMIT)"

# ---------- the responder (one background loop per node) ---------------------
# Bridges every rln*Request the delivery module emits to liblogos_rln_module
# and answers with the reply envelope every responder must speak
# (delivery-module docs/rln.md): {"ok": <module reply>} |
# {"err":{"kind","message"}}. Verdicts/statuses inside ok are the module's
# lowercase wire verbatim; envelope kinds are the seam's UPPER_SNAKE.
# reqId values >= 2^63 print negative — echoed back unchanged.

b64d() { printf '%s' "$1" | base64 -d; }

# Map a module error reply onto the seam's envelope err (THE kind mapping a
# production router owes the seam): not_ready/budget_exhausted pass through
# uppercased, permanent+invalid_argument are PERMANENT, the rest TRANSIENT.
seam_err_from_module() {
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    kind = json.load(sys.stdin).get("kind", "")
except Exception:
    kind = ""
seam = {"not_ready": "NOT_READY", "budget_exhausted": "BUDGET_EXHAUSTED",
        "permanent": "PERMANENT", "invalid_argument": "PERMANENT"}.get(kind, "TRANSIENT")
print(json.dumps({"err": {"kind": seam, "message": "module: " + (kind or "no reply")}},
                 separators=(",", ":")))' 2>/dev/null \
        || printf '{"err":{"kind":"TRANSIENT","message":"module: no reply"}}'
}

rln_respond() {
    local node="$1" req="$2" payload="$3" note="$4" res
    res=$(node_call "$node" delivery_module rlnRespond "$req" \
        "$(argfile "rsp_${node}_${RANDOM}" "$payload")" | jres) || res=""
    case "$res" in
        *'"success":true'*) echo "responder[$node]: reqId=$req $note" ;;
        *) echo "responder[$node]: reqId=$req rlnRespond FAILED ($note): ${res:-<empty>}" ;;
    esac
}

answer_event() {
    local node="$1" line="$2"
    local ev a0 a1 a2 a3 a4 a5 _rest req
    IFS='|' read -r ev a0 a1 a2 a3 a4 a5 _rest <<<"$line"
    req=$(b64d "$a0")
    case "$ev" in
    rlnStartRequest)
        local res
        res=$(node_call "$node" liblogos_rln_module start \
            "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" \
            | jres | jval) || res=""
        case "$res" in
            *'"started":true'*) rln_respond "$node" "$req" "{\"ok\":$res}" "start ok" ;;
            *) rln_respond "$node" "$req" "$(seam_err_from_module "$res")" \
                "start ERR: ${res:-<empty>}" ;;
        esac ;;
    rlnRegisterRequest)
        if [ "$node" = "n1" ]; then
            # The event's LIP RegistryOptions array IS the module wire — pass
            # it through verbatim, appending only the funding pair the seam
            # has no field for.
            local opts reg
            opts=$(b64d "$a3" | python3 -c '
import json, sys
o = json.load(sys.stdin)
o.append({"key": "funding_holding_account_id", "value": sys.argv[1]})
print(json.dumps(o, separators=(",", ":")))' "$HOLDING") || opts=""
            reg=$(node_call "$node" liblogos_rln_module register \
                "$(b64d "$a1")" "$(argfile "rr_${node}_${RANDOM}" "$(b64d "$a2")")" \
                "$opts" | jres) || reg=""
            case "$reg" in
                *'"state":"pending"'*)
                    rln_respond "$node" "$req" "{\"ok\":$reg}" \
                        "register ok (pending $(printf '%s' "$reg" | jfield membership_hash))" ;;
                *) rln_respond "$node" "$req" "$(seam_err_from_module "$reg")" \
                    "register ERR: ${reg:-<empty>}" ;;
            esac
        else
            # Deliberate: the validator node keeps no membership. A failed
            # best-effort registration must degrade, not break bring-up —
            # asserted later via n2's own notice log + working validate.
            rln_respond "$node" "$req" \
                '{"err":{"kind":"TRANSIENT","message":"e2e: validator node registers nothing (deliberate)"}}' \
                "register deliberately refused (degradation probe)"
        fi ;;
    rlnGenerateProofRequest)
        # (reqId, registryId, rlnIdentifier, signalHex, epochTimestamp)
        local out
        out=$(node_call "$node" liblogos_rln_module generate_proof \
            "$(b64d "$a1")" "$(argfile "gp_${node}_${RANDOM}" "$(b64d "$a2")")" \
            "$(argfile "gs_${node}_${RANDOM}" "$(b64d "$a3")")" \
            "str:$(b64d "$a4")" | jres | jval) || out=""
        case "$out" in
            *'"proof_canonical"'*)
                rln_respond "$node" "$req" "{\"ok\":$out}" \
                    "generate ok (slot $(printf '%s' "$out" | jfield message_id))" ;;
            *) rln_respond "$node" "$req" "$(seam_err_from_module "$out")" \
                "generate ERR: ${out:-<empty>}" ;;
        esac ;;
    rlnVerifyProofRequest)
        # (reqId, registryId, rlnIdentifier, signalHex, epochTimestamp,
        #  proofJson) — still Verify-named on the event surface; the module
        # method is validate_proof (THE mapping).
        local out verdict
        out=$(node_call "$node" liblogos_rln_module validate_proof \
            "$(b64d "$a1")" "$(argfile "vp_${node}_${RANDOM}" "$(b64d "$a2")")" \
            "$(argfile "vs_${node}_${RANDOM}" "$(b64d "$a3")")" \
            "str:$(b64d "$a4")" \
            "$(argfile "vj_${node}_${RANDOM}" "$(b64d "$a5")")" | jres | jval) || out=""
        case "$out" in
            *'"verdict"'*)
                verdict=$(printf '%s' "$out" | jfield verdict)
                rln_respond "$node" "$req" "{\"ok\":$out}" "verify verdict=$verdict" ;;
            *) rln_respond "$node" "$req" "$(seam_err_from_module "$out")" \
                "verify ERR: ${out:-<empty>}" ;;
        esac ;;
    *)
        echo "responder[$node]: ignoring $ev (reqId $req)" ;;
    esac
}

responder_loop() {
    local node="$1" evt cursor batch line
    evt=$(gv NODEEVT "${node}_delivery_module")
    cursor="$E2E_RUN_DIR/responder-$node.cursor"
    : >"$cursor"
    while :; do
        batch=$(python3 - "$evt" "$cursor" <<'EOF'
import base64, json, sys
path, cur = sys.argv[1], sys.argv[2]
try:
    seen = int(open(cur).read().strip() or "0")
except Exception:
    seen = 0
try:
    text = open(path).read()
except OSError:
    sys.exit(0)
# Only consume newline-terminated lines: the watcher appends live and the
# last line may be mid-write.
if text and not text.endswith("\n"):
    text = text[: text.rfind("\n") + 1]
lines = text.splitlines()
out = []
for i, line in enumerate(lines):
    if i < seen or not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    ev = d.get("event", "")
    if not (ev.startswith("rln") and ev.endswith("Request")):
        continue
    a = d.get("data", {})
    args = [str(a.get("arg%d" % k, "")) for k in range(7)]
    out.append("|".join([ev] + [base64.b64encode(s.encode()).decode() for s in args]))
open(cur, "w").write(str(len(lines)))
if out:
    print("\n".join(out))
EOF
        ) || batch=""
        if [ -n "$batch" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                answer_event "$node" "$line" >>"$E2E_RUN_DIR/responder-$node.log" 2>&1
            done <<<"$batch"
        fi
        sleep 0.5
    done
}

# ---------- daemons ----------------------------------------------------------
# E2E_DAEMON_ENV is NOT touched here: the RLN module runs its default
# module-owned keystore custody (self-provisioned secret, zero unlock calls)
# — exactly the headless shape the delivery integration deploys.
section "daemons: RLN stack + delivery_module on both nodes"
for n in $NODES_ALL; do
    daemon_start "$n" || die "daemon_start $n failed"
    daemon_load_modules "$n" lez_core liblogos_lez_rln_module liblogos_rln_module \
        delivery_module || die "$n: load-module failed"
done
NODES_UP=1
say "co-residency: all 4 modules loaded on both nodes (keystore: module-owned custody, no unlock call)"

# ---------- wallets (n1 pays; n2 only reads) ---------------------------------
# BOTH nodes need an open wallet: the RLN module's registry reads (root
# window refresh, membership state) go through liblogos_lez_rln_module,
# whose account fetches need lez_core's wallet open — a validator-only node
# without one has a permanently cold root window. Only n1 funds anything.
section "wallets"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "syncing wallets to chain head $CHAIN_HEAD"
for n in $NODES_ALL; do
    if [ "$n" = "n1" ]; then
        wallet_open n1 || die "n1: wallet open failed"
    else
        # Each daemon gets its own storage.json — two lez_core processes
        # must never share one mutable wallet file.
        cp -R "$E2E_WALLET_HOME" "$E2E_RUN_DIR/wallet-$n" \
            || die "$n: cannot copy wallet home"
        rm -f "$E2E_RUN_DIR/wallet-$n/storage.json"
        wallet_open "$n" "$E2E_RUN_DIR/wallet-$n" || die "$n: wallet open failed"
    fi
    wallet_sync "$n" >/dev/null || die "$n: wallet sync failed"
done
HOLDING=$(wallet_fresh_holding n1) || HOLDING=""
[ -n "$HOLDING" ] || die "no unused holding account"
BOUNDS=$(node_call n1 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
[ -n "$BOUNDS" ] || die "get_registry_bounds failed (rln module up?)"
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: $BOUNDS"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "claiming $CLAIM RLNTOK from the faucet"
CLAIM_RES=$(node_call n1 liblogos_lez_rln_module claim_tokens \
    "$(argfile cfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile hold "$HOLDING")" "$CLAIM" | jres) || CLAIM_RES=""
[ -n "$CLAIM_RES" ] || die "claim_tokens failed"
wait_balance n1 "$HOLDING" "$CLAIM" >/dev/null || die "faucet credit never landed (want $CLAIM)"

# Pre-warm both modules' root windows: responder-answered start calls must
# fit the library's 10s rlnInvoke budget, and a cold start's registry read
# can eat most of that on a slow target. start is idempotent.
for n in $NODES_ALL; do
    PREWARM=$(node_call "$n" liblogos_rln_module start \
        "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || PREWARM=""
    case "$PREWARM" in
        *'"started":true'*) say "$n: rln module pre-warmed" ;;
        *) die "$n: rln module start (pre-warm) failed: ${PREWARM:-<empty>}" ;;
    esac
done

# ---------- responders up, then the delivery nodes ---------------------------
section "delivery nodes (bring-up via the real config surface)"
for n in $NODES_ALL; do
    node_watch_start "$n" delivery_module
    : >"$E2E_RUN_DIR/responder-$n.log"
    responder_loop "$n" &
    RESPONDER_PIDS="$RESPONDER_PIDS $!"
done
say "responders: one background bridge per node"

# The RLN scope rides createNode's flat conf — the keys delivery added at
# a48f8b8a. No env injection, no fork patch.
delivery_cfg() {
    local port="$1" peers="$2"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"rln-relay":true,"rln-relay-lez":true,"rln-relay-registry-id":"%s","rln-relay-identifier":"%s","rln-relay-user-message-limit":%s,"rln-relay-epoch-sec":%s%s}' \
        "$port" "$CLUSTER_ID" "$REGISTRY_ID" "$RLN_ID" "$RATE_LIMIT" \
        "$E2E_EPOCH_SIZE_SEC" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

delivery_up() {
    local node="$1" peers="$2" port cfg peerid
    port=$(( BASE_PORT + ${node#n} ))
    cfg=$(delivery_cfg "$port" "$peers")
    must_call "$node" createNode "createNode" "$(argfile "cfg_$node" "$cfg")" >/dev/null
    must_call "$node" start "start (dispatch)" >/dev/null
    node_wait_event "$node" delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
        || die "$node: no nodeStarted within ${EVT_TIMEOUT}s (RLN legs unanswered? see responder log)"
    peerid=$(must_call "$node" getNodeInfo "getNodeInfo MyPeerId" MyPeerId)
    [ -n "$peerid" ] || die "$node: empty MyPeerId"
    say "$node: delivery up on 127.0.0.1:$port (peer $peerid)"
    sv MADDR "$node" "/ip4/127.0.0.1/tcp/$port/p2p/$peerid"
}

delivery_up n1 ""
delivery_up n2 "$(gv MADDR n1)"

# ---------- bring-up assertions ----------------------------------------------
section "bring-up assertions"

# The register event n1's library emitted must carry the CONFIGURED scope —
# this is what the real config surface exists to prove.
EVT2=$(node_wait_event n1 delivery_module rlnRegisterRequest 5) \
    || die "n1 emitted no rlnRegisterRequest (config surface not wired?)"
EV_REGISTRY=$(evt_arg "$EVT2" 1)
EV_RLNID=$(evt_arg "$EVT2" 2)
EV_OPTS=$(evt_arg "$EVT2" 3)
[ "$EV_REGISTRY" = "$REGISTRY_ID" ] \
    || die "rlnRegisterRequest registry mismatch: event '$EV_REGISTRY' != configured '$REGISTRY_ID' — $EVT2"
[ "$EV_RLNID" = "$RLN_ID" ] \
    || die "rlnRegisterRequest rln_identifier mismatch: event '$EV_RLNID' != configured '$RLN_ID' — $EVT2"
EV_RATE=$(printf '%s' "$EV_OPTS" | python3 -c '
import json, sys
kv = {o.get("key"): o.get("value") for o in json.load(sys.stdin) if isinstance(o, dict)}
print(kv.get("rate_limit", ""))' 2>/dev/null) || EV_RATE=""
[ "$EV_RATE" = "$RATE_LIMIT" ] \
    || die "rlnRegisterRequest rate_limit mismatch: options carried '$EV_RATE', want '$RATE_LIMIT' — options: $EV_OPTS"
say "n1: register request carries the configured scope byte-exact"

# Timeouts also resolve the library's awaits (best-effort bring-up), so
# nodeStarted alone doesn't prove the responses LANDED — the library's own
# log lines do.
REG_LOGGED=0
for _t in $(seq 1 15); do
    if node_logs n1 | grep -q "RLN module start failed"; then
        die "n1's library saw the start leg fail: $(node_logs n1 | grep -m1 'RLN module start failed')"
    fi
    if node_logs n1 | grep -q "RLN membership registered"; then
        REG_LOGGED=1
        break
    fi
    sleep 1
done
[ "$REG_LOGGED" = 1 ] \
    || die "n1's library never logged 'RLN membership registered' — responses may have raced the 10s window"
say "n1: library log confirms start + register landed inside the 10s windows"

# n2: the deliberately-refused registration degraded instead of breaking
# bring-up (nodeStarted already proved the node came up).
node_logs n2 | grep -q "RLN membership registration failed" \
    || die "n2 never logged the expected 'RLN membership registration failed' notice"
say "n2: refused registration degraded gracefully (node up, notice logged)"

# ---------- the registration is real: pending -> active on chain -------------
section "confirmation (real chain)"
say "polling n1 get_membership_state to active (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
STATE=""
STATE_JSON=""
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    STATE_JSON=$(node_call n1 liblogos_rln_module get_membership_state \
        "$REGISTRY_ID" "$(argfile rlnid2 "$RLN_ID")" | jres) || STATE_JSON=""
    STATE=$(printf '%s' "$STATE_JSON" | jfield state)
    say "  state poll $_t: ${STATE:-<none>}"
    case "$STATE" in
        active|grace_period) break ;;
        failed) die "registration FAILED on chain: $STATE_JSON" ;;
    esac
    sleep "$E2E_POLL_INTERVAL_S"
done
[ "$STATE" = "active" ] || [ "$STATE" = "grace_period" ] \
    || die "membership never became active (last state: ${STATE:-<none>})"
LEAF=$(printf '%s' "$STATE_JSON" | jfield leaf_index)
MEMBERSHIP_HASH=$(printf '%s' "$STATE_JSON" | jfield membership_hash)
say "n1 membership active at leaf $LEAF"

# ---------- mesh -------------------------------------------------------------
section "mesh (static peers, relay)"
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
for n in $NODES_ALL; do
    must_call "$n" subscribe "subscribe" "$TOPIC" >/dev/null
done
say "both nodes subscribed to $TOPIC"
sleep 1

# ---------- send leg: proof-gated relay n1 -> n2 -----------------------------
section "send leg (proof-gated relay, n1 -> n2)"
RECEIVED=0
ATTEMPT=0
while [ "$ATTEMPT" -lt "$SEND_ATTEMPTS" ]; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    PAYLOAD="rln-gated ping $ATTEMPT from n1"
    REQID=$(must_call n1 send "send (attempt $ATTEMPT)" "$TOPIC" \
        "$(argfile "pay_$ATTEMPT" "$PAYLOAD")")
    [ -n "$REQID" ] || die "send returned no requestId"
    PROP=$(node_wait_event n1 delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") || {
        node_wait_event n1 delivery_module messageError 1 "$REQID" >/dev/null \
            && die "messageError for requestId $REQID (see n1 responder log for the generate/verify trail)"
        die "no messagePropagated for requestId $REQID within ${EVT_TIMEOUT}s"
    }
    MSGHASH=$(printf '%s' "$PROP" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
    [ -n "$MSGHASH" ] || die "messagePropagated carried no messageHash: $PROP"
    say "attempt $ATTEMPT: propagated (requestId $REQID, hash ${MSGHASH:0:18}…)"
    if node_wait_event n2 delivery_module messageReceived "$RECV_WAIT_S" "$MSGHASH" >/dev/null; then
        RECEIVED=1
        say "attempt $ATTEMPT: n2 received the proof-gated message"
        break
    fi
    # Likely the fresh-root window on n2: its module answered `invalid`, the
    # validator Rejected, and the module nudged its window refresh. A NEW
    # send (fresh slot) after the nudge should pass.
    say "attempt $ATTEMPT: not received on n2 (fresh-root window?) — n2 verify trail: $(grep -o 'verify verdict=[a-z_]*' "$E2E_RUN_DIR/responder-n2.log" | tail -3 | tr '\n' ' ')"
    sleep 3
done
[ "$RECEIVED" = 1 ] || die "n2 never received a proof-gated message in $SEND_ATTEMPTS attempts — n2 responder log tail: $(tail -5 "$E2E_RUN_DIR/responder-n2.log")"

# The verdict that let the message through crossed the seam verbatim:
# lowercase module wire, parsed by the library, Accepted by the validator.
grep -q "verify verdict=valid" "$E2E_RUN_DIR/responder-n2.log" \
    || die "n2's responder never answered a validate_proof with verdict=valid"
GEN_COUNT=$(grep -c "generate ok" "$E2E_RUN_DIR/responder-n1.log" || true)
N2_VERDICTS=$(grep -o "verify verdict=[a-z_]*" "$E2E_RUN_DIR/responder-n2.log" | sed 's/verify verdict=//' | tr '\n' ',' | sed 's/,$//')
say "n1 proofs generated: $GEN_COUNT (each a real slot); n2 verdicts: $N2_VERDICTS"

echo
echo "e2e: PASS — delivery-rln (target $E2E_TARGET)"
echo "e2e:   config    rln-relay-lez/-registry-id/-identifier/-user-message-limit (no env fork)"
echo "e2e:   keystore  module-owned custody — zero unlock calls anywhere"
echo "e2e:   bring-up  n1 start+register ok (ACTIVE at leaf $LEAF, $MEMBERSHIP_HASH); n2 register refused -> degraded gracefully"
echo "e2e:   message   n1 generate_proof (proof_canonical) -> gossipsub -> n2 validate_proof -> \"valid\" -> messageReceived (attempt $ATTEMPT/$SEND_ATTEMPTS)"
echo "e2e:   verdicts  n2 saw: $N2_VERDICTS (lowercase module wire, crossing verbatim)"