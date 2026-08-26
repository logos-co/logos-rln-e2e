#!/usr/bin/env bash
# scenarios/consumer-selftest — the no-chain gate for the consumer module.
# What it proves:
#   1. the .lgx loads in logoscore (librlnconsumer resolves beside the plugin)
#   2. a call crosses harness -> C++ plugin -> nim-ffi -> Nim and back (ping)
#   3. a >5s Nim handler crosses one nim-ffi RET_STALE_WARN progress tick and
#      still completes (slowPing) — the ticket bridge treats it as non-terminal
#   4. an RLN op with NO liblogos_rln_module loaded fails fast and clean
#      through the whole seam (Nim rlnInvoke -> op callback -> bridge worker ->
#      lp failure -> error back), instead of hanging or crashing
#   5. a second createConsumer is rejected (one consumer per context)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done

cleanup() { daemon_stop_all; }
trap cleanup EXIT

NODE=n1
section "daemon"
daemon_start "$NODE"
daemon_load_modules "$NODE" nim_rln_consumer

section "createConsumer"
CFG='{"registryId":"logos:selftest:0000000000000000000000000000000000000000000000000000000000000000","rlnIdentifierHex":"1111111111111111111111111111111111111111111111111111111111111111","epochSizeSec":"60","opTimeoutSec":"10"}'
OUT=$(node_call "$NODE" nim_rln_consumer createConsumer "$(argfile cfg1 "$CFG")" | jres)
case "$OUT" in
    *'"success":true'*) say "createConsumer OK" ;;
    *) die "createConsumer failed: $OUT" ;;
esac

OUT=$(node_call "$NODE" nim_rln_consumer createConsumer "$(argfile cfg2 "$CFG")" | jres)
case "$OUT" in
    *'already created'*) say "double createConsumer rejected" ;;
    *) die "expected the second createConsumer to be rejected, got: $OUT" ;;
esac

section "ping"
OUT=$(node_call "$NODE" nim_rln_consumer ping "selftest" | jres)
case "$OUT" in
    *'"success":true'*'pong: selftest'*) say "ping round-trip OK (C++ -> Nim -> C++)" ;;
    *) die "ping failed: $OUT" ;;
esac

section "slowPing (crosses one RET_STALE_WARN tick)"
OUT=$(node_call "$NODE" nim_rln_consumer slowPing "selftest" | jres)
case "$OUT" in
    *'"success":true'*'slow pong: selftest'*) say "slowPing OK — stale tick treated as non-terminal" ;;
    *) die "slowPing failed (stale-warn handling broken?): $OUT" ;;
esac

section "RLN op without the RLN module"
# startRln must travel the whole seam and fail CLEANLY: Nim rlnStart() ->
# typed op callback -> bridge worker -> lp client fails (no
# liblogos_rln_module) -> {"err":{"kind","message"}} envelope (or the seam's
# 10s TRANSIENT timeout, whichever lands first) -> Nim err -> plugin failure.
# A hang here means the seam lost a completion; a crash means the bridge
# didn't survive an lp failure.
OUT=$(node_call "$NODE" nim_rln_consumer startRln | jres)
case "$OUT" in
    *'"success":false'*) say "startRln failed cleanly through the seam: $OUT" ;;
    *) die "expected a clean seam failure from startRln, got: $OUT" ;;
esac

# ...and the module must still be alive afterwards.
OUT=$(node_call "$NODE" nim_rln_consumer ping "still-alive" | jres)
case "$OUT" in
    *'pong: still-alive'*) say "module alive after the failed op" ;;
    *) die "module wedged after the failed op: $OUT" ;;
esac

say "CONSUMER SELFTEST PASS"
