#!/usr/bin/env bash
# scenarios/delivery-rln — end-to-end acceptance for logos-delivery's RLN
# integration (branch impl-plugable-rln-api-module REBASED onto
# feat/rln-api-structure e5f8f327 — the rln/integration-fixes stacks on
# BOTH logos-delivery and logos-delivery-module) against the REAL RLN
# module stack.
#
# The seam under test: liblogosdelivery's rlnInvoke fires a C callback into
# delivery_module, whose IN-PROCESS BRIDGE answers it by calling the
# co-loaded liblogos_rln_module and feeding the MODULE'S REPLY BACK VERBATIM
# (the library parses the module's own wire dialects; ok/err envelope gone).
# Since delivery-module ccbb3cd the bridge auto-enables whenever the node
# conf carries rln-relay-lez — there is no external-responder topology for
# lez any more. Each request is STILL re-emitted as an rln*Request event for
# observability, and delivery_module.rlnRespond(reqId, resultJson) still
# exists, but on a bridged node the bridge answers first and any external
# answer is rejected as a duplicate. THIS SCRIPT runs a WITNESS responder on
# n2 that routes every event to the module anyway and asserts exactly that
# contract (events emit; the guard accepts exactly one answer per reqId,
# always the bridge's on the hot path; the module's dedup verdict proves
# the bridge validated first).
#
# What it proves:
#   1. co-residency: the RLN stack + the RLN-enabled delivery_module load in
#      one daemon, on both nodes — and the in-process bridge auto-enables on
#      BOTH from the rln-relay-lez conf (no responder answers anything).
#   2. bring-up via the REAL config surface: rln-lez / rln-registry-id /
#      rln-identifier / rln-relay-user-message-limit / rln-registry-options
#      ride createNode's flat conf (spellings of logos-delivery
#      impl-plugable-rln-api-module 85c2d6f8), the rlnStartRequest carries
#      the module's start config (epoch + registries — no more out-of-band
#      responder knowledge), and the rlnGetMembershipStateRequest that
#      follows carries the configured scope (the responder injects nothing).
#   3. keystore custody default: NO unlock call anywhere — the module
#      self-provisions its own secret (the headless deployment shape;
#      contract: docs/delivery-integration.md §1).
#   4. registration is REAL, and it is the APP's job, not bring-up's: since
#      logos-delivery 131fc9b1 the library no longer registers at startup —
#      it reads the scope's membership state after start and REFUSES to
#      start the node without an active/grace_period membership ("the node
#      does not have a usable RLN membership"). So this script registers
#      BOTH nodes through liblogos_rln_module first (pending -> active on
#      the target chain, each node paying from its own faucet-funded
#      holding), then brings delivery up and asserts the library's "RLN membership
#      verified" gate on both. (The old fundless-n2 "degrade gracefully"
#      leg is gone with that design: a node without a membership does not
#      come up at all now.)
#   5. the message path, end to end: n1 send -> rlnGenerateProofRequest ->
#      module generate_proof (its proof_canonical bytes become
#      message.proof) -> gossipsub -> n2's validator ->
#      rlnValidateProofRequest -> module validate_proof -> the lowercase
#      "valid" verdict crosses verbatim -> messageReceived on n2. A
#      fresh-root "invalid" on an early attempt is tolerated: the module
#      nudges its root window and a later send passes — the send leg
#      retries with fresh messages; slot accounting is asserted (one
#      distinct message_id per attempt).
#   6. the NEGATIVE control: with the tamper hook armed, n2's witness
#      answers one probe with a corrupted-signal "invalid" — and the probe
#      is DELIVERED anyway, its answer rejected: an external responder
#      cannot hijack a bridged node's verdicts. (The old verdict-gates
#      control — a corrupted answer suppressing delivery — needed an
#      authoritative external responder; that topology no longer exists
#      for lez, so the Reject path now lives only in delivery's own tests.)
#
# Required checkouts (the integration branches have no flake pins):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ rln/integration-fixes
#                             (upstream ccbb3cd auto-enable bridge + our
#                             init-order fix; fork
#                             adklempner/logos-delivery-module)
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
    || die "target '$E2E_TARGET' provides funding=$E2E_FUNDING — n1's registration is paid from a faucet claim; pick a faucet deployment"
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

# ---------- the witness responder --------------------------------------------
# Routes every rln*Request n2's delivery module emits to liblogos_rln_module
# and answers with THE MODULE'S REPLY VERBATIM — exactly what an external
# responder used to do. The duplicate guard is FIRST-WINS: on the hot path
# the bridge always answers first, so a witness validate answer must always
# come back rejected ("unknown or already-completed reqId") — but on the
# registry-read ops the module's in-flight short-circuit can answer the
# witness while the bridge's identical call is still in flight, and then
# the bridge's own answer is the rejected one. The post-run guard check
# encodes exactly that split. The witness's second module reads also double
# as an oracle: a validate of a message the bridge already validated comes
# back "duplicate" (same nullifier + signal in the module's log).
# reqId values >= 2^63 print negative — echoed back unchanged.

b64d() { printf '%s' "$1" | base64 -d; }

# Module-shaped failures for when the module CALL itself dies (no reply at
# all) — result dialect / tstr dialect respectively.
RESULT_FAIL='{"success":false,"error":"{\"class\":\"transient\",\"kind\":\"e2e_no_reply\",\"message\":\"module call failed\"}"}'
TSTR_FAIL='{"error":{"class":"transient","kind":"e2e_no_reply","message":"module call failed"}}'

rln_respond() {
    local node="$1" req="$2" payload="$3" note="$4" res
    res=$(node_call "$node" delivery_module rlnRespond "$req" \
        "$(argfile "rsp_${node}_${RANDOM}" "$payload")" | jres) || res=""
    case "$res" in
        # The bridge answered first — the expected fate of every witness answer.
        *'"success":false'*) echo "responder[$node]: reqId=$req answer rejected as expected ($note)" ;;
        *'"success":true'*) echo "responder[$node]: reqId=$req answer ACCEPTED — bridge did not answer ($note)" ;;
        *) echo "responder[$node]: reqId=$req rlnRespond broke ($note): ${res:-<empty>}" ;;
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
        # (reqId, registryId, rlnIdentifier, optionsJson) — the options array
        # arrives COMPLETE from the node's conf; it IS the module's
        # register_membership wire, so it passes through untouched. Register
        # is idempotent per scope, so this second call after the bridge's is
        # a re-register short-circuit (or the same fast error on a node with
        # no funding option), never a double mint.
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
        rln_respond "$node" "$req" "$reg" "$note" ;;
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
            # Negative-control hook: corrupt the SIGNAL, producing a clean
            # "invalid" verdict (proof no longer binds the signal; no
            # nullifier is recorded for an invalid proof). The witness then
            # answers something MATERIALLY different from the bridge's
            # "valid" — and the rejection of that answer is the proof that
            # an external responder cannot flip a bridged node's verdict.
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
    rlnGetMembershipStateRequest)
        # (reqId, registryId, rlnIdentifier, timestamp) — the bring-up gate
        # since logos-delivery 131fc9b1: after start the library reads the
        # scope's membership state and refuses to start the node unless it
        # is active/grace_period. A tstr method: the module's object goes
        # back verbatim (the library parses the native dialect).
        local st note
        st=$(node_call "$node" liblogos_rln_module get_membership_state \
            "$(b64d "$a1")" "$(argfile "ms_${node}_${RANDOM}" "$(b64d "$a2")")" | jres) || st=""
        [ -n "$st" ] || st="$TSTR_FAIL"
        case "$st" in
            *'"state":"'*) note="membership state=$(printf '%s' "$st" | jfield state)" ;;
            *) note="membership state ERR: $st" ;;
        esac
        rln_respond "$node" "$req" "$st" "$note" ;;
    *)
        # Answer instead of starving the library's await; the post-run check
        # turns any occurrence into a failure, so a future seam leg (stop /
        # get_epoch_quota) fails loudly, not by timeout.
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

# ---------- wallets (both nodes pay for their own membership) ----------------
# BOTH nodes need an open wallet: the RLN module's registry reads (root
# window refresh, membership state) go through liblogos_lez_rln_module,
# whose account fetches need lez_core's wallet open — a validator-only node
# without one has a permanently cold root window. And since the library's
# bring-up gate needs a membership on every rln-enabled node, each node
# derives and funds ITS OWN holding: wallet-n2 is copied before n1 derives
# its account, so n1's holding key is not in n2's wallet (the sequencer
# rejects a spend from it with "'user_holding' must be a signer").
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
sv HOLD n1 "$HOLDING"
# n2: derived AFTER n1's claim landed, so the same-seed derivation skips
# n1's (now existing) account and lands on a genuinely fresh one.
HOLDING2=$(wallet_fresh_holding n2) || HOLDING2=""
[ -n "$HOLDING2" ] || die "n2: no unused holding account"
[ "$HOLDING2" != "$HOLDING" ] || die "n2 derived n1's holding ($HOLDING) — same-seed derivation not skipping existing accounts?"
say "n2: claiming $CLAIM RLNTOK from the faucet into its own holding"
CLAIM_RES2=$(node_call n2 liblogos_lez_rln_module claim_tokens \
    "$(argfile cfg3 "$E2E_CONFIG_ACCOUNT")" "$(argfile hold2 "$HOLDING2")" "$CLAIM" | jres) || CLAIM_RES2=""
[ -n "$CLAIM_RES2" ] || die "n2: claim_tokens failed"
wait_balance n2 "$HOLDING2" "$CLAIM" >/dev/null || die "n2: faucet credit never landed (want $CLAIM)"
sv HOLD n2 "$HOLDING2"

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

# ---------- registration (the app's job, before bring-up) -------------------
# The library's bring-up gate (logos-delivery 131fc9b1) requires an
# active/grace_period membership for the configured scope on EVERY
# rln-enabled node, so both register here through the module — the way an
# app (the membership UI) does — and wait for the chain to confirm. Each
# node pays from its own holding (derived and funded above); sequential so
# the two chain confirmations read cleanly.
section "registration (via liblogos_rln_module, pending -> active on chain)"
register_and_confirm() {
    local node="$1" reg state_json state options
    options="[{\"key\":\"rate_limit\",\"value\":\"$RATE_LIMIT\"},{\"key\":\"funding_holding_account_id\",\"value\":\"$(gv HOLD "$node")\"}]"
    reg=$(node_call "$node" liblogos_rln_module register_membership \
        "$REGISTRY_ID" "$(argfile "reg_$node" "$RLN_ID")" "$options" | jres) || reg=""
    case "$reg" in
        *'"state":"pending"'*) say "$node: register_membership accepted (pending $(printf '%s' "$reg" | jfield membership_hash))" ;;
        *) die "$node: register_membership failed: ${reg:-<empty>}" ;;
    esac
    say "$node: polling get_membership_state to active (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
    state=""
    state_json=""
    for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        state_json=$(node_call "$node" liblogos_rln_module get_membership_state \
            "$REGISTRY_ID" "$(argfile "st_$node" "$RLN_ID")" | jres) || state_json=""
        state=$(printf '%s' "$state_json" | jfield state)
        say "  $node state poll $_t: ${state:-<none>}"
        case "$state" in
            active|grace_period) break ;;
            failed) die "$node: registration FAILED on chain: $state_json" ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    [ "$state" = "active" ] || [ "$state" = "grace_period" ] \
        || die "$node: membership never became active (last state: ${state:-<none>})"
    sv LEAF "$node" "$(printf '%s' "$state_json" | jfield leaf_index)"
    sv MHASH "$node" "$(printf '%s' "$state_json" | jfield membership_hash)"
    say "$node: membership active at leaf $(gv LEAF "$node")"
}
register_and_confirm n1
register_and_confirm n2
LEAF=$(gv LEAF n1)
MEMBERSHIP_HASH=$(gv MHASH n1)

# ---------- witness up, then the delivery nodes ------------------------------
section "delivery nodes (bring-up via the real config surface)"
# ONE topology since delivery-module ccbb3cd: the conf's rln-lez auto-
# enables the in-process bridge in createNode on BOTH nodes (there is no
# external-responder topology for lez any more, and no opt-out key). n1 runs
# pure production shape; n2 additionally runs the WITNESS responder, which
# answers everything the way an external responder would and asserts every
# answer is rejected — plus hosts the tamper hook for the hijack control.
for n in $NODES_ALL; do
    node_watch_start "$n" delivery_module
    : >"$E2E_RUN_DIR/responder-$n.log"
done
responder_loop n2 &
RESPONDER_PIDS="$RESPONDER_PIDS $!"
say "n2: witness responder up (routes events; hot-path answers must all be rejected)"

# The RLN scope rides createNode's flat conf. n1 additionally carries the
# funding pair via rln-registry-options — the conf-fed path that
# retires the responder's payer injection (the seam finally has a field
# for who funds a registration). Key names follow logos-delivery
# impl-plugable-rln-api-module 85c2d6f8, which renamed the LEZ keys from
# rln-relay-{lez,registry-id,identifier,registry-options} to
# rln-{lez,registry-id,identifier,registry-options}; the parser rejects the
# old spellings outright ("Unrecognized configuration option(s)").
delivery_cfg() {
    local port="$1" peers="$2" extra="$3"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true,"rln-relay":true,"rln-lez":true,"rln-registry-id":"%s","rln-identifier":"%s","rln-relay-user-message-limit":%s,"rln-relay-epoch-sec":%s%s%s}' \
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

FUNDING_OPTS=$(printf ',"rln-registry-options":"{\\"funding_holding_account_id\\":\\"%s\\"}"' "$HOLDING")
delivery_up n1 "" "$FUNDING_OPTS"
delivery_up n2 "$(gv MADDR n1)"
# rln-lez in the conf is the bridge's own enable signal now — no
# separate key. createNode fails hard if the bridge can't come up, so this
# grep is about the LOG CONTRACT, not survival.
for n in $NODES_ALL; do
    grep -q "rln served in-process" "$(node_log_path "$n")" \
        || die "$n: conf carries rln-lez but createNode never logged 'rln served in-process' (bridge auto-enable broken?)"
done
say "both nodes: in-process rln bridge auto-enabled by the rln-lez conf"

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

# The membership-state gate the library runs right after start must ask
# for the CONFIGURED scope — this is what the real config surface exists to
# prove now that registration is no longer part of bring-up.
EVT2=$(node_wait_event n1 delivery_module rlnGetMembershipStateRequest 5) \
    || die "n1 emitted no rlnGetMembershipStateRequest (config surface not wired?)"
EV_REGISTRY=$(evt_arg "$EVT2" 1)
EV_RLNID=$(evt_arg "$EVT2" 2)
[ "$EV_REGISTRY" = "$REGISTRY_ID" ] \
    || die "rlnGetMembershipStateRequest registry mismatch: event '$EV_REGISTRY' != configured '$REGISTRY_ID' — $EVT2"
[ "$EV_RLNID" = "$RLN_ID" ] \
    || die "rlnGetMembershipStateRequest rln_identifier mismatch: event '$EV_RLNID' != configured '$RLN_ID' — $EVT2"
say "n1: the membership-state gate asks for the configured scope"

# Timeouts also resolve the library's awaits, so nodeStarted alone doesn't
# prove the responses LANDED — the library's own log lines do: "RLN
# membership verified" is the gate passing on the bridge's answer.
for n in $NODES_ALL; do
    GATE_LOGGED=0
    for _t in $(seq 1 15); do
        if node_logs "$n" | grep -q "RLN module start failed\|does not have a usable RLN membership"; then
            die "$n's library failed bring-up: $(node_logs "$n" | grep -m1 'RLN module start failed\|usable RLN membership')"
        fi
        if node_logs "$n" | grep -q "RLN membership verified"; then
            GATE_LOGGED=1
            break
        fi
        sleep 1
    done
    [ "$GATE_LOGGED" = 1 ] \
        || die "$n's library never logged 'RLN membership verified' — the gate's answer may have raced its budget"
done
say "both nodes: library log confirms start + the membership-state gate landed inside the per-op budgets"

# ---------- mesh -------------------------------------------------------------
section "mesh (static peers, relay)"
say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"
for n in $NODES_ALL; do
    must_call "$n" subscribe "subscribe" "$TOPIC" >/dev/null
done
say "both nodes subscribed to $TOPIC"
sleep 1

# n2's valid-root window warms through its own registry reads — which go
# lez-rln -> lez_core (the wallet). On testnet the
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
            && die "messageError for requestId $REQID (generate leg failed — see n1's daemon log)"
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

# ---------- negative control: external answers cannot hijack the bridge ------
# n2's witness corrupts the SIGNAL before validating one probe, producing a
# real "invalid" from the module — a verdict that CONTRADICTS the bridge's
# "valid". If external answers had any authority the probe would be dropped;
# instead it must be DELIVERED, and the witness's contradicting answer must
# be rejected. (The old drop-on-invalid control needed an authoritative
# external responder — a topology lez no longer has.)
section "negative control (external verdicts are rejected, message delivers)"
: >"$E2E_RUN_DIR/tamper-n2"
PAYLOAD="rln-gated ping TAMPER from n1"
REQID=$(must_call n1 send "send (tamper probe)" "$TOPIC" "$(argfile pay_tamper "$PAYLOAD")")
PROP=$(node_wait_event n1 delivery_module messagePropagated "$EVT_TIMEOUT" "$REQID") \
    || die "tamper probe never propagated from n1"
MSGHASH_T=$(printf '%s' "$PROP" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["data"].get("arg1",""))')
node_wait_event n2 delivery_module messageReceived "$RECV_WAIT_S" "$MSGHASH_T" >/dev/null \
    || die "NEGATIVE CONTROL FAILED: the probe never delivered — an external 'invalid' overrode the bridge's own verdict?"
grep -q "TAMPER active" "$E2E_RUN_DIR/responder-n2.log" \
    || die "tamper hook never fired on n2 (probe did not reach the witness?)"
grep -q "verify verdict=invalid" "$E2E_RUN_DIR/responder-n2.log" \
    || die "n2's module never answered 'invalid' for the corrupted signal — witness tail: $(tail -3 "$E2E_RUN_DIR/responder-n2.log")"
rm -f "$E2E_RUN_DIR/tamper-n2"
say "tamper probe: witness answered a contradicting 'invalid', was rejected, and the message delivered — external responders cannot hijack a bridged node"

# No seam op may go unanswered: an UNHANDLED line means delivery grew a leg
# the witness (and this scenario) must learn.
if grep -q "UNHANDLED op" "$E2E_RUN_DIR"/responder-n1.log "$E2E_RUN_DIR"/responder-n2.log 2>/dev/null; then
    die "witness hit unhandled seam ops: $(grep -h 'UNHANDLED op' "$E2E_RUN_DIR"/responder-*.log | sort -u | tr '\n' ' ')"
fi

# The duplicate guard: at most ONE answer lands per reqId, and it's
# first-wins, not bridge-wins. On the hot path (validate) the bridge always
# answers first — the witness pays a poll lag plus a full verify — so an
# accepted witness validate answer means the bridge went silent: fail. On
# the registry-read ops the module's own in-flight short-circuit can hand
# the WITNESS a fast reply while the bridge's identical call is still
# walking the registry (seen on testnet for n2's register), so first-wins
# legitimately goes either way there: log it, don't fail — the guard still
# rejected the loser.
grep -q "answer rejected as expected" "$E2E_RUN_DIR/responder-n2.log" \
    || die "n2's witness never got an answer rejected — did the events stop emitting?"
if grep "answer ACCEPTED" "$E2E_RUN_DIR/responder-n2.log" | grep -v "(register" | grep -q .; then
    die "duplicate guard failed on the hot path: a witness answer beat the bridge — $(grep 'answer ACCEPTED' "$E2E_RUN_DIR/responder-n2.log" | grep -v '(register' | head -2 | tr '\n' ' ')"
fi
if grep -q "answer ACCEPTED" "$E2E_RUN_DIR/responder-n2.log"; then
    say "n2 witness won a register race (module's in-flight short-circuit answered it first) — first answer wins, the bridge's own was the rejected one"
fi

# The two-reader oracle: the witness re-validated the delivered message
# AFTER the bridge did, so the module's nullifier log answers "duplicate" —
# proof in one verdict that the events emit, the bridge answered first, and
# the module's double-signal dedup works.
grep -q "verify verdict=duplicate" "$E2E_RUN_DIR/responder-n2.log" \
    || die "n2's witness never saw a 'duplicate' re-validate of the delivered message — bridge answered first? witness tail: $(tail -3 "$E2E_RUN_DIR/responder-n2.log")"
N2_VERDICTS=$(grep -o "verify verdict=[a-z_]*" "$E2E_RUN_DIR/responder-n2.log" | sed 's/verify verdict=//' | tr '\n' ',' | sed 's/,$//')
say "n2 witness verdict trail: $N2_VERDICTS"

echo
echo "e2e: PASS — delivery-rln (target $E2E_TARGET)"
echo "e2e:   config    rln-lez/rln-registry-id/rln-identifier/rln-relay-user-message-limit/rln-registry-options (85c2d6f8 spellings, no responder injection)"
echo "e2e:   seam      start carries the module config; module replies forwarded VERBATIM (ok/err envelope retired)"
echo "e2e:   keystore  module-owned custody — zero unlock calls anywhere"
echo "e2e:   bring-up  app-side register via the module on BOTH nodes (n1 ACTIVE at leaf $LEAF, $MEMBERSHIP_HASH; n2 leaf $(gv LEAF n2)), then start + the library's membership-state gate verified on both"
echo "e2e:   message   n1 generate_proof (proof_canonical) -> gossipsub -> n2 validate_proof -> \"valid\" -> messageReceived (attempt $ATTEMPT/$SEND_ATTEMPTS)"
echo "e2e:   topology  IN-PROCESS bridge auto-enabled by rln-lez on BOTH nodes; n2's witness rejected on every hot-path answer (guard is first-wins)"
echo "e2e:   gate      witness's contradicting \"invalid\" rejected, probe DELIVERED (hijack control); $ATTEMPT attempts = $GEN_COUNT generate requests"
echo "e2e:   verdicts  n2 witness saw: $N2_VERDICTS (duplicate = bridge validated first; module wire crossing verbatim)"