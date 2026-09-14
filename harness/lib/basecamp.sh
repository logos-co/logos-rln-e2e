#!/usr/bin/env bash
# harness/lib/basecamp.sh — drive a headless Basecamp (the desktop app with
# an EMBEDDED logos-core) from a scenario.
#
# Basecamp has no logoscore CLI seam: node_call/node_wait_event do not apply
# to modules it hosts. What it has is the QML inspector (dev #app build,
# TCP on QML_INSPECTOR_PORT) whose `evaluate` command runs a QML/JS
# expression in the main widget's context and RETURNS the result — and that
# context carries `backend` (MainUIBackend), which exposes
#   backend.loadCoreModule(name)                        (public slot)
#   backend.callCoreModuleMethod(mod, method, argsJson) (Q_INVOKABLE)
# so every module call a scenario needs is one evaluate away. (The
# inspector's own call_method DISCARDS return values — never use it.)
#
# callCoreModuleMethod wraps each reply as {"result": <value>}; Qt parses a
# JSON-shaped module reply into an object, so the driver unwraps that layer
# and re-emits objects COMPACT — substring asserts ("started":true) then
# match the module's own wire spelling.
#
# Hard-won constraints (each cost a run):
#   - Only the NON-portable #app build appends the `-dev` variant liblogos
#     discovery needs for the harness-built .lgx bundles; a portable bundle
#     silently loads zero side-loaded modules.
#   - The wallet answers NO reads while sync_to_block runs, and the app-side
#     call times out at 20s regardless of how far the chunk got: a timed-out
#     probe means BUSY (wait, never re-issue — re-issuing restarts the chunk),
#     an answered-but-unchanged height means IDLE (re-issue the chunk).
#   - This wallet build keeps checkpoints, not a sync cursor: a fresh session
#     syncs from ~0 (≈25 min on the hosted testnet).
#
# Requires: compat.sh (say/die), chain.sh (chain_head), json.sh; the caller's
# die() may call basecamp_die_tails for diagnostics.
#
# Globals set: BASECAMP_PID, BC_UD (user-dir), BC_INSPECTOR_PORT.

BC_INSPECTOR_PORT="${E2E_INSPECTOR_PORT:-3768}"
BC_SETTLE_S="${E2E_BASECAMP_SETTLE_S:-20}"
BASECAMP_PID=""
BC_UD=""

# Fail fast if another Basecamp already owns the inspector port.
basecamp_port_check() {
    if command -v nc >/dev/null && nc -z 127.0.0.1 "$BC_INSPECTOR_PORT" 2>/dev/null; then
        die "inspector port $BC_INSPECTOR_PORT is already in use (a running Basecamp?) — set E2E_INSPECTOR_PORT"
    fi
}

# The inspector client: one command per invocation, newline-JSON over TCP.
_basecamp_write_driver() {
    BC_INSP="$E2E_RUN_DIR/insp.py"
    cat >"$BC_INSP" <<'PYEOF'
#!/usr/bin/env python3
# Minimal QML-inspector client (newline-delimited JSON over TCP), one
# command per invocation:
#   insp.py <port> eval                 <<<'<js expression>'
#   insp.py <port> call <mod> <method>  <<<'<argsJson>'
# call = backend.callCoreModuleMethod(mod, method, argsJson) via `evaluate`
# — the result-RETURNING inspector path (its call_method discards returns).
import json, socket, sys

port, mode = int(sys.argv[1]), sys.argv[2]
stdin = sys.stdin.read()
if mode == "eval":
    expr = stdin
else:
    args = stdin.strip() or "[]"
    expr = "backend.callCoreModuleMethod(%s, %s, %s)" % (
        json.dumps(sys.argv[3]), json.dumps(sys.argv[4]), json.dumps(args))
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=20)
except OSError as e:
    sys.stderr.write("insp: connect failed: %s\n" % e)
    sys.exit(2)
s.settimeout(90)
f = s.makefile("rwb")
f.write((json.dumps({"id": 1, "command": "evaluate",
                     "params": {"expression": expr}}) + "\n").encode())
f.flush()
for _ in range(200):
    line = f.readline()
    if not line:
        break
    try:
        d = json.loads(line.decode())
    except Exception:
        continue
    if d.get("id") != 1:
        continue
    r = d.get("result", d)
    # callCoreModuleMethod returns a QString wrapping the module's reply as
    # {"result": <variantToJsonValue(result)>} (CoreModuleManager.cpp) —
    # unwrap that one layer so a tstr reply prints as the module's own
    # JSON, an int as an int; its {"error": ...} shape stays visible.
    if isinstance(r, str) and r[:1] == "{":
        try:
            inner = json.loads(r)
            if isinstance(inner, dict) and set(inner) == {"result"}:
                r = inner["result"]
        except Exception:
            pass
    if isinstance(r, bool):
        r = "true" if r else "false"
    elif isinstance(r, (dict, list)):
        # Qt parses a JSON-shaped module reply into an object; re-emit it
        # COMPACT so the shell's substring asserts match the wire spelling.
        r = json.dumps(r, separators=(",", ":"))
    print(r if r is not None else "")
    sys.exit(0)
sys.stderr.write("insp: no reply for: %s\n" % expr[:200])
sys.exit(1)
PYEOF
}

# bc_eval <js-expression>            -> prints the evaluate result
# bc_call <module> <method> [argsJson] -> prints the module reply (unwrapped)
bc_eval() { printf '%s' "$1" | python3 "$BC_INSP" "$BC_INSPECTOR_PORT" eval 2>>"$E2E_RUN_DIR/inspector.log"; }
bc_call() { printf '%s' "${3:-[]}" | python3 "$BC_INSP" "$BC_INSPECTOR_PORT" call "$1" "$2" 2>>"$E2E_RUN_DIR/inspector.log"; }

# Strict integer parse of a reply — an error JSON carries digits too (a
# timed-out call's code), never mistake those for a block height.
bc_int() { python3 -c '
import json, sys
r = sys.stdin.read().strip()
try:
    d = json.loads(r)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    d = d.get("value")
if isinstance(d, int) and not isinstance(d, bool):
    print(d)
'; }
bc_synced() { bc_call lez_core get_last_synced_block | bc_int; }

# basecamp_launch <user-dir> <wallet-home> <chat-delivery-conf-json>
# Stages the harness modules dir into <user-dir>/modules, launches the app
# headless with the wallet + RLN env the module stack expects, waits for the
# inspector, settles, and gates on the `backend` context property.
# Extra KEY=VALUE env pairs may follow as further arguments.
basecamp_launch() {
    local ud="$1" whome="$2" conf="$3"; shift 3
    [ -n "${BASECAMP_APP:-}" ] && [ -x "$BASECAMP_APP" ] \
        || die "basecamp_launch: BASECAMP_APP not set/executable (NEEDS_APPS=basecamp?)"
    BC_UD="$ud"
    mkdir -p "$ud/modules"
    cp -R "$E2E_MODULES_DIR/." "$ud/modules/" || die "cannot stage modules into $ud"
    say "staged $(ls "$ud/modules" | tr '\n' ' ')into basecamp user-dir"
    _basecamp_write_driver
    env QT_QPA_PLATFORM=offscreen \
        QML_INSPECTOR_PORT="$BC_INSPECTOR_PORT" \
        NSSA_WALLET_HOME_DIR="$whome" \
        LEE_WALLET_HOME_DIR="$whome" \
        LEZ_RLN_TREE_ID_HEX="$E2E_TREE_ID" \
        CHAT_DELIVERY_CONF_OVERRIDE="$conf" \
        "$@" \
        "$BASECAMP_APP" --user-dir "$ud" -platform offscreen \
        >"$E2E_RUN_DIR/basecamp.log" 2>&1 &
    BASECAMP_PID=$!
    say "basecamp launched (pid $BASECAMP_PID, inspector :$BC_INSPECTOR_PORT)"

    local _t tb
    for _t in $(seq 1 60); do
        kill -0 "$BASECAMP_PID" 2>/dev/null || die "basecamp exited during startup"
        if python3 -c "import socket;socket.create_connection(('127.0.0.1',$BC_INSPECTOR_PORT),timeout=1).close()" 2>/dev/null; then
            break
        fi
        [ "$_t" = 60 ] && die "inspector port never opened (60s)"
        sleep 1
    done
    say "inspector reachable — settling ${BC_SETTLE_S}s (headless dependency resolution)"
    sleep "$BC_SETTLE_S"
    for _t in $(seq 1 30); do
        tb=$(bc_eval "typeof backend") || tb=""
        [ "$tb" = "object" ] && break
        [ "$_t" = 30 ] && die "backend context property never appeared (got '$tb')"
        sleep 2
    done
    say "backend reachable through evaluate"
}

# basecamp_load_modules <module>... — loadCoreModule each, in order, and
# wait until it answers introspection (getCoreModuleMethods != "[]").
basecamp_load_modules() {
    local m ready _t methods
    for m in "$@"; do
        bc_eval "backend.loadCoreModule('$m')" >/dev/null
        ready=""
        for _t in $(seq 1 45); do
            methods=$(bc_eval "backend.getCoreModuleMethods('$m')") || methods=""
            case "$methods" in
                ""|"[]") sleep 2 ;;
                *) ready=1; break ;;
            esac
        done
        [ -n "$ready" ] || die "basecamp: module $m never became callable"
        say "basecamp: $m loaded"
    done
}

# basecamp_wallet_open_sync <wallet-home>
# Waits until the registry module's own wallet is open and caught up on the
# given home (seeding storage.json from storage.json.seed when absent — the
# module needs a storage file to adopt). Prints nothing; dies on failure.
basecamp_wallet_open_sync() {
    local home="$1" st _t tries iv
    [ -f "$home/wallet_config.json" ] || die "basecamp wallet: no wallet_config.json in $home"
    # The module opens this home itself and would find nothing to open without
    # a storage file; seeding stays here because it has to happen before the
    # app starts, not after.
    if [ ! -f "$home/storage.json" ]; then
        cp "$home/storage.json.seed" "$home/storage.json" \
            || die "basecamp wallet: cannot seed $home/storage.json"
    fi

    # Since liblogos_lez_rln_module 3.0.0 the module owns its wallet: it adopts
    # the home LEE_WALLET_HOME_DIR names and syncs it on its own thread at
    # load. Opening lez_core on that same storage.json would make two writers
    # of one file, so the app is never asked to — it is asked whether the
    # module is ready.
    iv="${E2E_POLL_INTERVAL_S:-5}"
    tries=$(( ${E2E_WALLET_READY_S:-600} / iv ))
    [ "$tries" -lt 1 ] && tries=1
    for _t in $(seq 1 "$tries"); do
        st=$(bc_call liblogos_lez_rln_module wallet_status) || st=""
        case "$st" in
            *'"state":"ready"'*) say "basecamp wallet ready"; return 0 ;;
            ''|*'"state":"pending"'*) sleep "$iv" ;;
            *) die "basecamp registry wallet failed to come up: $st" ;;
        esac
    done
    die "basecamp registry wallet never became ready (last: ${st:-<empty>})"
}

# Diagnostics for a scenario's die(): app stderr, the newest session log
# under the user-dir, the inspector driver log.
basecamp_die_tails() {
    local blog
    if [ -s "$E2E_RUN_DIR/basecamp.log" ]; then
        echo "---- basecamp log tail ----" >&2
        tail -25 "$E2E_RUN_DIR/basecamp.log" >&2 || true
    fi
    blog=$(ls -t "$BC_UD/logs" 2>/dev/null | head -1)
    if [ -n "$blog" ]; then
        echo "---- basecamp session log tail ($blog) ----" >&2
        tail -25 "$BC_UD/logs/$blog" >&2 || true
    fi
    if [ -s "$E2E_RUN_DIR/inspector.log" ]; then
        echo "---- inspector driver log tail ----" >&2
        tail -10 "$E2E_RUN_DIR/inspector.log" >&2 || true
    fi
}

# SIGTERM (graceful quit), then SIGKILL after 10s.
basecamp_stop() {
    local _t
    [ -n "$BASECAMP_PID" ] || return 0
    kill "$BASECAMP_PID" 2>/dev/null
    for _t in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$BASECAMP_PID" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$BASECAMP_PID" 2>/dev/null
    BASECAMP_PID=""
}
