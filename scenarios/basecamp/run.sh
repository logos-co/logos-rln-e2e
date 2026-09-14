#!/usr/bin/env bash
# scenarios/basecamp — two Basecamp instances, modules installed, left running
# for manual testing of the same path the `delivery` scenario automates.
#
# Basecamp embeds liblogos in-process and exposes no daemon the logoscore CLI
# can attach to (`--config-dir <user-dir>` answers daemon not_configured), so
# nothing here drives a node. What it does is the setup that is tedious by
# hand: resolve the chain, install the whole module stack plus both UIs into
# two isolated instances, launch them, and print the exact values to paste in.
#
# It also brings up the same logos-docker relay the delivery scenario uses, so
# both instances meet at one fixed address rather than you copying a multiaddr
# between two UIs. The chain is the target's: --target local boots a local
# sequencer and provisions a fresh tree, --target testnet uses the hosted one.
#
# The instances and the relay are deliberately LEFT RUNNING — that is the
# deliverable. The script prints how to stop them.
#
# Modules come from a directory of portable .lgx bundles, which
# tools/build-basecamp-lgx.sh produces. They must be portable, not the -dev
# variants the harness builds for its own daemons: a dev bundle resolves its
# libraries out of /nix/store paths that Basecamp's plugin loader does not
# carry.
#
# Env beyond docs/contract.md:
#   E2E_BASECAMP_BIN       the LogosBasecamp binary (default: result/bin under
#                          E2E_BASECAMP_CHECKOUT)
#   E2E_BASECAMP_CHECKOUT  logos-basecamp checkout (default ../logos-basecamp)
#   E2E_BASECAMP_LGX_DIR   directory of portable .lgx (default ./basecamp-lgx)
#   E2E_BASECAMP_DIR       where the instance user-dirs go (default under the
#                          run dir; point it somewhere durable to keep them)
#   E2E_TCP_PORT_BASE      instance n's node listens on base+n (default 61200)
#   E2E_BOOTSTRAP=docker   bring up the relay; `none` peers the instances
#                          directly (harness/lib/bootstrap.sh has its knobs)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx chain bootstrap; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

CHECKOUT="${E2E_BASECAMP_CHECKOUT:-$ROOT/../logos-basecamp}"
LGX_DIR="${E2E_BASECAMP_LGX_DIR:-$ROOT/basecamp-lgx}"
INSTANCE_ROOT="${E2E_BASECAMP_DIR:-$E2E_RUN_DIR/basecamp}"
TCP_PORT_BASE="${E2E_TCP_PORT_BASE:-61200}"
CLUSTER_ID="${E2E_CLUSTER_ID:-198}"

for _v in E2E_SEQUENCER E2E_CONFIG_ACCOUNT E2E_TREE_ID; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done

BIN="${E2E_BASECAMP_BIN:-}"
if [ -z "$BIN" ]; then
    BIN="$CHECKOUT/result/bin/LogosBasecamp"
fi
[ -x "$BIN" ] || die "no Basecamp binary at $BIN — build it (cd $CHECKOUT && nix build) or set E2E_BASECAMP_BIN"

[ -d "$LGX_DIR" ] || die "no module bundles at $LGX_DIR — build them: ./tools/build-basecamp-lgx.sh -o $LGX_DIR"
BUNDLES=$(find "$LGX_DIR" -maxdepth 1 -name '*.lgx' | sort)
[ -n "$BUNDLES" ] || die "no .lgx under $LGX_DIR — build them: ./tools/build-basecamp-lgx.sh -o $LGX_DIR"

CONFIG_HEX=$(python3 - "$E2E_CONFIG_ACCOUNT" <<'EOF'
import sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + A.index(c)
print(n.to_bytes(32, "big").hex())
EOF
) || die "cannot decode config account '$E2E_CONFIG_ACCOUNT'"
REGISTRY_ID="logos:${E2E_TARGET}:$CONFIG_HEX"

# One identifier for both instances: it scopes the application, not the member,
# and feeds the external nullifier each side derives. Peers that do not share
# it can never validate each other's proofs.
RLN_IDENTIFIER="${E2E_RLN_IDENTIFIER:-$(openssl rand -hex 32)}"

# The createNode config for one instance, with the relay as its entry node when
# there is one.
bc_node_cfg() {
    local port="$1" entry=""
    [ -n "$PEER" ] && entry=",\"entry-node\":[\"$PEER\"]"
    printf '{"mode":"core","preset":"","messagingOverrides":{"log-level":"DEBUG","listen-address":"127.0.0.1","tcp-port":%s,"cluster-id":%s,"num-shards-in-network":1,"store":false%s}}' \
        "$port" "$CLUSTER_ID" "$entry"
}

PEER=""
PIDS=""
STARTED=0
cleanup() {
    [ "$STARTED" = 1 ] && return 0
    for p in $PIDS; do kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

# Usage: instance <label> <index>
instance() {
    local label="$1" index="$2" udir mods lgx pid
    udir="$INSTANCE_ROOT/$label"
    mods="$udir/modules"
    mkdir -p "$mods" || die "cannot create $mods"

    for lgx in $BUNDLES; do
        install_lgx "$lgx" "$mods"
    done
    say "$label: installed $(find "$mods" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') modules into $mods"

    # LEZ_RLN_TREE_ID_HEX must reach the app: rln_core derives its PDAs from it.
    # Software rendering because these run over X11 forwarding to XQuartz,
    # which cannot give Qt Quick a usable GLX context.
    (cd "$udir" && exec env \
        LEZ_RLN_TREE_ID_HEX="$E2E_TREE_ID" \
        QT_QUICK_BACKEND=software \
        QT_XCB_GL_INTEGRATION=none \
        "$BIN" --user-dir "$udir" >>"$udir/basecamp-stdout.log" 2>&1) &
    pid=$!
    PIDS="$PIDS $pid"
    disown "$pid" 2>/dev/null || true
    sv BCPID "$label" "$pid"
    sv BCDIR "$label" "$udir"
    say "$label: started (pid $pid, user-dir $udir)"
}

section "chain"
say "registry: $REGISTRY_ID"
say "tree ${E2E_TREE_ID:0:8}…, sequencer $E2E_SEQUENCER"

# The same relay the delivery scenario uses, so both instances meet at one
# fixed address instead of you copying a multiaddr between two UIs. Left
# running with them; E2E_BOOTSTRAP=none skips it and peers them directly.
if [ "${E2E_BOOTSTRAP:-docker}" = docker ]; then
    section "bootstrap"
    bootstrap_up "$CLUSTER_ID" 1 "$REGISTRY_ID" "$RLN_IDENTIFIER" "${E2E_RATE_LIMIT:-100}"
    PEER=$(bootstrap_multiaddr)
fi

section "instances"
instance a 1
instance b 2

# Ready when the module scan has run; the log is the only signal the app gives.
for _label in a b; do
    _dir=$(gv BCDIR "$_label")
    for _t in $(seq 1 60); do
        grep -q "Logos Core started successfully" "$_dir/basecamp-stdout.log" 2>/dev/null && break
        sleep 2
    done
    grep -q "Logos Core started successfully" "$_dir/basecamp-stdout.log" 2>/dev/null \
        || die "$_label: core never started — see $_dir/basecamp-stdout.log"
    say "$_label: core up"
done
STARTED=1

cat <<TXT

e2e: PASS — two Basecamp instances are running and left up.

  a  pid $(gv BCPID a)  $(gv BCDIR a)
  b  pid $(gv BCPID b)  $(gv BCDIR b)${PEER:+
  relay  $PEER}

Manual test, in this order:

1. In BOTH: open the RLN membership UI, create a NEW wallet (do not import a
   committed one), claim from the faucet, and register a membership with
     registry-id      $REGISTRY_ID
     rln-identifier   $RLN_IDENTIFIER
   The identifier must be THE SAME in both, or neither can validate the other.

2. In BOTH: delivery_module.configureRln, BEFORE createNode --
   {"registry-id":"$REGISTRY_ID","rln-identifier":"$RLN_IDENTIFIER","epoch-size-sec":${E2E_EPOCH_SIZE_SEC:-600}}

3. In a, createNode with
   $(bc_node_cfg $((TCP_PORT_BASE+1)))
   then start.

4. In b, the same but on tcp-port $((TCP_PORT_BASE+2)):
   $(bc_node_cfg $((TCP_PORT_BASE+2)))

5. Subscribe on both, send from a in the delivery demo, watch it arrive on b.
   get_epoch_quota on a drops by one per message.

Stop everything:
  kill $(gv BCPID a) $(gv BCPID b)${PEER:+
  docker rm -f $E2E_BOOTSTRAP_NAME}
TXT
