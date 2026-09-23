# shellcheck shell=bash
# harness/lib/delivery.sh — delivery_module's RLN bring-up, in one place.
#
# Since logos-delivery-module#118 (v0.3.0-rc.1) there is no configureRln: RLN
# comes from the network preset a node's createNode config names, and readiness
# is a separate observation because the backend comes up off that thread. Seven
# call sites across five scenarios need the same two steps, over two different
# transports — logoscore daemons (node_call) and Basecamp's embedded core
# (bc_call_on) — so they live here rather than as seven copies.
#
# The bodies were lifted from scenarios/delivery-rln/run.sh, which is where
# this shape was first written and verified.
#
# Source AFTER daemon.sh. The _bc variants additionally need basecamp.sh, but
# only at call time, so a scenario with no Basecamp need not source it.
#
# Env beyond docs/contract.md:
#   E2E_RLN_READY_TIMEOUT_S  180  budget for rlnState to reach Ready

. "$(dirname "${BASH_SOURCE[0]}")/json.sh"

# How many polls fit in a budget, at least one. A private copy on purpose:
# master's compat.sh does not define one, and the eight scenarios that want it
# each carry their own. A lib that relied on its caller having defined it would
# work in some scenarios and silently run `seq 1 ""` in others — which is two
# iterations, not the budget, and reads as the thing being waited for failing.
_delivery_polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

# Usage: delivery_stage_rln_presets <file> <registry> <rlnid> <epoch_size_sec>
# Writes the presets file and remembers the scope, so the readiness check can
# assert the node resolved the preset we actually wrote.
#
# Neither deployment these scenarios run against is a shipped preset — all of
# which ship RLN off — so each stages its own. The entry is keyed "" because
# delivery_cfg passes no preset and a flat WakuNodeConf defaults `preset` to
# the empty string. Names are matched exactly: a variant spelling is an error,
# not a miss, which is deliberate upstream so a node cannot come up on the
# right network with RLN silently off.
#
# MUST run before the daemon (or app) that reads it starts: the file is read at
# createNode, and one that cannot be parsed fails that call rather than quietly
# leaving RLN off.
delivery_stage_rln_presets() {
    local file="${1:?delivery_stage_rln_presets <file> <registry> <rlnid> <epoch>}"
    local registry="${2:?registry}" rlnid="${3:?rln identifier}" epoch="${4:?epoch size}"
    cat >"$file" <<JSON || die "cannot write rln presets to $file"
{"": {"enabled": true,
      "registry-id": "$registry",
      "rln-identifier": "$rlnid",
      "epoch-size-sec": $epoch}}
JSON
    sv RLNSCOPE registry "$registry"
    sv RLNSCOPE rlnid "$rlnid"
    sv RLNSCOPE epoch "$epoch"
    say "rln presets: $file"
}

# Usage: delivery_rln_presets_env <file>
# The env pair a daemon or app needs, as one token. daemon.sh word-splits
# E2E_DAEMON_ENV unquoted, so the path must not contain spaces.
delivery_rln_presets_env() {
    printf 'LOGOS_DELIVERY_RLN_PRESETS=%s' "${1:?delivery_rln_presets_env <file>}"
}

# Reads an rlnState reply on stdin and prints one word: ready | pending |
# disabled | failed | scope. Anything but ready/pending carries a detail after
# a colon.
#
# The state is parsed as a FIELD, not matched as a substring of the whole
# reply: `message` is free text, and a Failed whose message mentions "Ready"
# would otherwise report success.
#
# rlnState also returns the registryId / rlnIdentifier / epochSizeSec it
# resolved, so this checks them against what delivery_stage_rln_presets wrote.
# Nothing else does: two nodes that disagree on scope reject each other's
# messages as invalid rather than reporting a misconfiguration, which reads
# exactly like a product fault.
_delivery_rln_verdict() {
    # python3 -c, not a heredoc: a heredoc IS stdin, so the reply being piped
    # in would never reach the script.
    python3 -c '
import json, sys

want_reg, want_rlnid, want_epoch = sys.argv[1], sys.argv[2], sys.argv[3]
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    print("pending"); sys.exit()
if isinstance(d, str):
    try:
        d = json.loads(d)
    except Exception:
        print("pending"); sys.exit()
if isinstance(d, dict) and "success" in d and ("value" in d or "error" in d):
    if not d.get("success"):
        print("failed:%s" % (d.get("error") or "<no error>")); sys.exit()
    d = d.get("value") or {}
if not isinstance(d, dict):
    print("pending"); sys.exit()

state = d.get("state", "")
if state == "Failed":
    print("failed:%s" % (d.get("message") or "<no message>"))
elif state == "Disabled":
    print("disabled:%s" % (d.get("message") or "no preset resolved"))
elif state == "Ready":
    bad = ""
    for name, got, want in (
        ("registryId", d.get("registryId"), want_reg),
        ("rlnIdentifier", d.get("rlnIdentifier"), want_rlnid),
        ("epochSizeSec", d.get("epochSizeSec"), want_epoch),
    ):
        if got is None or not want:
            continue
        if str(got) != str(want):
            bad = "%s is %s, staged %s" % (name, got, want)
            break
    print("scope:" + bad if bad else "ready")
else:
    print("pending")
' "$(gv RLNSCOPE registry)" "$(gv RLNSCOPE rlnid)" "$(gv RLNSCOPE epoch)"
}

# Usage: _delivery_rln_ready_loop <who> <reader-command…>
# The shared poll. <reader-command> prints an rlnState reply on stdout.
_delivery_rln_ready_loop() {
    local who="$1"; shift
    local verdict _t
    # rlnState is polled rather than the log grepped: it reads a field instead
    # of waiting on a chain round trip, so it answers well inside logosctl's
    # fixed 20s transport deadline — which is what forced the log-line fallback
    # the old configureRln call needed.
    for _t in $(seq 1 "$(_delivery_polls "${E2E_RLN_READY_TIMEOUT_S:-180}" 5)"); do
        verdict=$("$@" | _delivery_rln_verdict) || verdict=""
        case "$verdict" in
            ready)
                say "$who: rlnState Ready (scope matches the staged preset)"
                return 0 ;;
            failed:*)
                die "$who: rlnState Failed — ${verdict#failed:}" ;;
            disabled:*)
                # Disabled is a misconfigured run, not a slow one: the preset
                # carried no RLN, which for these scenarios means the file
                # never reached the process.
                die "$who: rlnState Disabled — ${verdict#disabled:}. \
Is LOGOS_DELIVERY_RLN_PRESETS reaching it, and staged before it started?" ;;
            scope:*)
                die "$who: the node resolved a DIFFERENT scope than we staged — ${verdict#scope:}. \
Two nodes that disagree here reject each other's proofs as invalid." ;;
        esac
        sleep 5
    done
    die "$who: rlnState never reached Ready within ${E2E_RLN_READY_TIMEOUT_S:-180}s"
}

# Usage: delivery_wait_rln_ready <node>
# Between createNode and start. createNode installs the library's RLN plugin
# synchronously and then brings the backend up on its own thread, so a node is
# not ready the moment the call returns; start fires the library's
# get_membership_state gate, and a backend still initializing has nothing to
# answer it with.
delivery_wait_rln_ready() {
    local node="${1:?delivery_wait_rln_ready <node>}"
    _delivery_rln_ready_loop "$node" _delivery_rln_read_node "$node"
}
_delivery_rln_read_node() { node_call "$1" delivery_module rlnState | jres; }

# Usage: delivery_wait_rln_ready_bc [label]
# The same, over Basecamp's embedded core. Needs basecamp.sh sourced.
delivery_wait_rln_ready_bc() {
    local label="${1:-${BC:-bc}}"
    _delivery_rln_ready_loop "$label" _delivery_rln_read_bc "$label"
}
_delivery_rln_read_bc() { bc_call_on "$1" delivery_module rlnState; }

# ---------------------------------------------------------------------------
# Bring-up around the RLN step. Lifted from scenarios/delivery-rln, which still
# carries its own copies — it is green and porting it is a separate change.
# delivery-rln-soak is the only consumer today.
# ---------------------------------------------------------------------------

# Usage: delivery_registry_id
# The bring-up scope: logos:<target>:<32-byte hex of the base58 config account>.
delivery_registry_id() {
    local hex
    hex=$(python3 -c '
import sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + A.index(c)
print(n.to_bytes(32, "big").hex())
' "$E2E_CONFIG_ACCOUNT") || die "cannot decode config account '${E2E_CONFIG_ACCOUNT:-<unset>}'"
    printf 'logos:%s:%s' "$E2E_TARGET" "$hex"
}

# Usage: delivery_rln_identifier
# ONE identifier for a whole scenario, never one per node: rln_identifier
# scopes the APPLICATION, not the member. It feeds the external nullifier both
# sides derive, so a per-node value makes every message reject with
# validatorRes=Reject — which reads exactly like a product fault.
delivery_rln_identifier() { openssl rand -hex 32; }

# Usage: delivery_rln_evt <plainName>   -> ERE matching both spellings
# The rln request family arrives as dispatchRlnFooRequestEvent on the wire
# while every other delivery event keeps its plain name. Match either until
# that settles, so a rename upstream does not read as a missing proof.
delivery_rln_evt() {
    local n="$1"
    printf '(%s|dispatch%s%sEvent)' "$n" "$(printf '%s' "${n%"${n#?}"}" | tr '[:lower:]' '[:upper:]')" "${n#?}"
}

# Usage: delivery_must_call <node> <method> <label> [args…]
# node_call delivery_module + insist on StdLogosResult success; prints the value.
delivery_must_call() {
    local node="$1" method="$2" label="$3"; shift 3
    local res
    res=$(node_call "$node" delivery_module "$method" "$@" | jres) || res=""
    case "$res" in
        *'"success":true'*) printf '%s' "$res" | jval ;;
        *) die_node "$node" "$label failed: ${res:-<empty>}" ;;
    esac
}

# Usage: delivery_quota <node> <registry> <rlnid> <tag> [unix_seconds]
# The module's epoch budget: {"epoch_index":N,"rate_limit":N,"remaining":N}.
# rate_limit 0 always means "no usable membership", never "exhausted".
delivery_quota() {
    local node="$1" registry="$2" rlnid="$3" tag="$4" ts="${5:-$(date +%s)}"
    node_call "$node" liblogos_rln_module get_epoch_quota \
        "$registry" "$(argfile "q_${tag}" "$rlnid")" "str:$ts" | jres | jval
}

# Usage: delivery_prewarm <node> <start-config-json>
# `start` the RLN module directly. Pre-warms the root window and, because the
# config names registries, kicks off provisioning. Idempotent.
delivery_prewarm() {
    local node="$1" cfg="$2" out
    out=$(node_call "$node" liblogos_rln_module start "$cfg" | jres | jval) || out=""
    case "$out" in
        *'"started":true'*) say "$node: rln module started (${cfg})" ;;
        *) die_node "$node" "rln module start failed: ${out:-<empty>}" ;;
    esac
}

# Usage: delivery_await_provisioned <node> <registry> <rlnid>
# The module registers itself; the harness only funded it. Records leaf + hash
# under sv LEAF/MHASH.
delivery_await_provisioned() {
    local node="$1" registry="$2" rlnid="$3" state_json state bounds _t
    say "$node: waiting for the module to provision a membership (budget ${E2E_CONFIRM_TIMEOUT_S}s)…"
    state=""
    state_json=""
    for _t in $(seq 1 "$(_delivery_polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        state_json=$(node_call "$node" liblogos_rln_module get_membership_state \
            "$registry" "$(argfile "st_$node" "$rlnid")" | jres) || state_json=""
        state=$(printf '%s' "$state_json" | jfield state)
        case "$state" in
            unknown) say "  $node poll $_t: unknown ($(printf '%s' "$state_json" | jfield provisioning))" ;;
            *) say "  $node poll $_t: ${state:-<none>}" ;;
        esac
        case "$state" in
            active|grace_period) break ;;
            failed) die_node "$node" "provisioned registration FAILED on chain: $state_json" ;;
        esac
        # The registry enforces its own rate-limit bounds and the module only
        # says so on stderr — without this, asking for a rate outside them
        # looks like a plain provisioning timeout.
        bounds=$(node_logs "$node" | grep -m1 "outside registry bounds") || bounds=""
        [ -z "$bounds" ] || die_node "$node" "the registry refused the requested rate: ${bounds##*: } \
— pick a rate inside those bounds"
        sleep "$E2E_POLL_INTERVAL_S"
    done
    [ "$state" = "active" ] || [ "$state" = "grace_period" ] \
        || die_node "$node" "the module never provisioned a membership (last state: ${state:-<none>}). \
The harness deliberately does not register — if this times out, provisioning is what failed."
    sv LEAF "$node" "$(printf '%s' "$state_json" | jfield leaf_index)"
    sv MHASH "$node" "$(printf '%s' "$state_json" | jfield membership_hash)"
    say "$node: membership active at leaf $(gv LEAF "$node") — provisioned, not registered by this test"
}

# Usage: delivery_wait_roots_warm <node> <registry> [budget_s]
# A node cannot validate until its registry read path works: those reads go
# through liblogos_lez_rln_module, whose in-process wallet can still be
# churning through a sync. While it is, every validate_proof answers not_ready
# and delivery Ignores the message.
delivery_wait_roots_warm() {
    local node="$1" registry="$2" budget="${3:-${E2E_ROOTS_WARM_BUDGET_S:-300}}" t0 roots
    say "$node: waiting for the registry read path (valid roots; budget ${budget}s)…"
    t0=$(date +%s)
    roots=""
    while :; do
        roots=$(node_call "$node" liblogos_rln_module get_valid_roots "$registry" 2>/dev/null | jres) || roots=""
        case "$roots" in
            *'"valid_roots":["'*) break ;;
        esac
        if [ $(( $(date +%s) - t0 )) -ge "$budget" ]; then
            die_node "$node" "registry read path never warmed in ${budget}s (wallet still syncing?) — last reply: ${roots:-<empty>}"
        fi
        sleep 5
    done
    say "$node: registry read path warm after $(( $(date +%s) - t0 ))s"
}

# Usage: delivery_node_conf <tcp_port> <cluster_id> [static_peer_maddr]
# The conf carries NO rln-* key and no preset name: the scope arrives through
# the presets file, keyed "".
delivery_node_conf() {
    local port="$1" cluster="$2" peers="${3:-}"
    printf '{"logLevel":"INFO","listenAddress":"127.0.0.1","tcpPort":%s,"clusterId":"%s","numShardsInNetwork":1,"relay":true,"store":false,"filter":false,"lightpush":false,"peerExchange":false,"discv5Discovery":false,"reliabilityEnabled":true%s}' \
        "$port" "$cluster" "${peers:+,\"staticnodes\":[\"$peers\"]}"
}

# Usage: delivery_node_up <node> <tcp_port> <cluster_id> [static_peer_maddr] [evt_timeout_s]
# createNode -> wait for RLN -> start. The wait sits between them because
# createNode brings the backend up off its own thread and start fires the
# library's membership gate. Records the dial address under sv MADDR.
delivery_node_up() {
    local node="$1" port="$2" cluster="$3" peers="${4:-}" evt_timeout="${5:-30}" peerid
    delivery_must_call "$node" createNode "createNode" \
        "$(argfile "cfg_$node" "$(delivery_node_conf "$port" "$cluster" "$peers")")" >/dev/null
    delivery_wait_rln_ready "$node"
    delivery_must_call "$node" start "start (dispatch)" >/dev/null
    node_wait_event "$node" delivery_module nodeStarted "$evt_timeout" >/dev/null \
        || die_node "$node" "no nodeStarted within ${evt_timeout}s"
    peerid=$(delivery_must_call "$node" getNodeInfo "getNodeInfo MyPeerId" MyPeerId)
    [ -n "$peerid" ] || die_node "$node" "empty MyPeerId"
    sv MADDR "$node" "/ip4/127.0.0.1/tcp/$port/p2p/$peerid"
    say "$node: delivery up on 127.0.0.1:$port (peer $peerid)"
}
