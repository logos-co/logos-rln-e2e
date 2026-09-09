# shellcheck shell=bash
# harness/lib/daemon.sh — logoscore daemon lifecycle + the node_call seam.
#
# node_call/node_logs have the same signature whether the node is a host
# process (now) or a container (compose topology, P3) — scenarios never know
# the difference. A node id is a name; its state lives in
# $E2E_RUN_DIR/nodes/<node>/{config,daemon.log}, so NODES>1 is a matter of
# calling daemon_start twice.
#
# Sourcing this file REPLACES compat.sh's die with one that first prints the
# tail of $E2E_DIE_NODE's daemon log (set by daemon_start to the first node);
# die_node picks a different node for one call.
#
# Env beyond docs/contract.md:
#   E2E_DAEMON_ENV   extra KEY=VALUE pairs (space-separated) for every daemon
#   E2E_DIE_NODE     node whose log tail die prints
#   E2E_NODES        node ids started so far (daemon_stop_all's list)
#   E2E_WATCHERS     node:module:pid triples of running event watchers

. "$(dirname "${BASH_SOURCE[0]}")/json.sh"

E2E_NODES="${E2E_NODES:-}"
E2E_WATCHERS="${E2E_WATCHERS:-}"

node_cfg_dir() { gv NODECFG "$1"; }
node_log_path() { gv NODELOG "$1"; }

die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    local log
    log=$(node_log_path "${E2E_DIE_NODE:-}")
    if [ -n "$log" ] && [ -f "$log" ]; then
        printf '%s\n' "---- daemon log tail (${E2E_DIE_NODE}) ----" >&2
        tail -40 "$log" >&2 || true
    fi
    exit 1
}

die_node() { local node="$1"; shift; E2E_DIE_NODE="$node"; die "$@"; }

# Usage: daemon_start <node>
daemon_start() {
    local node="${1:?daemon_start <node>}" dir cfg log pid _t
    [ -n "${LOGOSCORE:-}" ] || die "daemon_start: LOGOSCORE unset (resolve_artifacts first)"
    [ -n "${E2E_MODULES_DIR:-}" ] || die "daemon_start: E2E_MODULES_DIR unset (resolve_artifacts first)"
    dir="${E2E_RUN_DIR:?daemon_start: E2E_RUN_DIR unset}/nodes/$node"
    cfg="$dir/config"
    log="$dir/daemon.log"
    mkdir -p "$cfg"
    sv NODECFG "$node" "$cfg"
    sv NODELOG "$node" "$log"
    E2E_NODES="$E2E_NODES $node"
    [ -n "${E2E_DIE_NODE:-}" ] || E2E_DIE_NODE="$node"

    # env -i: Qt strips DYLD_* otherwise, and daemon+client must agree on the
    # effective TMPDIR (QLocalSocket path). LEZ_RLN_TREE_ID_HEX must survive
    # into the daemon: rln_core derives PDAs from it.
    local -a envv
    envv=(HOME="$HOME" PATH="$PATH" LOGOSCORE_CONFIG_DIR="$cfg"
          RUST_BACKTRACE=full QT_QPA_PLATFORM=offscreen)
    if [ -n "${E2E_WALLET_HOME:-}" ]; then
        envv=("${envv[@]}" "NSSA_WALLET_HOME_DIR=$E2E_WALLET_HOME" "LEE_WALLET_HOME_DIR=$E2E_WALLET_HOME")
    fi
    if [ -n "${E2E_TREE_ID:-}" ]; then
        envv=("${envv[@]}" "LEZ_RLN_TREE_ID_HEX=$E2E_TREE_ID")
    fi
    local kv
    for kv in ${E2E_DAEMON_ENV:-}; do envv=("${envv[@]}" "$kv"); done

    say "$node: starting logoscore daemon"
    # exec: $! must be the daemon itself so daemon_stop can kill just this node.
    (cd "$dir" && exec env -i "${envv[@]}" "$LOGOSCORE" -m "$E2E_MODULES_DIR" -D </dev/null >>"$log" 2>&1) &
    pid=$!
    sv NODEPID "$node" "$pid"
    disown "$pid" 2>/dev/null || true

    for _t in $(seq 1 60); do
        [ -f "$cfg/client/config.json" ] && break
        sleep 1
    done
    [ -f "$cfg/client/config.json" ] || die_node "$node" "daemon produced no client config"
    for _t in $(seq 1 60); do
        _with_timeout 5 env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg" "$LOGOSCORE" --quiet --json list-modules 2>/dev/null \
            | grep -q '"capability_module".*"loaded"' && break
        sleep 1
    done
    sleep 5
}

# Usage: daemon_load_modules <node> <module>…
daemon_load_modules() {
    local node="${1:?daemon_load_modules <node> <module>…}"; shift
    [ $# -gt 0 ] || die "daemon_load_modules: no modules given"
    local cfg log mod
    cfg=$(node_cfg_dir "$node")
    log=$(node_log_path "$node")
    [ -n "$cfg" ] || die "daemon_load_modules: unknown node '$node'"
    for mod in "$@"; do
        say "$node: load-module $mod"
        _with_timeout 30 env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg" "$LOGOSCORE" --json load-module "$mod" \
            >>"$log" 2>&1 || die_node "$node" "load-module $mod failed"
    done
}

# Usage: node_call <node> <module> <method> [args…]
node_call() {
    local node="$1"; shift
    local cfg
    cfg=$(node_cfg_dir "$node")
    [ -n "$cfg" ] || die "node_call: unknown node '$node'"
    export E2E_CFG_DIR="$cfg"
    call_json "$@"
}

# Usage: node_watch_start <node> <module>
# Streams the module's events (logoscore watch) into
# nodes/<node>/events-<module>.jsonl until daemon_stop. Start it BEFORE the
# call whose event you'll wait on — the stream only carries events emitted
# after attach.
node_watch_start() {
    local node="${1:?node_watch_start <node> <module>}" mod="${2:?node_watch_start <node> <module>}"
    local cfg evt pid
    cfg=$(node_cfg_dir "$node")
    [ -n "$cfg" ] || die "node_watch_start: unknown node '$node'"
    evt="$(dirname "$(node_log_path "$node")")/events-$mod.jsonl"
    sv NODEEVT "${node}_${mod}" "$evt"
    ( exec env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg" \
        "$LOGOSCORE" --json watch "$mod" >>"$evt" 2>&1 ) &
    pid=$!
    disown "$pid" 2>/dev/null || true
    E2E_WATCHERS="$E2E_WATCHERS $node:$mod:$pid"
    say "$node: watching $mod events -> $(basename "$evt")"
}

# Usage: node_wait_event <node> <module> <event> [timeout_s] [substring]
# Prints the first matching event line (compact JSON: {"event":...,"data":
# {"arg0":...}}) or returns 1 on timeout. substring is a fixed-string filter
# over the raw line (e.g. a requestId or topic).
node_wait_event() {
    local node="$1" mod="$2" ev="$3" timeout="${4:-30}" match="${5:-}" evt _t
    evt=$(gv NODEEVT "${node}_${mod}")
    [ -n "$evt" ] || die "node_wait_event: no watcher for $node/$mod (node_watch_start first)"
    for _t in $(seq 1 "$timeout"); do
        python3 - "$evt" "$ev" "$match" <<'EOF' && return 0
import json, sys
path, ev, match = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path)
except OSError:
    sys.exit(1)
for line in lines:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("event") != ev:
        continue
    if match and match not in line:
        continue
    print(json.dumps(d, separators=(",", ":")))
    sys.exit(0)
sys.exit(1)
EOF
        sleep 1
    done
    return 1
}

_watchers_stop() {
    # Usage: _watchers_stop <node|''>  ('' = all)
    local node="$1" w rest
    rest=""
    for w in $E2E_WATCHERS; do
        case "$w" in
            ${node:-*}:*) kill "${w##*:}" 2>/dev/null || true ;;
            *) rest="$rest $w" ;;
        esac
    done
    E2E_WATCHERS="$rest"
}

# Usage: node_logs <node> [lines]   (whole log when lines is omitted)
node_logs() {
    local node="$1" lines="${2:-}" log
    log=$(node_log_path "$node")
    [ -n "$log" ] && [ -f "$log" ] || return 1
    if [ -n "$lines" ]; then tail -n "$lines" "$log"; else cat "$log"; fi
}

daemon_stop() {
    local node="$1" pid
    _watchers_stop "$node"
    pid=$(gv NODEPID "$node")
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    sv NODEPID "$node" ""
}

# Usage: daemon_stop_wait <node> [timeout_s=30]
# daemon_stop, then wait for the process to actually exit. SIGTERM is
# asynchronous: anything that must observe the daemon's resources released
# (the RLN module's exclusive keystore lock, ports) needs this, not a bare
# daemon_stop.
daemon_stop_wait() {
    local node="${1:?daemon_stop_wait <node>}" timeout="${2:-30}" pid _t
    pid=$(gv NODEPID "$node")
    daemon_stop "$node"
    [ -n "$pid" ] || return 0
    for _t in $(seq 1 "$timeout"); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    die_node "$node" "daemon $pid did not exit within ${timeout}s of SIGTERM"
}

# Usage: daemon_restart <node>
# Stop the daemon (waiting for real exit) and start a fresh one over the
# SAME state dir — the restart/persistence probe primitive. Module loading
# is per-daemon-lifetime: the caller re-runs daemon_load_modules (and any
# node_watch_start) itself.
daemon_restart() {
    local node="${1:?daemon_restart <node>}"
    daemon_stop_wait "$node"
    daemon_start "$node"
}

daemon_stop_all() {
    local node
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving daemons up, state in ${E2E_RUN_DIR:-<none>}"
        return
    fi
    for node in $E2E_NODES; do daemon_stop "$node"; done
    # The run's modules dir is unique per run, so this cannot reach another
    # run's daemons.
    [ -n "${E2E_MODULES_DIR:-}" ] && pkill -f "logoscore -m $E2E_MODULES_DIR" 2>/dev/null
    return 0
}
