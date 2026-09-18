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
# Requires: compat.sh (say/die), chain.sh (chain_head), json.sh, wallet.sh
# (wallet_fund_account) and daemon.sh (wallet_home_fresh); the caller's
# die() may call basecamp_die_tails for diagnostics.
#
# Globals set: BASECAMP_PID, BC_UD (user-dir), BC_INSPECTOR_PORT.

# More than one instance can run at once, so the per-instance state is keyed
# by label through compat.sh's sv/gv map — the same shape daemon.sh uses for
# nodes. `BC` names the instance the unlabelled helpers address, so a scenario
# that never mentions a label behaves exactly as before.
#
# The default label keeps the ORIGINAL log path, `$E2E_RUN_DIR/basecamp.log`:
# scenarios grep it directly for the delivery library's own lines, and a
# rename would have been a silent break in nine places.
BC_INSPECTOR_PORT="${E2E_INSPECTOR_PORT:-3768}"
BC_SETTLE_S="${E2E_BASECAMP_SETTLE_S:-20}"
BC="${BC:-bc}"
BC_LABELS=""
# Kept for scenarios that already read them — delivery-basecamp-rln and both
# chat scenarios name $BASECAMP_PID in their E2E_KEEP message. They track the
# most recently launched instance; anything driving two should read
# `gv BCPID <label>` / `gv BCUD <label>` instead.
# shellcheck disable=SC2034  # read by scenarios, not by this file
BASECAMP_PID=""
# shellcheck disable=SC2034  # ditto
BC_UD=""

# The inspector port for <label>. The default instance takes the base port;
# each further one takes the next, so `basecamp_launch_as b` needs no port
# argument to coexist with `a`.
bc_port() {
    local label="${1:-$BC}" port
    port=$(gv BCPORT "$label")
    printf '%s' "${port:-$BC_INSPECTOR_PORT}"
}

# Where <label>'s app log lives. See the note on the default label above.
basecamp_log_path() {
    local label="${1:-$BC}"
    if [ "$label" = "bc" ]; then
        printf '%s' "$E2E_RUN_DIR/basecamp.log"
    else
        printf '%s' "$E2E_RUN_DIR/basecamp-$label.log"
    fi
}

# Fail fast if something already owns the port an instance is about to bind.
# Usage: basecamp_port_check [port]
basecamp_port_check() {
    local port="${1:-$BC_INSPECTOR_PORT}"
    if command -v nc >/dev/null && nc -z 127.0.0.1 "$port" 2>/dev/null; then
        die "inspector port $port is already in use (a running Basecamp?) — set E2E_INSPECTOR_PORT"
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

# The `_on` forms address an instance by label; the bare forms address `BC`.
# Every call is routed by the port, so two instances are two ports and nothing
# else — there is no shared state to get wrong.
#
# bc_eval_on <label> <js-expression>
# bc_call_on <label> <module> <method> [argsJson]
bc_eval_on() {
    local label="$1"; shift
    printf '%s' "$1" | python3 "$BC_INSP" "$(bc_port "$label")" eval \
        2>>"$E2E_RUN_DIR/inspector-$label.log"
}
bc_call_on() {
    local label="$1"; shift
    printf '%s' "${3:-[]}" | python3 "$BC_INSP" "$(bc_port "$label")" call "$1" "$2" \
        2>>"$E2E_RUN_DIR/inspector-$label.log"
}

# bc_eval <js-expression>            -> prints the evaluate result
# bc_call <module> <method> [argsJson] -> prints the module reply (unwrapped)
bc_eval() { bc_eval_on "$BC" "$@"; }
bc_call() { bc_call_on "$BC" "$@"; }

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

# Wait for a line in basecamp's app log — the delivery library and the plugin
# log there, and some of what a scenario needs to know is only stated in a log
# line (configureRln outliving its transport deadline, "RLN membership
# verified"). Lives here because the log path is basecamp_launch's to choose;
# it was a private copy in delivery-basecamp-rln while two other scenarios
# called it.
# Usage: bc_log_wait <pattern> [seconds]
#        bc_log_wait_on <label> <pattern> [seconds]
bc_log_wait_on() {
    local label="$1" pattern="$2" budget="${3:-20}" _t log
    log=$(basecamp_log_path "$label")
    for _t in $(seq 1 "$budget"); do
        grep -q "$pattern" "$log" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}
bc_log_wait() { bc_log_wait_on "$BC" "$@"; }

# basecamp_launch <user-dir> <wallet-home> <chat-delivery-conf-json>
# Stages the harness modules dir into <user-dir>/modules, launches the app
# headless with the wallet + RLN env the module stack expects, waits for the
# inspector, settles, and gates on the `backend` context property.
# Extra KEY=VALUE env pairs may follow as further arguments.
basecamp_launch() { basecamp_launch_as "$BC" "$@"; }

# basecamp_launch_as <label> <user-dir> <wallet-home> <chat-delivery-conf-json>
# The labelled form. Each instance takes the next inspector port after the
# base, gets its own log, and records its pid and user-dir under its label —
# so a second launch adds an instance instead of replacing the first.
basecamp_launch_as() {
    local label="${1:?basecamp_launch_as <label> <user-dir> <wallet-home> <conf>}"
    local ud="$2" whome="$3" conf="$4"; shift 4
    [ -n "${BASECAMP_APP:-}" ] && [ -x "$BASECAMP_APP" ] \
        || die "basecamp_launch: BASECAMP_APP not set/executable (NEEDS_APPS=basecamp?)"
    [ -z "$(gv BCPID "$label")" ] || die "basecamp_launch_as: $label is already running"

    # Port by arrival order: the first instance takes the base, so a
    # single-instance scenario lands exactly where it always did.
    local n port log
    n=$(printf '%s' "$BC_LABELS" | wc -w | tr -d ' ')
    port=$(( BC_INSPECTOR_PORT + n ))
    basecamp_port_check "$port"
    sv BCPORT "$label" "$port"
    BC_LABELS="$BC_LABELS $label"
    log=$(basecamp_log_path "$label")

    sv BCUD "$label" "$ud"
    # shellcheck disable=SC2034  # the compatibility shim; see the note above
    BC_UD="$ud"
    mkdir -p "$ud/modules"
    cp -R "$E2E_MODULES_DIR/." "$ud/modules/" || die "cannot stage modules into $ud"
    say "$label: staged $(ls "$ud/modules" | tr '\n' ' ')into basecamp user-dir"
    _basecamp_write_driver
    env QT_QPA_PLATFORM=offscreen \
        QML_INSPECTOR_PORT="$port" \
        NSSA_WALLET_HOME_DIR="$whome" \
        LEE_WALLET_HOME_DIR="$whome" \
        LEZ_RLN_TREE_ID_HEX="$E2E_TREE_ID" \
        CHAT_DELIVERY_CONF_OVERRIDE="$conf" \
        "$@" \
        "$BASECAMP_APP" --user-dir "$ud" -platform offscreen \
        >"$log" 2>&1 &
    local pid=$!
    sv BCPID "$label" "$pid"
    BASECAMP_PID="$pid"
    say "$label: basecamp launched (pid $pid, inspector :$port, log $(basename "$log"))"

    local _t tb
    for _t in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || die "$label: basecamp exited during startup"
        if python3 -c "import socket;socket.create_connection(('127.0.0.1',$port),timeout=1).close()" 2>/dev/null; then
            break
        fi
        [ "$_t" = 60 ] && die "$label: inspector port never opened (60s)"
        sleep 1
    done
    say "$label: inspector reachable — settling ${BC_SETTLE_S}s (headless dependency resolution)"
    sleep "$BC_SETTLE_S"
    for _t in $(seq 1 30); do
        tb=$(bc_eval_on "$label" "typeof backend") || tb=""
        [ "$tb" = "object" ] && break
        [ "$_t" = 30 ] && die "$label: backend context property never appeared (got '$tb')"
        sleep 2
    done
    say "$label: backend reachable through evaluate"
}

# basecamp_load_modules <module>... — loadCoreModule each, in order, and
# wait until it answers introspection (getCoreModuleMethods != "[]").
basecamp_load_modules() { basecamp_load_modules_on "$BC" "$@"; }

# basecamp_load_modules_on <label> <module>...
basecamp_load_modules_on() {
    local label="$1"; shift
    local m ready _t methods
    for m in "$@"; do
        bc_eval_on "$label" "backend.loadCoreModule('$m')" >/dev/null
        ready=""
        for _t in $(seq 1 45); do
            methods=$(bc_eval_on "$label" "backend.getCoreModuleMethods('$m')") || methods=""
            case "$methods" in
                ""|"[]") sleep 2 ;;
                *) ready=1; break ;;
            esac
        done
        [ -n "$ready" ] || die "$label: module $m never became callable"
        say "$label: $m loaded"
    done
}

# basecamp_wallet_open_sync <wallet-home>
# Waits until the registry module's own wallet is open and caught up on the
# given home. Prints nothing; dies on failure.
#
# It used to seed storage.json from storage.json.seed here, under a comment
# saying the seeding had to happen before the app started — while every caller
# invoked this AFTER basecamp_launch, so the module had already adopted the
# home. Both halves are gone: the home is built by basecamp_wallet_home before
# the launch, and it deliberately carries no storage for the module to adopt.
basecamp_wallet_open_sync() { basecamp_wallet_open_sync_on "$BC" "$@"; }

# basecamp_wallet_open_sync_on <label> <wallet-home>
basecamp_wallet_open_sync_on() {
    local label="$1" home="$2" st _t tries iv
    [ -f "$home/wallet_config.json" ] || die "$label wallet: no wallet_config.json in $home"

    # Since liblogos_lez_rln_module 3.0.0 the module owns its wallet: it adopts
    # the home LEE_WALLET_HOME_DIR names and syncs it on its own thread at
    # load. Opening lez_core on that same storage.json would make two writers
    # of one file, so the app is never asked to — it is asked whether the
    # module is ready.
    iv="${E2E_POLL_INTERVAL_S:-5}"
    tries=$(( ${E2E_WALLET_READY_S:-600} / iv ))
    [ "$tries" -lt 1 ] && tries=1
    for _t in $(seq 1 "$tries"); do
        st=$(bc_call_on "$label" liblogos_lez_rln_module wallet_status) || st=""
        case "$st" in
            *'"state":"ready"'*) say "$label: basecamp wallet ready"; return 0 ;;
            ''|*'"state":"pending"'*) sleep "$iv" ;;
            *) die "$label: registry wallet failed to come up: $st" ;;
        esac
    done
    die "$label: registry wallet never became ready (last: ${st:-<empty>})"
}

# basecamp_wallet_home <dir>
# The app's own wallet home: the staged wallet_config.json and nothing else, so
# the module creates a wallet there and derives a payer only this instance
# holds. MUST precede basecamp_launch — the home reaches the module as
# LEE_WALLET_HOME_DIR on the app's command line and is never re-read.
#
# The alternative this replaces was a copy of the whole staged home plus
# LEZ_RLN_PAYER naming the deployment's funded account. That works, in the
# sense that the app can sign — but the harness signs as the same account, so
# two processes advance one nonce, and under liblogos_rln_module 0.8.0 both
# also submit a Register.
basecamp_wallet_home() {
    local dir="${1:?basecamp_wallet_home <dir>}"
    wallet_home_fresh "$dir"
}

# The account the app's registry module signs and pays with, published by the
# module precisely so something outside can fund it. Basecamp has no logoscore
# CLI seam, so this is wallet_payer's twin over the inspector.
basecamp_payer() { basecamp_payer_on "$BC"; }

# basecamp_payer_on <label>
basecamp_payer_on() {
    local label="$1" st payer
    st=$(bc_call_on "$label" liblogos_lez_rln_module wallet_status) || st=""
    payer=$(printf '%s' "$st" | jfield payer)
    # Qt parses a JSON-shaped module reply into an object and the driver
    # re-emits it, so what arrives here is usually clean JSON — but not always
    # (a reply that came back as a STRING re-emits with its braces escaped).
    # Fall back to reading the field out of the text rather than reporting a
    # module that answered as one that published nothing.
    [ -n "$payer" ] || payer=$(printf '%s' "$st" \
        | grep -oE '"payer":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$payer" ] || die "$label: the registry module published no payer account (wallet_status: ${st:-<empty>})"
    printf '%s' "$payer"
}

# Live NATIVE balance of <account>, or of the app's own payer when omitted.
# Prints a decimal string; "" when the module could not answer — which is NOT
# zero and must not be compared as such.
basecamp_native_balance() { basecamp_native_balance_on "$BC" "$@"; }

# basecamp_native_balance_on <label> [account]
basecamp_native_balance_on() {
    local label="$1" acct="${2:-}"
    bc_call_on "$label" liblogos_lez_rln_module get_native_balance \
        "$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1]]))' "$acct")" \
        | jfield balance
}

# Poll until the app's payer holds at least <want> native.
# Prints the last balance seen; 1 when the budget runs out.
basecamp_wait_native() { basecamp_wait_native_on "$BC" "$@"; }

# basecamp_wait_native_on <label> <want>
basecamp_wait_native_on() {
    local label="$1" want="$2" bal="" _w tries
    local iv="${E2E_POLL_INTERVAL_S:-5}"
    tries=$(( ${E2E_CONFIRM_TIMEOUT_S:-180} / iv ))
    [ "$tries" -lt 1 ] && tries=1
    for _w in $(seq 1 "$tries"); do
        bal=$(basecamp_native_balance_on "$label")
        case "$bal" in
            ''|*[!0-9]*) sleep "$iv"; continue ;;
        esac
        if [ "$bal" -ge "$want" ]; then printf '%s' "$bal"; return 0; fi
        sleep "$iv"
    done
    printf '%s' "${bal:-0}"
    return 1
}

# Fund the app's own payer and wait for the balance to land — wallet_fund's
# twin for an instance node_call cannot reach.
#
# It prints NOTHING. `say` writes to stdout, so a function that both logs and
# prints a value cannot be read with $( ): the first version of this returned
# its own log line glued to the account id. Ask basecamp_payer for the id.
basecamp_fund() { basecamp_fund_on "$BC" "$@"; }

# basecamp_fund_on <label> [amount]
basecamp_fund_on() {
    local label="$1" amount="${2:-${E2E_FUND_AMOUNT:-5000000000}}" payer before
    payer=$(basecamp_payer_on "$label") || exit 1
    [ -n "$payer" ] || die "$label: no payer to fund"
    # A payer derived in a home that carries no storage has never held
    # anything, so this is where a home built wrong shows up — and it is the
    # only place it can. Comparing the id against E2E_PAYER cannot do it: the
    # module publishes hex and the deployment names base58, so that comparison
    # is true whatever happened.
    before=$(basecamp_native_balance_on "$label" "$payer")
    case "$before" in
        '') die "$label: cannot read $payer's balance — refusing to fund an account whose state is unknown" ;;
        0)  : ;;
        *)  die "$label: payer $payer already holds $before native before anything funded it — its wallet home carried storage, so it derived an existing account rather than one of its own" ;;
    esac
    say "$label: funding its payer $payer with $amount native"
    wallet_fund_account "$payer" "$amount"
    basecamp_wait_native_on "$label" "$amount" >/dev/null \
        || die "$label: payer $payer never reached $amount native"
}

# Diagnostics for a scenario's die(): app stderr, the newest session log
# under the user-dir, the inspector driver log.
basecamp_die_tails() {
    local label blog log ud
    # Every instance, not the last one launched: with two apps the failure is
    # as likely to be in the one that is not current.
    for label in ${BC_LABELS:-$BC}; do
        log=$(basecamp_log_path "$label")
        if [ -s "$log" ]; then
            echo "---- $label: basecamp log tail ----" >&2
            tail -25 "$log" >&2 || true
        fi
        ud=$(gv BCUD "$label")
        blog=$(ls -t "$ud/logs" 2>/dev/null | head -1)
        if [ -n "$blog" ]; then
            echo "---- $label: basecamp session log tail ($blog) ----" >&2
            tail -25 "$ud/logs/$blog" >&2 || true
        fi
        if [ -s "$E2E_RUN_DIR/inspector-$label.log" ]; then
            echo "---- $label: inspector driver log tail ----" >&2
            tail -10 "$E2E_RUN_DIR/inspector-$label.log" >&2 || true
        fi
    done
}

# SIGTERM (graceful quit), then SIGKILL after 10s.
# basecamp_stop [label] — one instance, or every launched one when omitted.
# The no-argument form is what the single-instance scenarios already call, and
# stopping "all" of one instance is what it always did.
basecamp_stop() {
    local label
    if [ -n "${1:-}" ]; then
        _basecamp_stop_one "$1"
        return 0
    fi
    for label in $BC_LABELS; do
        _basecamp_stop_one "$label"
    done
    # shellcheck disable=SC2034  # the compatibility shim; see the note above
    BASECAMP_PID=""
}

_basecamp_stop_one() {
    local label="$1" pid _t
    pid=$(gv BCPID "$label")
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null
    for _t in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null
    sv BCPID "$label" ""
}
