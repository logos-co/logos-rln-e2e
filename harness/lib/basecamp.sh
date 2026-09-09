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
# Opens lez_core on the home (seeding storage.json from storage.json.seed
# when absent — the fresh-wallet shape) and syncs to the chain head with
# the busy/idle patience loop. Prints nothing; dies on failure.
basecamp_wallet_open_sync() {
    local home="$1" head bsync _t open_args
    [ -f "$home/wallet_config.json" ] || die "basecamp wallet: no wallet_config.json in $home"
    if [ ! -f "$home/storage.json" ]; then
        cp "$home/storage.json.seed" "$home/storage.json" \
            || die "basecamp wallet: cannot seed $home/storage.json"
    fi
    head=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
    open_args=$(jq -cn --arg c "$home/wallet_config.json" --arg s "$home/storage.json" \
        --arg t "$home/statistics.json" '[$c,$s,$t]')
    bc_call lez_core open "$open_args" >/dev/null   # reply unreliable; probe below
    bsync=""
    for _t in $(seq 1 9); do
        bsync=$(bc_synced) || bsync=""
        [ -n "$bsync" ] && break
        sleep 10
    done
    [ -n "$bsync" ] || die "basecamp wallet never became usable after open"
    say "basecamp wallet open (synced to $bsync, head $head)"

    local step="${E2E_BASECAMP_SYNC_STEP:-250}"
    local reissue_s="${E2E_SYNC_REISSUE_S:-30}"
    local stall_s="${E2E_SYNC_STALL_S:-600}"
    local cur="$bsync" tgt="$bsync" now next
    local last_progress last_issue=0 last_said=0 busy_n=0
    last_progress=$(date +%s)
    while [ "$cur" -lt "$head" ]; do
        now=$(date +%s)
        if [ "$cur" -ge "$tgt" ]; then
            tgt=$(( cur + step ))
            [ "$tgt" -gt "$head" ] && tgt="$head"
            bc_call lez_core sync_to_block "[$tgt]" >/dev/null 2>&1 || true
            last_issue=$now
        fi
        next=$(bc_synced) || next=""
        if [ -n "$next" ] && [ "$next" -gt "$cur" ]; then
            cur="$next"
            last_progress=$now
            busy_n=0
            if [ $(( cur - last_said )) -ge 2000 ] || [ "$cur" -ge "$head" ]; then
                say "  basecamp wallet sync: $cur / $head"
                last_said=$cur
            fi
        elif [ $(( now - last_progress )) -ge "$stall_s" ]; then
            die "basecamp wallet sync stalled at $cur for ${stall_s}s (head $head, chunk target $tgt)"
        elif [ -z "$next" ]; then
            # BUSY: no reads mid-chunk; never re-issue into a busy wallet.
            busy_n=$(( busy_n + 1 ))
            [ $(( busy_n % 6 )) = 0 ] && say "  basecamp wallet busy at $cur (chunk -> $tgt, $(( now - last_progress ))s since progress)"
            sleep 5
        else
            # IDLE without progress: the chunk ended early — re-issue it.
            if [ $(( now - last_issue )) -ge "$reissue_s" ]; then
                bc_call lez_core sync_to_block "[$tgt]" >/dev/null 2>&1 || true
                last_issue=$now
            fi
            sleep 2
        fi
    done
    say "basecamp wallet synced to head"
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
