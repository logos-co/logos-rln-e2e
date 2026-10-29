#!/usr/bin/env bash
# tools/zone/export-node-state.sh — copy a membership out of a logosctl
# container so a scenario can seed a node with it (harness/lib/seed.sh,
# seed_module_state).
#
#   tools/zone/export-node-state.sh <container> [out-dir] [registry-id]
#
# Defaults: out-dir ~/.local/share/logos-rln-e2e/zone/<container>, registry
# logos:testnet:<hex of BpxYQFLWf6Wi5HhWAaZRtbhxmeKa5P9THK7WBDCoXRg9>
# (testnet-zone-events, the registry on the events-era program).
#
# What it takes:
#   rln-module/      liblogos_rln_module's persistence dir: the sealed keystore
#                    (the membership secret and its slot counters), the records
#                    and rln_autounlock.secret, the module-owned password
#   lez-module/      liblogos_lez_rln_module's persistence dir: leaf_claims.json
#                    (the leaf index the registration claimed) and payer.json
#   membership.json  liblogos_rln_module.get_memberships for the registry, as
#                    the container answers it: a scenario reads the
#                    rln_identifier (memberships are scoped by it), the leaf
#                    index and the membership hash from here
#
# The out-dir holds a membership SECRET: it is created 0700 under a path
# outside any repo. Never commit it.
set -euo pipefail

CTR="${1:?usage: export-node-state.sh <container> [out-dir] [registry-id]}"
OUT="${2:-$HOME/.local/share/logos-rln-e2e/zone/$CTR}"
REG="${3:-}"
say() { printf 'export-node-state: %s\n' "$*" >&2; }
die() { say "FAIL: $*"; exit 1; }

command -v docker >/dev/null || die "docker not on PATH"
docker inspect "$CTR" >/dev/null 2>&1 || die "no container '$CTR' (is Docker running? docker ps -a)"
[ "$(docker inspect -f '{{.State.Running}}' "$CTR")" = true ] || die "container '$CTR' is not running: docker start $CTR"

if [ -z "$REG" ]; then
    HEX=$(python3 - <<'PY'
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in "BpxYQFLWf6Wi5HhWAaZRtbhxmeKa5P9THK7WBDCoXRg9":
    n = n * 58 + A.index(c)
print(n.to_bytes(32, "big").hex())
PY
)
    REG="logos:testnet:$HEX"
fi

# The module persistence dirs live under the logosctl session dir
# (LOGOSCTL_CONFIG_DIR=/data/session in the rlnreg image); find them by the
# files the modules are known to write rather than by a layout nobody pinned.
RLN_DIR=$(docker exec "$CTR" sh -c 'find /data -name rln_autounlock.secret 2>/dev/null | head -1 | xargs -r dirname')
[ -n "$RLN_DIR" ] || die "no rln_autounlock.secret under /data in $CTR — the RLN module never provisioned a keystore there"
LEZ_DIR=$(docker exec "$CTR" sh -c 'find /data -name leaf_claims.json 2>/dev/null | head -1 | xargs -r dirname')
if [ -z "$LEZ_DIR" ]; then
    LEZ_DIR=$(docker exec "$CTR" sh -c 'find /data -name payer.json 2>/dev/null | head -1 | xargs -r dirname')
    [ -z "$LEZ_DIR" ] || say "no leaf_claims.json in $CTR (registration was sent elsewhere); taking $LEZ_DIR for payer.json only"
fi
[ -n "$LEZ_DIR" ] || say "no lez-module persistence found in $CTR; the RLN record's cached leaf index must carry the seed"

umask 077
rm -rf "$OUT"
mkdir -p "$OUT"
docker cp "$CTR:$RLN_DIR/." "$OUT/rln-module/"
say "rln-module/ <- $CTR:$RLN_DIR ($(find "$OUT/rln-module" -type f | wc -l | tr -d ' ') files)"
if [ -n "$LEZ_DIR" ]; then
    docker cp "$CTR:$LEZ_DIR/." "$OUT/lez-module/"
    say "lez-module/ <- $CTR:$LEZ_DIR ($(cd "$OUT/lez-module" && printf '%s ' *))"
fi

# The memberships as the container's module reports them. The CLI envelope is
# {"status":"ok","result":<string or object>}; keep the unwrapped result.
RAW=$(docker exec "$CTR" timeout 60 logosctl --json call liblogos_rln_module get_memberships "$REG" 2>/dev/null || true)
printf '%s' "$RAW" | python3 -I -c '
import json, sys
out = None
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
        if isinstance(r, str):
            try:
                r = json.loads(r)
            except Exception:
                pass
        out = r
        break
if out is None:
    sys.exit("get_memberships gave no result: " + sys.argv[1][:300])
json.dump({"registry_id": sys.argv[2], "container": sys.argv[3], "memberships": out}, open(sys.argv[4], "w"), indent=1)
' "$RAW" "$REG" "$CTR" "$OUT/membership.json" || die "cannot record the memberships (is the module loaded and the registry right? $REG)"
say "membership.json <- get_memberships $REG"
grep -o '"state": *"[a-z_]*"\|"leaf_index": *[0-9]*\|"rln_identifier": *"[0-9a-f]*"' "$OUT/membership.json" | sort -u | tr '\n' ' ' >&2; echo >&2
chmod -R go-rwx "$OUT"
say "seed at $OUT — seed a node with seed_module_state <node> liblogos_rln_module $OUT/rln-module (harness/lib/seed.sh)"
