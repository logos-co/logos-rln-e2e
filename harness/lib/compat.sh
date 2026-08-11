# shellcheck shell=bash
# harness/lib/compat.sh — logging + bash 3.2 compat, sourced by everything.
# Stock macOS ships bash 3.2: no associative arrays, no ${var,,}. Keep every
# harness script runnable there.

say()     { printf '%s\n' "e2e: $*"; }
section() { printf '\n== %s ==\n' "$*"; }
die()     { printf '%s\n' "e2e: FAIL: $*" >&2; exit 1; }

# sv <map> <key> <value> / gv <map> <key> — string-keyed map shim
# (keys restricted to [A-Za-z0-9_]).
sv() { eval "_${1}_${2}=\"\$3\""; }
gv() { eval "printf '%s' \"\${_${1}_${2}:-}\""; }