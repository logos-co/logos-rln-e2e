#!/usr/bin/env bash
# scenarios/delivery-rln — end-to-end acceptance for logos-delivery's RLN
# integration (branch impl-plugable-rln-api-module REBASED onto
# feat/rln-api-structure e5f8f327 — the rln/integration-fixes stacks on
# BOTH logos-delivery and logos-delivery-module) against the REAL RLN
# module stack.
#
# The seam under test is event-out/respond-in: liblogosdelivery's rlnInvoke
# fires a C callback into delivery_module, which re-emits it as an
# rln*Request logos event; whoever handles it answers via
# delivery_module.rlnRespond(reqId, resultJson). THIS SCRIPT runs a
# background responder per node, bridging every request to
# liblogos_rln_module and feeding the MODULE'S REPLY BACK VERBATIM — since
# the seam rework (delivery's 95e7e3c7) the library parses the module's own
# wire dialects and the ok/err envelope is gone.
#
# What it proves:
#   1. co-residency: the RLN stack + the RLN-enabled delivery_module load in
#      one daemon, on both nodes — and BOTH responder topologies work: n1
#      runs delivery_module's in-process bridge (rlnBridgeAttach — the
#      production default, no responder loop), n2 the external
#      event-out/respond-in responder.
#   2. bring-up via the REAL config surface: rln-relay-lez /
#      rln-relay-registry-id / rln-relay-identifier /
#      rln-relay-user-message-limit / rln-relay-registry-options ride
#      createNode's flat conf, the rlnStartRequest carries the module's
#      start config (epoch + registries — no more out-of-band responder
#      knowledge), and the rlnRegisterRequest options array is asserted to
#      carry the configured scope, rate AND the conf-fed funding pair (the
#      responder injects nothing).
#   3. keystore custody default: NO unlock call anywhere — the module
#      self-provisions its own secret (the headless deployment shape;
#      contract: docs/delivery-integration.md §1).
#   4. registration is REAL on n1 (pending -> active on the target chain),
#      answered inside the library's per-op budgets (95 s for registry-read
#      ops, 10 s local). n2's register is answered with a module-shaped
#      error ON PURPOSE: a failed best-effort registration must degrade
#      (the node still starts, relays and validates) instead of failing
#      bring-up.
#   5. the message path, end to end: n1 send -> rlnGenerateProofRequest ->
#      module generate_proof (its proof_canonical bytes become
#      message.proof) -> gossipsub -> n2's validator ->
#      rlnValidateProofRequest -> module validate_proof -> the lowercase
#      "valid" verdict crosses verbatim -> messageReceived on n2. A
#      fresh-root "invalid" on an early attempt is tolerated: the module
#      nudges its root window and a later send passes — the send leg
#      retries with fresh messages; slot accounting is asserted (one
#      distinct message_id per attempt).
#   6. the NEGATIVE control: n2's responder corrupts the signal for one
#      probe message, the module answers "invalid", and the scenario
#      asserts n2 does NOT deliver it — the verdict actually gates.
#
# Required checkouts (the integration branches have no flake pins):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ rln/integration-fixes
#                             (rebased: start-config event + verbatim-reply
#                             docs; fork adklempner/logos-delivery-module)
#   LOGOS_DELIVERY_CHECKOUT   logos-delivery @ rln/integration-fixes
#                             (impl branch rebased onto the api structure;
#                             upstream absorbed errors->Ignore, the prover
#                             leg and the RegistryOptions register — only
#                             the legacy-provider retype is still ours;
#                             fork adklempner/logos-delivery);
#                             submodules checked out
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
# Without the right overrides this runs against stale pins — fail with the
# pointer instead of a confusing hang or a minutes-later assertion.
# A prebuilt DELIVERY_LGX carries both halves; otherwise BOTH checkouts are
# needed (the DM flake pins the pre-fixes logos-delivery, so a shim-only
# override silently tests the wrong Nim library).
if [ -z "${DELIVERY_LGX:-}" ]; then
    [ -n "${DELIVERY_MODULE_CHECKOUT:-}" ] && [ -n "${LOGOS_DELIVERY_CHECKOUT:-}" ] \
        || die "delivery-rln needs the integration branches: set BOTH DELIVERY_MODULE_CHECKOUT and LOGOS_DELIVERY_CHECKOUT (rln/integration-fixes) or a prebuilt DELIVERY_LGX"
fi
# The e2e flake pin predates the 0.6.1 module wire (proof_canonical +
# RegistryOptions register) this scenario asserts.
[ -n "${RLN_LGX:-}" ] || [ -n "${RLN_MODULES_CHECKOUT:-}" ] \
    || die "delivery-rln needs the 0.6.1 module stack — the flake pin predates it; set RLN_MODULES_CHECKOUT (or RLN_LGX)"

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
# and answers with THE MODULE'S REPLY VERBATIM (delivery-module docs/rln.md):
# the library parses the module's two wire dialects itself — the LogosResult
# envelope for start/stop/get_epoch_quota/generate_proof/validate_proof, the
# compact tstr reply (in-band {"error":{...}}) for register_membership /
# get_membership_state. No re-wrapping, no kind mapping: a responder is a
# router, not a translator.
# reqId values >= 2^63 print negative — echoed back unchanged.

b64d() { printf '%s' "$1" | base64 -d; }

# Module-shaped failures for when the module CALL itself dies (no reply at
# all) — result dialect / tstr dialect respectively.
RESULT_FAIL='{"success":false,"error":"{\"class\":\"transient\",\"kind\":\"e2e_no_reply\",\"message\":\"module call failed\"}"}'
TSTR_FAIL='{"error":{"class":"transient","kind":"e2e_no_reply","message":"module call failed"}}'
TSTR_FAIL_REFUSED='{"error":{"class":"transient","kind":"e2e_refused","message":"validator node registers nothing (deliberate)"}}'

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
        # (reqId, configJson) — the start config rides the seam now: epoch
        # size + registries come from the NODE's conf through the library;
        # the responder just routes it to the module.
        local cfg res note
        cfg=$(b64d "$a1")
        case "$cfg" in
            *"$REGISTRY_ID"*) : ;;
            *) echo "responder[$node]: WARN start config lacks the registry: $cfg" ;;
        esac
        res=$(node_call "$node" liblogos_rln_module start "$cfg" | jres) || res=""
        [ -n "$res" ] || res="$RESULT_FAIL"
        case "$res" in
            *'"success":true'*) note="start ok" ;;
            *) note="start ERR: $res" ;;
        esac
        rln_respond "$node" "$req" "$res" "$note" ;;
    rlnRegisterRequest)
        if [ "$node" = "n1" ]; then
            # (reqId, registryId, rlnIdentifier, optionsJson) — the options
            # array arrives COMPLETE from the node's conf (rate_limit + the
            # funding pair via rln-relay-registry-options); it IS the
            # module's register_membership wire, so it passes through untouched
            # and the module's tstr reply goes back verbatim.
            local reg note
            reg=$(node_call "$node" liblogos_rln_module register_membership \
                "$(b64d "$a1")" "$(argfile "rr_${node}_${RANDOM}" "$(b64d "$a2")")" \
                "$(b64d "$a3")" | jres) || reg=""
            [ -n "$reg" ] || reg="$TSTR_FAIL"
            case "$reg" in
                *'"state":"pending"'*)
                    note="register ok (pending $(printf '%s' "$reg" | jfield membership_hash))" ;;
                *) note="register ERR: $reg" ;;
            esac
            rln_respond "$node" "$req" "$reg" "$note"
        else
            # Deliberate: the validator node keeps no membership. A failed
            # best-effort registration must degrade, not break bring-up —
            # asserted later via n2's own notice log + working validate.
            # The refusal is a module-shaped tstr error.
            rln_respond "$node" "$req" "$TSTR_FAIL_REFUSED" \
                "register deliberately refused (degradation probe)"
        fi ;;
    rlnGenerateProofRequest)
        # (reqId, registryId, rlnIdentifier, signalHex, epochTimestamp) —
        # the module's result envelope goes back verbatim; the library digs
        # value.proof_canonical out itself.
        local out note
        out=$(node_call "$node" liblogos_rln_module generate_proof \
            "$(b64d "$a1")" "$(argfile "gp_${node}_${RANDOM}" "$(b64d "$a2")")" \
            "$(argfile "gs_${node}_${RANDOM}" "$(b64d "$a3")")" \
            "str:$(b64d "$a4")" | jres) || out=""
        [ -n "$out" ] || out="$RESULT_FAIL"
        case "$out" in
            *'"proof_canonical"'*)
                note="generate ok (slot $(printf '%s' "$out" | jval | jfield message_id))" ;;
            *) note="generate ERR: $out" ;;
        esac
        rln_respond "$node" "$req" "$out" "$note" ;;
    rlnValidateProofRequest)
        # (reqId, registryId, rlnIdentifier, signalHex, epochTimestamp,
        #  proofJson) — event and module method share the validate name since
        # delivery-module bcdc8348. Envelope forwarded verbatim.
        local out verdict note sig
        sig=$(b64d "$a3")
        if [ -f "$E2E_RUN_DIR/tamper-$node" ]; then
            # Negative-control hook: corrupt the SIGNAL (not the proof — a
            # mangled proof can fail deserialization and come back a module
            # ERROR, which delivery maps to Ignore; a bad signal is a clean
            # deterministic "invalid" verdict).
            sig=$(printf '%s' "$sig" | python3 -c '
import sys
s = sys.stdin.read().strip()
print(s[:-1] + ("0" if s[-1] != "0" else "1"))')
            echo "responder[$node]: TAMPER active — signal corrupted for reqId=$req"
        fi
        out=$(node_call "$node" liblogos_rln_module validate_proof \
            "$(b64d "$a1")" "$(argfile "vp_${node}_${RANDOM}" "$(b64d "$a2")")" \
            "$(argfile "vs_${node}_${RANDOM}" "$sig")" \
            "str:$(b64d "$a4")" \
            "$(argfile "vj_${node}_${RANDOM}" "$(b64d "$a5")")" | jres) || out=""
        [ -n "$out" ] || out="$RESULT_FAIL"
        case "$out" in
            *'"verdict"'*)
                verdict=$(printf '%s' "$out" | jval | jfield verdict)
                note="verify verdict=$verdict" ;;
            *) note="verify ERR: $out" ;;
        esac
        rln_respond "$node" "$req" "$out" "$note" ;;
    *)
        # Answer instead of starving the library's await; the post-run check
        # turns any occurrence into a failure, so a future seam leg (stop /
        # get_membership_state / get_epoch_quota) fails loudly, not by timeout.
        echo "responder[$node]: UNHANDLED op $ev (reqId $req)"
        rln_respond "$node" "$req" "$RESULT_FAIL" "UNHANDLED $ev" ;;
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

# Pre-warm both modules' root windows: start sits in the library's 10s
# LOCAL budget, and a cold start's registry read can eat most of that on a
# slow target. start is idempotent.
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
# MIXED TOPOLOGY, both production-relevant shapes in one run:
#   n1: delivery_module's IN-PROCESS bridge (rlnBridgeAttach) answers its own
#       seam — no responder, the production default.
#   n2: the external event-out/respond-in responder — the topology that also
#       hosts the negative control's tamper hook (an in-process answer leaves
#       no seam to corrupt at).
for n in $NODES_ALL; do
    node_watch_start "$n" delivery_module
    : >"$E2E_RUN_DIR/responder-$n.log"
done
ATTACH=$(node_call n1 delivery_module rlnBridgeAttach "liblogos_rln_module" | jres)
case "$ATTACH" in
    *'"success":true'*) say "n1: in-process rln bridge attached (no responder)" ;;
    *) die "n1: rlnBridgeAttach failed: ${ATTACH:-<empty>}" ;;
esac
responder_loop n2 &
RESPONDER_PIDS="$RESPONDER_PIDS $!"
say "n2: external responder up (event-out/respond-in topology)"

# The RLN scope rides createNode's flat conf. n1 additionally carries the
# funding pair via rln-relay-registry-options — the conf-fed path that
# retires the responder's payer injection (the seam finally has a field
# for who funds a registration).
delivery_cfg() {
    local port="$1" peers="$2" extra="$3"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"rln-relay":true,"rln-relay-lez":true,"rln-relay-registry-id":"%s","rln-relay-identifier":"%s","rln-relay-user-message-limit":%s,"rln-relay-epoch-sec":%s%s%s}' \
        "$port" "$CLUSTER_ID" "$REGISTRY_ID" "$RLN_ID" "$RATE_LIMIT" \
        "$E2E_EPOCH_SIZE_SEC" "$extra" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

delivery_up() {
    local node="$1" peers="$2" extra="${3:-}" port cfg peerid
    port=$(( BASE_PORT + ${node#n} ))
    cfg=$(delivery_cfg "$port" "$peers" "$extra")
    must_call "$node" createNode "createNode" "$(argfile "cfg_$node" "$cfg")" >/dev/null
    must_call "$node" start "start (dispatch)" >/dev/null
    node_wait_event "$node" delivery_module nodeStarted "$EVT_TIMEOUT" >/dev/null \
        || die "$node: no nodeStarted within ${EVT_TIMEOUT}s (RLN legs unanswered? see responder log)"
    peerid=$(must_call "$node" getNodeInfo "getNodeInfo MyPeerId" MyPeerId)
    [ -n "$peerid" ] || die "$node: empty MyPeerId"
    say "$node: delivery up on 127.0.0.1:$port (peer $peerid)"
    sv MADDR "$node" "/ip4/127.0.0.1/tcp/$port/p2p/$peerid"
}

FUNDING_OPTS=$(printf ',"rln-relay-registry-options":"{\\"funding_holding_account_id\\":\\"%s\\"}"' "$HOLDING")
delivery_up n1 "" "$FUNDING_OPTS"
delivery_up n2 "$(gv MADDR n1)"

# ---------- bring-up assertions ----------------------------------------------
section "bring-up assertions"

# The start event must carry the module's start config, built from the
# node's OWN conf — the epoch size and registry no longer arrive out of
# band at the responder (the old finding-8 gap, now closed).
EVT1=$(node_wait_event n1 delivery_module rlnStartRequest 5) \
    || die "n1 emitted no rlnStartRequest"
EV_CFG=$(evt_arg "$EVT1" 1)
printf '%s' "$EV_CFG" | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
assert int(cfg["epoch_size_sec"]) == int(sys.argv[1]), \
    "epoch_size_sec %r != configured %s" % (cfg.get("epoch_size_sec"), sys.argv[1])
assert sys.argv[2] in cfg.get("registries", []), \
    "registry %s not in registries %r" % (sys.argv[2], cfg.get("registries"))
' "$E2E_EPOCH_SIZE_SEC" "$REGISTRY_ID" \
    || die "rlnStartRequest config mismatch: '$EV_CFG' (want epoch $E2E_EPOCH_SIZE_SEC + registry $REGISTRY_ID)"
say "n1: start request carries the node conf's exact epoch + registry"

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
EV_FUNDING=$(printf '%s' "$EV_OPTS" | python3 -c '
import json, sys
kv = {o.get("key"): o.get("value") for o in json.load(sys.stdin) if isinstance(o, dict)}
print(kv.get("funding_holding_account_id", ""))' 2>/dev/null) || EV_FUNDING=""
[ "$EV_FUNDING" = "$HOLDING" ] \
    || die "rlnRegisterRequest funding mismatch: options carried '$EV_FUNDING', want '$HOLDING' — options: $EV_OPTS"
say "n1: register options carry the configured scope, rate AND the conf-fed funding pair"

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
    || die "n1's library never logged 'RLN membership registered' — responses may have raced the library's budget"
say "n1: library log confirms start + register landed inside the per-op budgets"

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

# n2 never registered, so its valid-root window warms only through its own
# registry reads — which go lez-rln -> lez_core (the wallet). On testnet the
# wallet can still be churning through a long sync here (thousands of
# "Stored persistent accounts" writes), and while its event loop is
# saturated the remote object is unacquirable: every validate_proof then
# answers not_ready ("valid-root window not warm yet") and delivery Ignores
# the message. Wait for n2's read path before sending; validate nudges the
# window's own refresh once reads work.
ROOTS_WARM_BUDGET_S="${E2E_ROOTS_WARM_BUDGET_S:-300}"
say "waiting for n2's registry read path (valid roots via lez_core; budget ${ROOTS_WARM_BUDGET_S}s)…"
ROOTS_T0=$(date +%s)
ROOTS_N2=""
while :; do
    ROOTS_N2=$(node_call n2 liblogos_rln_module get_valid_roots "$REGISTRY_ID" 2>/dev/null | jres) || ROOTS_N2=""
    case "$ROOTS_N2" in
        *'"valid_roots":["'*) break ;;
    esac
    if [ $(( $(date +%s) - ROOTS_T0 )) -ge "$ROOTS_WARM_BUDGET_S" ]; then
        die_node n2 "registry read path never warmed in ${ROOTS_WARM_BUDGET_S}s (wallet still syncing?) — last reply: ${ROOTS_N2:-<empty>}"
    fi
    sleep 5
done
say "n2 registry read path warm after $(( $(date +%s) - ROOTS_T0 ))s"

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

# Every attempt spent a real slot: one generate request per attempt (n1 is
# bridged, so the module's replies are not harness-visible — the request
# events still are, and the module's own quota assertions live in
# consumer-register).
sleep 1 # let the last event line flush
GEN_COUNT=$(grep -c '"event":"rlnGenerateProofRequest"' "$(gv NODEEVT n1_delivery_module)" || true)
[ "$GEN_COUNT" = "$ATTEMPT" ] \
    || die "slot accounting: $GEN_COUNT generate requests for $ATTEMPT send attempts"
say "slot accounting: $GEN_COUNT attempts drove $GEN_COUNT generate requests"

# ---------- negative control: the verdict actually GATES ----------------------
# n2's responder now corrupts the SIGNAL before validating, forcing a real
# "invalid" verdict from the module. Delivery must Reject: the message
# propagates from n1 but must NOT surface as messageReceived on n2.
section "negative control (tampered validation must NOT deliver)"
: >"$E2E_RUN_DIR/tamper-n2"
PAYLOAD="rln-gated ping TAMPER from n1"
REQID=$(must_call n1 send "send (tamper probe)" "$TOPIC" "$(argfile pay_tamper "$PAYLOAD")")
PROP=$(node_wait_event n1 delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") \
    || die "tamper probe never propagated from n1"
MSGHASH_T=$(printf '%s' "$PROP" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
if node_wait_event n2 delivery_module messageReceived "$RECV_WAIT_S" "$MSGHASH_T" >/dev/null; then
    die "NEGATIVE CONTROL FAILED: n2 delivered a message its module called invalid — delivery is not gating on the verdict"
fi
grep -q "TAMPER active" "$E2E_RUN_DIR/responder-n2.log" \
    || die "tamper hook never fired on n2 (probe did not reach validation?)"
grep -q "verify verdict=invalid" "$E2E_RUN_DIR/responder-n2.log" \
    || die "n2's module never answered 'invalid' for the tampered signal — responder tail: $(tail -3 "$E2E_RUN_DIR/responder-n2.log")"
rm -f "$E2E_RUN_DIR/tamper-n2"
say "tampered message: verdict=invalid crossed, n2 did NOT deliver — the gate is real"

# No seam op may go unanswered: an UNHANDLED line means delivery grew a leg
# the responder (and this scenario) must learn.
if grep -q "UNHANDLED op" "$E2E_RUN_DIR"/responder-n1.log "$E2E_RUN_DIR"/responder-n2.log 2>/dev/null; then
    die "responder hit unhandled seam ops: $(grep -h 'UNHANDLED op' "$E2E_RUN_DIR"/responder-*.log | sort -u | tr '\n' ' ')"
fi

# The verdict that let the message through crossed the seam verbatim:
# lowercase module wire, parsed by the library, Accepted by the validator.
grep -q "verify verdict=valid" "$E2E_RUN_DIR/responder-n2.log" \
    || die "n2's responder never answered a validate_proof with verdict=valid"
N2_VERDICTS=$(grep -o "verify verdict=[a-z_]*" "$E2E_RUN_DIR/responder-n2.log" | sed 's/verify verdict=//' | tr '\n' ',' | sed 's/,$//')
say "n2 verdict trail: $N2_VERDICTS"

echo
echo "e2e: PASS — delivery-rln (target $E2E_TARGET)"
echo "e2e:   config    rln-relay-lez/-registry-id/-identifier/-user-message-limit/-registry-options (funding via conf, no responder injection)"
echo "e2e:   seam      start carries the module config; module replies forwarded VERBATIM (ok/err envelope retired)"
echo "e2e:   keystore  module-owned custody — zero unlock calls anywhere"
echo "e2e:   bring-up  n1 start+register ok (ACTIVE at leaf $LEAF, $MEMBERSHIP_HASH); n2 register refused -> degraded gracefully"
echo "e2e:   message   n1 generate_proof (proof_canonical) -> gossipsub -> n2 validate_proof -> \"valid\" -> messageReceived (attempt $ATTEMPT/$SEND_ATTEMPTS)"
echo "e2e:   topology  n1 IN-PROCESS bridge (rlnBridgeAttach, no responder); n2 external responder"
echo "e2e:   gate      tampered signal -> \"invalid\" -> NOT delivered (negative control); $ATTEMPT attempts = $GEN_COUNT generate requests"
echo "e2e:   verdicts  n2 saw: $N2_VERDICTS (lowercase module wire, crossing verbatim)"