# shellcheck shell=bash
# harness/lib/json.sh — JSON plumbing for logoscore --json calls.
#
# call_json drives the daemon whose LOGOSCORE_CONFIG_DIR is $E2E_CFG_DIR;
# daemon.sh's node_call sets that per node, so a scenario that talks to one
# node can call call_json directly.
#
# Env beyond docs/contract.md:
#   LOGOSCORE      the CLI (harness/artifacts.sh exports it)
#   E2E_CFG_DIR    config dir of the daemon a bare call_json talks to
#   E2E_ARGS_DIR   where argfile materialises @file args (default
#                  $E2E_RUN_DIR/args)
#   CALL_TIMEOUT   per-call timeout in seconds (default 180)

# Digit-leading strings (base58 accounts, hex) must go via @file or the CLI
# coerces them to numbers.
argfile() {
    local dir="${E2E_ARGS_DIR:-${E2E_RUN_DIR:-.}/args}"
    mkdir -p "$dir" || die "argfile: cannot create $dir"
    printf '%s' "$2" > "$dir/$1.arg"
    printf '@%s' "$dir/$1.arg"
}

# timeout(1) is coreutils; stock macOS has neither it nor gtimeout. A missing
# timeout must not fail every call — run uncapped instead.
_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"
    fi
}

call_json() {
    local mod="$1" meth="$2"; shift 2
    [ -n "${LOGOSCORE:-}" ] || die "call_json: LOGOSCORE unset (resolve_artifacts first)"
    [ -n "${E2E_CFG_DIR:-}" ] || die "call_json: no daemon selected (use node_call)"
    # env -u TMPDIR: daemon and client must agree on the effective TMPDIR
    # (QLocalSocket path); the daemon runs under env -i, i.e. without one.
    _with_timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$E2E_CFG_DIR" \
        "$LOGOSCORE" --json call "$mod" "$meth" "$@" 2>/dev/null
}

jres() {
    python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("status") == "ok" and "result" in d:
        r = d["result"]
        # Compact separators: callers case-glob against the modules own
        # compact JSON, so re-serialized values must not add spaces.
        print(r if isinstance(r, str) else json.dumps(r, separators=(",", ":")))
        break
'
}

# The CLI envelope status ("ok"/"error"), empty when the call emitted no JSON.
jstatus() {
    python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if "status" in d:
        print(d["status"])
        break
'
}

jfield() { python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('$1', ''))
except Exception:
    print('')
"; }

to_hex() { python3 -c 'import sys; print(sys.stdin.buffer.read().hex())'; }

# Unwrap a LogosResult envelope {success,value,error} (the -> result methods:
# start/stop/generate_proof/verify_proof/get_epoch_quota/
# get_registry_parameters) to its value on success or its error string on
# failure; passes anything else through unchanged (tolerates a double-encoded
# envelope, like the lp clients do).
jval() { python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    print(raw); sys.exit()
if isinstance(d, str):
    try:
        d = json.loads(d)
    except Exception:
        print(d); sys.exit()
if isinstance(d, dict) and "success" in d and ("value" in d or "error" in d):
    out = d.get("value") if d.get("success") else d.get("error")
    # Compact separators — see jres.
    print(out if isinstance(out, str) else json.dumps(out, separators=(",", ":")))
else:
    print(raw)
'; }
