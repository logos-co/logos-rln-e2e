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

. "$(dirname "${BASH_SOURCE[0]}")/json.sh"

E2E_NODES="${E2E_NODES:-}"

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

# Usage: node_logs <node> [lines]   (whole log when lines is omitted)
node_logs() {
    local node="$1" lines="${2:-}" log
    log=$(node_log_path "$node")
    [ -n "$log" ] && [ -f "$log" ] || return 1
    if [ -n "$lines" ]; then tail -n "$lines" "$log"; else cat "$log"; fi
}

daemon_stop() {
    local node="$1" pid
    pid=$(gv NODEPID "$node")
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    sv NODEPID "$node" ""
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
