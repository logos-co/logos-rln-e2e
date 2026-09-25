# shellcheck shell=bash
# harness/lib/fault.sh — degrade ONE node's chain RPC, on purpose.
#
# Scenarios that want to know how a node behaves against a hosted testnet's
# bad days (an RPC that refuses, stalls or answers slowly) run a fault proxy
# between that node's wallet and the sequencer, and flip its mode mid-run.
#
# The point of proxying one node rather than the endpoint is that the harness
# keeps its own sight: chain_head and every provisioning helper still dial
# $E2E_SEQUENCER directly, so the scenario can observe the chain during an
# outage it induced. Nothing here touches the sequencer itself.
#
# Usage, in order:
#   fault_up                      start the proxy (sets E2E_FAULT_URL)
#   fault_point_node <node>       point that node's wallet at it, before
#                                 daemon_start and after daemon_self_paying
#   fault_mode refuse             ... and any time later, to change the fault
#   fault_mode blackhole '*send*' scope a fault to matching JSON-RPC methods
#   fault_mode pass               lift it
#   fault_down                    stop the proxy (idempotent)
#
# Modes are faultproxy.py's: pass | refuse | blackhole | delay:<ms> | error5xx.
#
# Env beyond docs/contract.md:
#   E2E_FAULT_PORT=3141   port the proxy listens on
#   E2E_FAULT_UPSTREAM    sequencer it forwards to (default $E2E_SEQUENCER)

. "$(dirname "${BASH_SOURCE[0]}")/chain.sh"

E2E_FAULT_PORT="${E2E_FAULT_PORT:-3141}"
_FAULT_PID=""
_FAULT_CTL=""
_FAULT_TRACE=""
_FAULT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Start the proxy and wait until it answers a real chain read through it.
# Readiness is a proxied getLastBlockId, not a port probe: the listener accepts
# before its upstream is known good, and a scenario that pointed a node at a
# proxy which cannot reach the chain would read as a module bug.
fault_up() {
    local upstream="${1:-${E2E_FAULT_UPSTREAM:-${E2E_SEQUENCER:?fault_up: E2E_SEQUENCER unset}}}"
    local dir log _t
    [ -n "$_FAULT_PID" ] && die "fault_up: a proxy is already running (pid $_FAULT_PID)"
    dir="${E2E_RUN_DIR:?fault_up: E2E_RUN_DIR unset}/fault"
    mkdir -p "$dir" || die "fault_up: cannot create $dir"
    _FAULT_CTL="$dir/mode"
    _FAULT_TRACE="$dir/trace.log"
    log="$dir/proxy.log"
    printf 'pass\n' > "$_FAULT_CTL" || die "fault_up: cannot write $_FAULT_CTL"
    : > "$_FAULT_TRACE"

    E2E_FAULT_URL="http://127.0.0.1:$E2E_FAULT_PORT/"
    python3 "$_FAULT_HERE/tools/faultproxy.py" \
        --listen "127.0.0.1:$E2E_FAULT_PORT" \
        --upstream "$upstream" \
        --control "$_FAULT_CTL" \
        --trace "$_FAULT_TRACE" >>"$log" 2>&1 &
    _FAULT_PID=$!
    disown "$_FAULT_PID" 2>/dev/null || true

    for _t in $(seq 1 20); do
        # Liveness FIRST. If the port was already taken the proxy has exited on
        # a bind error, and a probe would be answered by whatever is squatting
        # there — which is worse than no proxy at all: the scenario would point
        # a node at a stranger and every assertion after it would be vacuous.
        if ! kill -0 "$_FAULT_PID" 2>/dev/null; then
            [ -f "$log" ] && tail -20 "$log" >&2
            die "fault_up: the proxy exited at once — is something already listening on port $E2E_FAULT_PORT? (lsof -nP -iTCP:$E2E_FAULT_PORT -sTCP:LISTEN). See $log"
        fi
        # Readiness is a real chain read AND that read appearing in OUR trace.
        # The second half is what proves the answer came through this proxy and
        # not from something else on the port.
        if chain_head "$E2E_FAULT_URL" >/dev/null 2>&1 \
            && [ "$(fault_trace_count)" -gt 0 ]; then
            say "fault proxy up: $E2E_FAULT_URL -> $upstream (pid $_FAULT_PID)"
            export E2E_FAULT_URL
            return 0
        fi
        sleep 1
    done
    [ -f "$log" ] && tail -20 "$log" >&2
    die "fault_up: the proxy never served a chain read of its own at $E2E_FAULT_URL — see $log"
}

# Usage: fault_mode <mode> [method-glob]
# Takes effect on the next request the proxy receives; nothing is restarted.
fault_mode() {
    local mode="${1:?fault_mode <mode> [method-glob]}" glob="${2:-}"
    [ -n "$_FAULT_CTL" ] || die "fault_mode: no proxy (call fault_up first)"
    if [ -n "$glob" ]; then
        printf '%s %s\n' "$mode" "$glob" > "$_FAULT_CTL"
        say "fault mode: $mode (methods matching '$glob')"
    else
        printf '%s\n' "$mode" > "$_FAULT_CTL"
        say "fault mode: $mode"
    fi
}

# Path to the request trace, for a scenario that wants to assert on it.
fault_trace_path() { printf '%s' "$_FAULT_TRACE"; }

# Usage: fault_trace_count [method]
# How many requests the proxy has seen, optionally for one method — the
# RPC-amplification measure a scenario can record per phase.
fault_trace_count() {
    local method="${1:-}"
    [ -f "$_FAULT_TRACE" ] || { printf '0'; return 0; }
    if [ -n "$method" ]; then
        awk -v m="$method" '$2 == m {n++} END {printf "%d", n+0}' "$_FAULT_TRACE"
    else
        awk 'END {printf "%d", NR+0}' "$_FAULT_TRACE"
    fi
}

# Usage: fault_point_node <node>
# Rewrite that node's wallet config to dial the proxy. MUST run after the home
# exists (daemon_self_paying / daemon_wallet_home) and before daemon_start.
#
# The config is what decides this, not the environment: the module will not
# re-point an existing wallet_config.json from LEZ_RLN_SEQUENCER, so a node
# left alone dials whatever the staged config named and the fault never lands.
fault_point_node() {
    local node="${1:?fault_point_node <node>}" home
    [ -n "${E2E_FAULT_URL:-}" ] || die "fault_point_node: no proxy (call fault_up first)"
    home=$(node_wallet_home "$node")
    [ -n "$home" ] \
        || die_node "$node" "fault_point_node needs a node with its own wallet home — call daemon_self_paying first"
    [ -f "$home/wallet_config.json" ] \
        || die_node "$node" "fault_point_node: no wallet_config.json in $home"
    python3 - "$home/wallet_config.json" "$E2E_FAULT_URL" <<'EOF' \
        || die_node "$node" "fault_point_node: cannot point the wallet config at $E2E_FAULT_URL"
import json, sys
path, seq = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["sequencer_addr"] = seq
for entry in cfg.get("sequencers", []):
    entry["sequencer_addr"] = seq
json.dump(cfg, open(path, "w"), indent=2)
EOF
    say "$node: wallet points at the fault proxy ($E2E_FAULT_URL)"
}

fault_down() {
    [ -n "$_FAULT_PID" ] || return 0
    say "stopping fault proxy (pid $_FAULT_PID)"
    kill -TERM "$_FAULT_PID" 2>/dev/null || true
    # Blackholed requests hold their threads; the interpreter goes down with
    # SIGTERM, so nothing needs draining first.
    _FAULT_PID=""
}
