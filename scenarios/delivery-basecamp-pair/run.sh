#!/usr/bin/env bash
# scenarios/delivery-basecamp-pair — two Basecamp instances talking to each
# other, with no logoscore daemon anywhere.
#
# Topology:
#   a   the desktop app (dev #app build, QML inspector), headless, its own
#       --user-dir and its own wallet home. Sends.
#   b   a second instance of the same app on its own inspector port, peered to
#       a through staticnodes. Receives, and validates the proof with its own
#       in-process bridge.
#
# Every other Basecamp scenario pairs the app with a logoscore daemon that does
# half the work — the chain oracle, the validating receiver. This one has no
# daemon at all, so both halves of the RLN path run inside an embedded core:
# app A proves, app B validates. That is the topology nothing else covers, and
# it is the shape a real two-user Basecamp conversation takes.
#
# What it proves:
#   1. two embedded cores coexist on one machine — separate user-dirs, separate
#      wallets, separate derived payers, separate inspector ports.
#   2. each provisions its OWN membership: the harness funds two accounts and
#      calls no register anywhere. Two leaves, one per app.
#   3. a's message reaches b only after b's own module validated the proof.
#
# Required (beyond docs/contract.md):
#   DELIVERY_MODULE_CHECKOUT  logos-delivery-module @ master
#   LOGOS_DELIVERY_CHECKOUT   logos-delivery @ master (submodules checked out)
#   BASECAMP_CHECKOUT         logos-basecamp (or BASECAMP_APP binary)
#
# Env knobs:
#   E2E_RATE_LIMIT=100           registration rate limit
#   E2E_BC_PAIR_PORT=61970       tcp ports are PORT+1 (a), PORT+2 (b)
#   E2E_INSPECTOR_PORT=3768      a takes this port, b takes the next
#   E2E_BASECAMP_SETTLE_S=20     post-launch settle before driving an app
#   E2E_MESH_WAIT_S=12           gossipsub mesh stabilization pause
#   E2E_SEND_ATTEMPTS=3          message-leg attempts (fresh-root window)
#   E2E_RECV_WAIT_S=20           per-attempt receive wait on b
#
# `--keep` leaves both instances running against a live devnet and prints what
# a human needs to drive them by hand. That is the useful half of the manual
# fixture in logos-rln-e2e PR #3; the other half of it — "open the membership
# UI and claim from the faucet" — describes a UI that cannot load on this stack
# and a faucet that no longer exists.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain basecamp delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
BASE_PORT="${E2E_BC_PAIR_PORT:-61970}"
CLUSTER_ID="${E2E_CLUSTER_ID:-199}"
MESH_WAIT_S="${E2E_MESH_WAIT_S:-12}"
SEND_ATTEMPTS="${E2E_SEND_ATTEMPTS:-3}"
RECV_WAIT_S="${E2E_RECV_WAIT_S:-20}"
TOPIC="/logos-rln-e2e/1/basecamp-pair/proto"
UD_ROOT="$E2E_RUN_DIR/basecamp"

# One identifier for both instances: it scopes the APPLICATION, not the member,
# and feeds the external nullifier each side derives. Peers that do not share
# it can never validate each other's proofs — which reads exactly like a broken
# prover, and cost a day the first time.
RLN_ID="${E2E_RLN_IDENTIFIER:-$(openssl rand -hex 32)}"

DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ]; then
        DYING=1
        basecamp_die_tails
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving both instances up, state in $E2E_RUN_DIR"
        return
    fi
    basecamp_stop
}
trap cleanup EXIT

# call delivery_module on one instance and insist on success; prints the reply.
bc_must_on() {
    local label="$1" method="$2" what="$3" args="${4:-[]}" res
    res=$(bc_call_on "$label" delivery_module "$method" "$args") || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" ;;
        *) die "$label: $what failed: ${res:-<empty>}" ;;
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
say "registry: $REGISTRY_ID (scope rate $RATE_LIMIT, identifier ${RLN_ID:0:16}…)"

# The node conf carries NO rln key at all — the same conf delivery-rln passes.
# The LEZ keys are gone from upstream outright and an unknown key is refused;
# `rln-relay: true` would make the conf builder demand an Ethereum chain id.
# The scope and the epoch size ride the RLN preset, which createNode resolves
# from LOGOS_DELIVERY_RLN_PRESETS; the rate limit is a register option.
delivery_cfg() {
    local port="$1" peers="$2"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true%s}' \
        "$port" "$CLUSTER_ID" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}


bc_port_of() { printf '%s' "$(( BASE_PORT + $1 ))"; }

# Both instances share one presets file: they must share the scope, and the
# app reads the path from its own environment at launch. Staged before either
# launches, because createNode is what resolves it.
RLN_PRESETS_FILE="$E2E_RUN_DIR/rln-presets.json"
delivery_stage_rln_presets "$RLN_PRESETS_FILE" "$REGISTRY_ID" "$RLN_ID" "$E2E_EPOCH_SIZE_SEC"

# ---------- per-instance bring-up ------------------------------------------
# Everything up to "has a membership and is not yet on the network". The two
# instances differ only in which port they listen on and whether they are given
# a peer, so this is one function called twice rather than two near-copies.
bring_up() {
    local label="$1"
    local home="$UD_ROOT/$label-wallet" ud="$UD_ROOT/$label"

    section "$label: basecamp up (own user-dir, own wallet)"
    basecamp_wallet_home "$home"
    basecamp_launch_as "$label" "$ud" "$home" "" \
        "$(delivery_rln_presets_env "$RLN_PRESETS_FILE")"
    basecamp_load_modules_on "$label" liblogos_lez_rln_module liblogos_rln_module delivery_module

    section "$label: wallet + payer"
    basecamp_wallet_open_sync_on "$label" "$home"
    local payer
    payer=$(basecamp_payer_on "$label") || die "$label: no payer"
    basecamp_fund_on "$label" || die "$label: funding failed"
    sv BCPAYER "$label" "$payer"
    say "$label: payer $payer funded — an account that held nothing until this transfer"

    # start names the registry; its provisioning task does the registering.
    # This scenario calls no register anywhere, on purpose.
    section "$label: rln start (the module provisions from here)"
    # Build the argument BEFORE the call. Inlining `"$(jq … "{\"k\":v}" …)"`
    # inside the `$( )` that captures the reply loses the backslash escapes —
    # the module then receives `"epoch_size_sec":60`, braces stripped and
    # truncated at the first comma, and answers "trailing characters at line 1
    # column 17".
    local st start_cfg start_args
    start_cfg=$(printf '{"epoch_size_sec":%s,"registries":["%s"],"rate_limit":%s}' \
        "$E2E_EPOCH_SIZE_SEC" "$REGISTRY_ID" "$RATE_LIMIT")
    start_args=$(jq -cn --arg c "$start_cfg" '[$c]')
    st=$(bc_call_on "$label" liblogos_rln_module start "$start_args") || st=""
    case "$st" in
        *'"started":true'*) say "$label: rln module started" ;;
        *) die "$label: rln module start failed: ${st:-<empty>}" ;;
    esac
}

# Wait for the membership the module provisions for itself.
await_provisioned() {
    local label="$1" state="" gms="" _t
    say "$label: waiting for the module to provision a membership (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
    for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        local gms_args
        gms_args=$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID" '[$r,$i]')
        gms=$(bc_call_on "$label" liblogos_rln_module get_membership_state "$gms_args") || gms=""
        state=$(printf '%s' "$gms" | grep -oE '"state":"[a-z_]+"' | head -1 | cut -d'"' -f4)
        case "$state" in
            unknown) say "  $label poll $_t: unknown ($(printf '%s' "$gms" | jfield provisioning))" ;;
            *) say "  $label poll $_t: ${state:-<none>}" ;;
        esac
        case "$state" in
            active|grace_period) break ;;
            failed) die "$label: provisioned registration FAILED on chain: $gms" ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    case "$state" in
        active|grace_period) : ;;
        *) die "$label: the module never provisioned a membership (last: ${state:-<none>}). \
This scenario deliberately registers nothing — if this times out, provisioning is what failed." ;;
    esac
    sv LEAF "$label" "$(printf '%s' "$gms" | grep -oE '"leaf_index":[0-9]+' | head -1 | cut -d: -f2)"
    say "$label: membership $state at leaf $(gv LEAF "$label") — provisioned, not registered by this test"
}

# createNode + start + subscribe. Prints the instance's multiaddr.
delivery_up_on() {
    local label="$1" idx="$2" peers="$3" port conf peerid
    port=$(bc_port_of "$idx")
    conf=$(delivery_cfg "$port" "$peers")
    bc_must_on "$label" createNode "createNode" "$(jq -cn --arg c "$conf" '[$c]')" >/dev/null
    delivery_wait_rln_ready_bc "$label"
    bc_must_on "$label" start "start" >/dev/null
    peerid=""
    local _t
    for _t in $(seq 1 60); do
        peerid=$(bc_call_on "$label" delivery_module getNodeInfo '["MyPeerId"]' 2>/dev/null \
            | grep -oE '"value":"[^"]+"' | cut -d'"' -f4) || peerid=""
        [ -n "$peerid" ] && break
        sleep 1
    done
    [ -n "$peerid" ] || die "$label: getNodeInfo never returned MyPeerId"
    bc_must_on "$label" subscribe "subscribe" "$(jq -cn --arg t "$TOPIC" '[$t]')" >/dev/null
    sv BCADDR "$label" "/ip4/127.0.0.1/tcp/$port/p2p/$peerid"
    say "$label: delivery up on 127.0.0.1:$port, subscribed to $TOPIC"
}

# ---------- both instances --------------------------------------------------
bring_up a
bring_up b

# Both provision concurrently — they were both started before either is waited
# on, so this measures two modules registering at once against one registry,
# not one after the other.
await_provisioned a
await_provisioned b
# One membership is one leaf, so two instances must land on two indices. Equal
# indices mean both are reading ONE membership — either they derived the same
# payer from a shared wallet home, or bc_call_on is routing both labels to the
# same inspector port and "b" is really a again. The second is what makes this
# check worth having: under it every other assertion here still passes, because
# a would be sending to itself over loopback and being asked about itself
# twice, and the run would go green having tested one instance and no topology.
[ "$(gv LEAF a)" != "$(gv LEAF b)" ] \
    || die "a and b both report leaf $(gv LEAF a) — one membership cannot back two instances. \
Either they share a wallet home, or both labels are being driven through one inspector port \
(a on $(bc_port a), b on $(bc_port b))."

# ---------- the network -----------------------------------------------------
# a first, with no peer; then b pointed at a. His fixture needed a docker relay
# for this because a HUMAN was copying a multiaddr between two GUIs — the
# harness just reads a's and hands it to b.
section "a: delivery up (no peer yet)"
delivery_up_on a 1 ""
section "b: delivery up (peered to a)"
delivery_up_on b 2 "$(gv BCADDR a)"

say "mesh stabilization: ${MESH_WAIT_S}s"
sleep "$MESH_WAIT_S"

# ---------- the message leg -------------------------------------------------
section "message leg (proof-gated, a -> b, both embedded cores)"
PAYLOAD="basecamp-pair-$(date +%s)-$RANDOM"
RECEIVED=0
ATTEMPT=0
for ATTEMPT in $(seq 1 "$SEND_ATTEMPTS"); do
    SEND_ARGS=$(jq -cn --arg t "$TOPIC" --arg p "$PAYLOAD" '[$t,{"_bytes":($p|@base64)}]')
    SEND=$(bc_call_on a delivery_module send "$SEND_ARGS") || SEND=""
    case "$SEND" in
        *'"success":true'*) : ;;
        *) die "a: send failed: ${SEND:-<empty>} — library gate: $(grep -m1 'usable RLN membership\|Failed to verify RLN membership\|Failed to attach RLN proof' "$(basecamp_log_path a)" 2>/dev/null || echo 'no gate error logged')" ;;
    esac
    if bc_log_wait_on b "Message received" "$RECV_WAIT_S"; then
        RECEIVED=1
        say "attempt $ATTEMPT: b received a message on its own embedded core"
        break
    fi
    say "attempt $ATTEMPT: not received on b (fresh-root window?) — retrying"
    sleep 3
done
[ "$RECEIVED" = 1 ] || die "b never received a's message in $SEND_ATTEMPTS attempts"

# b's bridge is what validated it. The preset brings the bridge up in-process
# and there is no external responder, so the library's own line is the evidence
# that the proof
# went through a validator rather than being relayed unchecked.
# Match the MODULE side of the call — `ModuleProxy: callRemoteMethod
# "validate_proof"` in liblogos_rln_module's own lines — not merely
# delivery_module attempting one. Without this the scenario would pass on a
# message that was relayed unvalidated, which is the one outcome it exists to
# rule out.
VALIDATES=$(grep -c 'callRemoteMethod "validate_proof"' "$(basecamp_log_path b)" 2>/dev/null || true)
[ "${VALIDATES:-0}" -ge 1 ] \
    || die "b received the message but its RLN module was never asked to validate_proof — \
the proof gate did not run, so this would be an unvalidated relay"
say "b: $VALIDATES validate_proof call(s) reached its own RLN module"

echo
echo "e2e: PASS — delivery-basecamp-pair (target $E2E_TARGET)"
echo "e2e:   topology  TWO Basecamp instances, no logoscore daemon anywhere — both halves of the RLN path ran inside an embedded core"
echo "e2e:   wallets   separate user-dirs, separate wallet homes, separate derived payers ($(gv BCPAYER a) / $(gv BCPAYER b))"
echo "e2e:   register  neither app was told to register: both provisioned from start(), at leaves $(gv LEAF a) and $(gv LEAF b)"
echo "e2e:   network   b peered to a via staticnodes $(gv BCADDR a) — no relay, no container"
echo "e2e:   message   a send -> proof attached -> gossipsub -> b validate_proof x$VALIDATES on its OWN rln module -> Message received (attempt $ATTEMPT/$SEND_ATTEMPTS)"

if [ "${E2E_KEEP:-0}" = "1" ]; then
    cat <<TXT

Both instances are left running. To drive them by hand:

  a  pid $(gv BCPID a)  inspector :$(bc_port a)  user-dir $(gv BCUD a)
  b  pid $(gv BCPID b)  inspector :$(bc_port b)  user-dir $(gv BCUD b)

  registry-id      $REGISTRY_ID
  rln-identifier   $RLN_ID
  topic            $TOPIC
  a's multiaddr    $(gv BCADDR a)
  b's multiaddr    $(gv BCADDR b)

Both already hold a membership and are subscribed, so a send on either should
arrive on the other. Stop them with:
  kill $(gv BCPID a) $(gv BCPID b)
TXT
fi
