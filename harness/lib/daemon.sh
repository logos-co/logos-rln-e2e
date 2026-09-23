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
#
# A node is a host process by default. daemon_register_container makes one a
# CONTAINER instead, and node_call/node_logs/daemon_load_modules/daemon_stop
# dispatch on that — which is the seam docs/contract.md already promises:
# "identical whether the node is a host process or a container".

. "$(dirname "${BASH_SOURCE[0]}")/json.sh"

E2E_NODES="${E2E_NODES:-}"
E2E_WATCHERS="${E2E_WATCHERS:-}"

node_cfg_dir() { gv NODECFG "$1"; }
node_log_path() { gv NODELOG "$1"; }
node_kind()      { local k; k=$(gv NODEKIND "$1"); printf '%s' "${k:-host}"; }
node_container() { gv NODECONT "$1"; }

# The wallet home a node's registry module opens. Since
# liblogos_lez_rln_module 3.0.0 that module owns its wallet in-process, so two
# nodes sharing one home are two writers of one storage.json — the corruption
# case the in-process wallet exists to prevent. Unset falls back to the staged
# $E2E_WALLET_HOME, which is correct only while exactly one node runs.
node_wallet_home() { local h; h=$(gv NODEWALL "$1"); printf '%s' "${h:-${E2E_WALLET_HOME:-}}"; }

# Whether <node> runs its own wallet and pays from an account it derived.
node_self_paying() { local v; v=$(gv NODESELFPAY "$1"); printf '%s' "${v:-0}"; }

# Usage: wallet_home_fresh <dir>
# Build a wallet home carrying the staged wallet_config.json and nothing else,
# so the registry module creates a fresh wallet there and derives a payer only
# that instance holds.
#
# Deliberately not a copy of the staged storage.json: derivation is
# deterministic from the seed, so every instance copying one wallet derives the
# SAME account id, and "its own payer" would be a fiction. Withholding the
# storage is what makes the seeds differ.
#
# It lives here rather than in wallet.sh because both callers must see it and
# wallet.sh sources this file, not the other way round. The second caller is
# Basecamp, which embeds logos-core and has no node to key anything on.
wallet_home_fresh() {
    local dir="${1:?wallet_home_fresh <dir>}"
    [ -n "${E2E_WALLET_HOME:-}" ] || die "wallet_home_fresh: no staged wallet home to copy a config from"
    rm -rf "$dir"
    mkdir -p "$dir" || die "wallet_home_fresh: cannot create $dir"
    cp "$E2E_WALLET_HOME/wallet_config.json" "$dir/" \
        || die "wallet_home_fresh: cannot copy wallet_config.json to $dir"
}

# Usage: daemon_self_paying <node> <dir>
# Give <node> a wallet of its OWN, and record that it pays for itself —
# wallet_fund refuses any node that does not.
#
# Must precede daemon_start, like daemon_wallet_home, and it implies it.
daemon_self_paying() {
    local node="${1:?daemon_self_paying <node> <dir>}" dir="${2:?wallet home dir}"
    wallet_home_fresh "$dir"
    sv NODESELFPAY "$node" 1
    daemon_wallet_home "$node" "$dir"
}

# Usage: daemon_wallet_home <node> <dir>
# Give <node> its own wallet home. MUST be called before daemon_start: the
# home reaches the module as an env var on the daemon's own command line, and
# nothing re-reads it afterwards.
daemon_wallet_home() {
    local node="${1:?daemon_wallet_home <node> <dir>}" dir="${2:?wallet home dir}"
    [ -z "$(gv NODEPID "$node")" ] \
        || die "daemon_wallet_home: $node is already running — set its home before daemon_start"
    sv NODEWALL "$node" "$dir"
}

# Usage: daemon_register_container <node> <container> <config-dir>
# Adopt an already-running container as <node>. The caller owns its lifetime
# up to daemon_stop; everything else addresses it exactly like a host node.
daemon_register_container() {
    local node="${1:?daemon_register_container <node> <container> <cfgdir>}"
    local cont="${2:?container}" cfg="${3:?config dir}"
    sv NODEKIND "$node" docker
    sv NODECONT "$node" "$cont"
    sv NODECFG "$node" "$cfg"
    E2E_NODES="$E2E_NODES $node"
    [ -n "${E2E_DIE_NODE:-}" ] || E2E_DIE_NODE="$node"
}

die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ -n "${E2E_DIE_NODE:-}" ]; then
        local tail_out
        tail_out=$(node_logs "$E2E_DIE_NODE" 40 2>/dev/null) || tail_out=""
        if [ -n "$tail_out" ]; then
            printf '%s\n' "---- daemon log tail (${E2E_DIE_NODE}) ----" >&2
            printf '%s\n' "$tail_out" >&2
        fi
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
    local home
    home=$(node_wallet_home "$node")
    if [ -n "$home" ]; then
        envv=("${envv[@]}" "NSSA_WALLET_HOME_DIR=$home" "LEE_WALLET_HOME_DIR=$home")
    fi
    if [ -n "${E2E_TREE_ID:-}" ]; then
        envv=("${envv[@]}" "LEZ_RLN_TREE_ID_HEX=$E2E_TREE_ID")
    fi
    # The account this node signs and pays with. Registration is single-asset,
    # so one account signs the Register, pays the registry price from its
    # native balance and pays the fee; without one every send is refused with
    # a bare "Incorrect fee".
    #
    # A node registered as self-paying gets NO LEZ_RLN_PAYER: the module then
    # derives its own account, publishes it through wallet_status, and waits
    # for something to fund it. Handing it the deployment's shared payer
    # instead would work, and would also mean every node spent one account's
    # balance and raced one account's nonce — which is the thing per-node
    # wallets exist to stop.
    if [ "$(gv NODESELFPAY "$node")" != 1 ] && [ -n "${E2E_PAYER:-}" ]; then
        envv=("${envv[@]}" "LEZ_RLN_PAYER=$E2E_PAYER")
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
        if [ "$(node_kind "$node")" = docker ]; then
            _with_timeout 60 docker exec -e LOGOSCORE_CONFIG_DIR="$cfg" \
                "$(node_container "$node")" logoscore --json load-module "$mod" \
                >/dev/null 2>&1 || die_node "$node" "load-module $mod failed"
        else
            _with_timeout 30 env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg" "$LOGOSCORE" --json load-module "$mod" \
                >>"$log" 2>&1 || die_node "$node" "load-module $mod failed"
        fi
    done
}

# Usage: node_call <node> <module> <method> [args…]
node_call() {
    local node="$1"; shift
    local cfg
    cfg=$(node_cfg_dir "$node")
    [ -n "$cfg" ] || die "node_call: unknown node '$node'"
    if [ "$(node_kind "$node")" = docker ]; then
        # The config dir rides an env var rather than --config-dir so the
        # argument list is identical to the host path. argfile's @/abs/path
        # references resolve because the run dir is bind-mounted at the same
        # absolute path inside (see relay.sh).
        _with_timeout "${CALL_TIMEOUT:-180}" docker exec -e LOGOSCORE_CONFIG_DIR="$cfg" \
            "$(node_container "$node")" logoscore --json call "$@" 2>/dev/null
        return
    fi
    export E2E_CFG_DIR="$cfg"
    call_json "$@"
}

# Usage: node_watch_start <node> <module>
# Streams the module's events (logoscore watch) into
# nodes/<node>/events-<module>.<gen>.jsonl until node_watch_stop or
# daemon_stop. Start it BEFORE the call whose event you'll wait on — the
# stream only carries events emitted after attach.
#
# Each attach takes a fresh generation, so the stream file and the read
# cursors node_wait_event keeps are new: a re-attach never inherits the
# previous watcher's position or its backlog.
node_watch_start() {
    local node="${1:?node_watch_start <node> <module>}" mod="${2:?node_watch_start <node> <module>}"
    local cfg evt pid gen live
    cfg=$(node_cfg_dir "$node")
    [ -n "$cfg" ] || die "node_watch_start: unknown node '$node'"
    # A container node's daemon is not reachable from the host binary, and its
    # config dir is a path inside the container: watching it produces an empty
    # stream and every wait on it times out looking like a missing event.
    # Refuse instead — watch the host peers, and read the container's own log
    # (node_logs) for what it did.
    [ "$(node_kind "$node")" != docker ] \
        || die "node_watch_start: $node is a container — events are only watchable on host nodes"
    # A second watcher on one node:module would append to the same stream and
    # double every line. daemon_stop clears the bookkeeping, so a re-attach
    # after a restart is fine; this only catches a genuine double-start.
    live=$(gv NODEEVT "${node}_${mod}")
    [ -z "$live" ] || die "node_watch_start: $node/$mod is already watched (node_watch_stop first)"
    gen=$(gv NODEEVTGEN "${node}_${mod}"); [ -n "$gen" ] || gen=0
    gen=$(( gen + 1 ))
    sv NODEEVTGEN "${node}_${mod}" "$gen"
    evt="$(dirname "$(node_log_path "$node")")/events-$mod.$gen.jsonl"
    : > "$evt"
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
#
# <event> is matched as an ANCHORED regex, so a plain name still matches only
# itself while a caller facing two spellings of one event can pass an
# alternation instead of waiting twice.
#
# A match consumes it: the read cursor for this (node, module, event) advances
# past the line returned, so a second wait for the same event waits for the
# NEXT one instead of re-matching the first. Without that, an event from an
# earlier phase silently satisfies a later wait and the test passes for the
# wrong reason. Cursors are per event name, so waiting for one event never
# skips another's backlog, and an event that arrived before the wait started
# still matches — that race is deliberate.
node_wait_event() {
    local node="$1" mod="$2" ev="$3" timeout="${4:-30}" match="${5:-}" evt key pos out _t
    # An empty pattern matches NOTHING, so the wait burns its whole budget and
    # reports the event as missing — which reads as a product fault. The usual
    # cause is a helper that produced the pattern not being sourced: a command
    # substitution for a missing function is empty, and nothing else complains.
    [ -n "$ev" ] || die "node_wait_event: empty event pattern for $node/$mod \
(a helper that builds it is probably not sourced)"
    evt=$(gv NODEEVT "${node}_${mod}")
    [ -n "$evt" ] || die "node_wait_event: no watcher for $node/$mod (node_watch_start first)"
    key="${node}_${mod}_$(gv NODEEVTGEN "${node}_${mod}")_$(printf '%s' "$ev" | tr -c '[:alnum:]' '_')"
    for _t in $(seq 1 "$timeout"); do
        pos=$(gv NODEEVTPOS "$key"); [ -n "$pos" ] || pos=0
        out=$(python3 - "$evt" "$ev" "$match" "$pos" <<'EOF'
import json, re, sys
path, ev, match, pos = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    f = open(path, "rb")
except OSError:
    sys.exit(1)
f.seek(pos)
while True:
    raw = f.readline()
    # A line without its newline is one the watcher is still writing; leave the
    # cursor where it is and re-read it on the next poll.
    if not raw or not raw.endswith(b"\n"):
        break
    line = raw.decode("utf-8", "replace").strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not re.fullmatch(ev, d.get("event") or ""):
        continue
    if match and match not in line:
        continue
    print(f.tell())
    print(json.dumps(d, separators=(",", ":")))
    sys.exit(0)
sys.exit(1)
EOF
        ) || out=""
        if [ -n "$out" ]; then
            sv NODEEVTPOS "$key" "$(printf '%s' "$out" | head -1)"
            printf '%s' "$(printf '%s' "$out" | tail -n +2)"
            return 0
        fi
        sleep 1
    done
    return 1
}

# Usage: node_watch_stop <node> <module>
# Stop one watcher and forget it, so a later node_wait_event on it dies
# loudly instead of polling a file nobody writes.
node_watch_stop() {
    local node="${1:?node_watch_stop <node> <module>}" mod="${2:?node_watch_stop <node> <module>}"
    _watchers_stop "$node" "$mod"
}

# Usage: _watchers_stop <node|''> [module|'']   ('' = every node / every module)
# Kills the matching watchers and clears their bookkeeping. Clearing NODEEVT is
# the point: it is what turns "waiting on a dead watcher" from a silent timeout
# into an immediate, named failure.
_watchers_stop() {
    local node="$1" mod="${2:-}" w rest wnode wmod
    rest=""
    for w in $E2E_WATCHERS; do
        wnode="${w%%:*}"; wmod="${w#*:}"; wmod="${wmod%:*}"
        if { [ -z "$node" ] || [ "$wnode" = "$node" ]; } \
            && { [ -z "$mod" ] || [ "$wmod" = "$mod" ]; }; then
            kill "${w##*:}" 2>/dev/null || true
            sv NODEEVT "${wnode}_${wmod}" ""
        else
            rest="$rest $w"
        fi
    done
    E2E_WATCHERS="$rest"
}

# Usage: node_logs <node> [lines]   (whole log when lines is omitted)
node_logs() {
    local node="$1" lines="${2:-}" log
    if [ "$(node_kind "$node")" = docker ]; then
        if [ -n "$lines" ]; then docker logs --tail "$lines" "$(node_container "$node")" 2>&1
        else docker logs "$(node_container "$node")" 2>&1; fi
        return
    fi
    log=$(node_log_path "$node")
    [ -n "$log" ] && [ -f "$log" ] || return 1
    if [ -n "$lines" ]; then tail -n "$lines" "$log"; else cat "$log"; fi
}

daemon_stop() {
    local node="$1" pid
    _watchers_stop "$node"
    if [ "$(node_kind "$node")" = docker ]; then
        if [ "${E2E_KEEP:-0}" = "1" ]; then
            say "E2E_KEEP=1: leaving container $(node_container "$node") up"
        else
            docker rm -f "$(node_container "$node")" >/dev/null 2>&1 || true
        fi
        sv NODEKIND "$node" ""
        return 0
    fi
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
    # Watchers go regardless of E2E_KEEP: they are disowned, so nothing else
    # ever reaps them (the pkill below matches the DAEMON command line,
    # `logoscore -m <dir>`, never a watcher's `logoscore --json watch <mod>`).
    # E2E_KEEP means inspectable daemons, not orphaned watch processes.
    _watchers_stop ""
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
