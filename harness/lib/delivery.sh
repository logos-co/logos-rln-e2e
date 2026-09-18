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
