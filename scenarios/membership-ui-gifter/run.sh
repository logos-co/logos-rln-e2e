#!/usr/bin/env bash
# scenarios/membership-ui-gifter — the RLN membership UI inside headless
# Basecamp, and the delegated registration it drives through an allocator
# that authenticates with an eth allowlist.
#
# Topology:
#   n2         the ALLOCATOR: logoscore + the lez stack + libp2p_module +
#              rln_gifter_module + eth_auth_module, its own funded payer,
#              `serve` with an eth-allowlist verifier naming the address
#              Basecamp's eth_sign_module reports.
#   basecamp   headless, fresh never-funded wallet: lez stack + libp2p_module
#              + rln_gifter_module (client half) + eth_sign_module (auth
#              producer) + liblogos_rln_module, with the UI bundle in its
#              plugins dir and keycard_capture_module installed (a declared UI
#              dependency, never called).
#
# What it proves:
#   1. the UI mounts: every dependency it declares resolves and Basecamp loads
#      it (no missing-deps popup).
#   2. Tier 1, the gate: register_membership with exactly the options the UI's
#      builder emits for eth — rate_limit 100, delegated, gifter_peer_id,
#      gifter_multiaddr, auth_type eth-allowlist, auth_provider eth_sign_module
#      — goes pending -> active; the allocator paid; Basecamp's payer did not.
#   3. the module key signed it: with the allocator re-served on a different
#      allowlist, a second registration (new rln_identifier) fails with
#      "address not allowlisted".
#   4. Tier 2 (non-blocking): the UI's flowController is reachable through the
#      inspector's object tree; the view runs in Basecamp's sandboxed
#      QQuickWidget engine, so `evaluate` cannot see it. Not reachable within
#      10s -> summary.json records TIER2_SKIPPED=sandbox-unreachable.
#
# Required (beyond docs/contract.md):
#   UI_LGX                logos-rln-membership-ui result-lgx (rln_membership_ui)
#   ETH_SIGN_LGX          logos-rln-gifter rust/eth-sign-module result-lgx
#   ETH_AUTH_LGX          logos-rln-gifter rust/eth-auth-module result-lgx
#   KEYCARD_CAPTURE_LGX   logos-rln-gifter rust/keycard-capture-module result-lgx
#   BASECAMP_APP | BASECAMP_CHECKOUT, LIBP2P_LGX | LIBP2P_MODULE_CHECKOUT,
#   GIFTER_LGX | GIFTER_CHECKOUT
#
# Env knobs:
#   E2E_UI_RATE_LIMIT=100       the UI's delegated rate (the registry minimum, which a
#                               default allocator serves without a maxRateLimit)
#   E2E_GIFTER_PORT=61873       the allocator's libp2p listen port
#   E2E_REG_WAIT_S=600          per-registration budget (pending -> active / failed)
#   E2E_INSPECTOR_PORT=3768     basecamp QML inspector port (must be free)
#   E2E_BASECAMP_SETTLE_S=20    post-launch settle before driving the app
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain basecamp delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

UI_RATE="${E2E_UI_RATE_LIMIT:-100}"
GIFTER_PORT="${E2E_GIFTER_PORT:-61873}"
REG_WAIT_S="${E2E_REG_WAIT_S:-600}"
UI_NAME="rln_membership_ui"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_RUN_DIR E2E_SEQUENCER E2E_WALLET_HOME \
          E2E_CONFIG_ACCOUNT E2E_TREE_ID E2E_PAYER E2E_CONFIRM_TIMEOUT_S \
          E2E_POLL_INTERVAL_S E2E_EPOCH_SIZE_SEC BASECAMP_APP; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md + scenario.env)"
done
for _v in UI_LGX ETH_SIGN_LGX ETH_AUTH_LGX KEYCARD_CAPTURE_LGX; do
    eval "[ -f \"\${$_v:-}\" ]" || die "$_v must name its .lgx (see run.sh header)"
done
basecamp_port_check

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODES_UP=""
DYING=0
UD="$E2E_RUN_DIR/basecamp-user"
SUMMARY="$E2E_RUN_DIR/summary.json"
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ]; then
        DYING=1
        basecamp_die_tails
        local n
        for n in $NODES_UP; do
            echo "---- $n log tail ----" >&2
            node_logs "$n" 30 >&2 || true
        done
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving basecamp (pid ${BASECAMP_PID:-none}) + nodes up, state in $E2E_RUN_DIR"
        return
    fi
    basecamp_stop
    [ -n "$NODES_UP" ] && daemon_stop_all
}
trap cleanup EXIT

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
say "registry: $REGISTRY_ID (UI rate $UI_RATE)"

# The extra core modules ride the shared modules dir (daemons and Basecamp's
# user-dir both stage from it); the UI bundle goes to Basecamp's plugins dir.
install_lgx "$ETH_AUTH_LGX"
install_lgx "$ETH_SIGN_LGX"
install_lgx "$KEYCARD_CAPTURE_LGX"
mkdir -p "$UD/plugins"
install_lgx "$UI_LGX" "$UD/plugins"
say "staged eth_auth_module, eth_sign_module, keycard_capture_module; $UI_NAME into $UD/plugins"

# ---------- n2: the allocator --------------------------------------------------
section "n2: allocator (libp2p + rln_gifter_module + eth_auth_module)"
daemon_self_paying n2 "$E2E_RUN_DIR/wallet-n2"
daemon_start n2 || die "daemon_start n2 failed"
NODES_UP="n2"
daemon_load_modules n2 liblogos_lez_rln_module liblogos_rln_module \
    libp2p_module rln_gifter_module eth_auth_module || die "n2: load-module failed"
wallet_open n2 || die "n2: wallet open failed"
wallet_sync n2 >/dev/null || die "n2: wallet sync failed"
PRICE=$(node_call n2 liblogos_lez_rln_module get_registry_bounds \
    "$(argfile gcfg "$E2E_CONFIG_ACCOUNT")" | jres | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in the registry bounds"
GPAYER=$(wallet_payer n2) || die "n2 published no payer"
wallet_fund n2 >/dev/null || die "funding the allocator's payer never landed"
gbal() { wallet_native_balance n2 "$GPAYER"; }
GBAL0=$(gbal)
case "$GBAL0" in ''|*[!0-9]*) die "cannot read the allocator's balance: '${GBAL0:-<empty>}'" ;; esac
say "allocator payer $GPAYER holds $GBAL0; price $PRICE per unit"

GADDR="/ip4/127.0.0.1/tcp/$GIFTER_PORT"
node_call n2 libp2p_module createNode "{\"addrs\":[\"$GADDR\"]}" | jres >/dev/null \
    || die "n2 libp2p createNode failed"
node_call n2 libp2p_module start | jres >/dev/null || die "n2 libp2p start failed"
PEERINFO=$(node_call n2 libp2p_module peerInfo | jres | jval) || PEERINFO=""
case "$PEERINFO" in
    *"/tcp/$GIFTER_PORT"*) ;;
    *) die "n2 libp2p is not listening on $GADDR: ${PEERINFO:-<empty>}" ;;
esac
GPEER=$(printf '%s' "$PEERINFO" | jfield peerId)
[ -n "$GPEER" ] || die "no peerId in peerInfo"
say "allocator peer: $GPEER @ $GADDR"
NULLIFIERS="$E2E_RUN_DIR/allocator-nullifiers"
serve() {
    local res
    res=$(node_call n2 rln_gifter_module serve "$(jq -cn --arg c "$E2E_CONFIG_ACCOUNT" \
        --arg w "$GPAYER" --arg n "$NULLIFIERS" --arg a "$1" \
        '{config:$c, wallet:$w, consumedNullifiersPath:$n,
          authVerifiers:{"eth-allowlist":{module:"eth_auth_module", config:{allowlist:[$a]}}}}')" | jres) || res=""
    case "$res" in
        ''|*error*) die "allocator serve (allowlist $1) failed: ${res:-<empty>}" ;;
    esac
    say "allocator serving eth-allowlist [$1]"
}

# ---------- basecamp ------------------------------------------------------------
section "basecamp up (headless; fresh never-funded wallet; UI in plugins)"
BHOME="$E2E_RUN_DIR/wallet-basecamp"
basecamp_wallet_home "$BHOME"
basecamp_launch "$UD" "$BHOME" ""
basecamp_load_modules liblogos_lez_rln_module libp2p_module rln_gifter_module \
    eth_sign_module liblogos_rln_module
basecamp_wallet_open_sync "$BHOME"
BC_PAYER=$(basecamp_payer) || die "basecamp: no payer"
[ "$BC_PAYER" != "$GPAYER" ] || die "basecamp's payer IS the allocator's account ($GPAYER)"
bc_payer_balance() { wallet_native_balance n2 "$BC_PAYER"; }
BCBAL0=$(bc_payer_balance)
[ "$BCBAL0" = 0 ] || die "basecamp's payer $BC_PAYER holds '${BCBAL0:-<unreadable>}' — 'the allocator paid' would be unfalsifiable"
say "basecamp payer $BC_PAYER holds 0 — it cannot pay"

for step in createNode start; do
    a='[]'
    [ "$step" = createNode ] && a=$(jq -cn --arg c '{"addrs":["/ip4/127.0.0.1/tcp/0"]}' '[$c]')
    R=$(bc_call libp2p_module "$step" "$a") || R=""
    case "$R" in
        *'"success":false'*|*'"error":"'*) die "basecamp: libp2p $step failed: $R" ;;
    esac
done
say "basecamp: libp2p node up (the gifter client dials through it)"
START_ARGS=$(jq -cn --arg c "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"],\"provision\":false}" '[$c]')
RSTART=$(bc_call liblogos_rln_module start "$START_ARGS") || RSTART=""
case "$RSTART" in
    *'"started":true'*) say "basecamp: rln module started (provision off)" ;;
    *) die "basecamp: rln module start failed: ${RSTART:-<empty>}" ;;
esac

# ---------- 1. the UI mounts ------------------------------------------------------
section "1. $UI_NAME mounts (every declared dependency resolves)"
BCLOG=$(basecamp_log_path "$BC")
bc_eval "backend.loadUiModule('$UI_NAME')" >/dev/null
MOUNTED=""
for _t in $(seq 1 30); do
    if grep -q "has missing deps" "$BCLOG" 2>/dev/null && grep "has missing deps" "$BCLOG" | grep -q "$UI_NAME"; then
        die "$UI_NAME: $(grep "has missing deps" "$BCLOG" | grep "$UI_NAME" | tail -1)"
    fi
    grep -q "Failed to load UI module.*$UI_NAME\|Failed to load UI module \"$UI_NAME\"" "$BCLOG" 2>/dev/null \
        && die "$UI_NAME: $(grep "Failed to load UI module" "$BCLOG" | tail -1)"
    if grep -q "Successfully loaded UI module: \"\?$UI_NAME" "$BCLOG" 2>/dev/null; then
        MOUNTED=log; break
    fi
    LAUNCH=$(bc_eval "JSON.stringify(backend.launcherApps)") || LAUNCH=""
    case "$LAUNCH" in *"$UI_NAME"*) MOUNTED=launcherApps; break ;; esac
    sleep 2
done
[ -n "$MOUNTED" ] || die "$UI_NAME never mounted within 60s (no load line, not in launcherApps) — log tail: $(tail -3 "$BCLOG")"
say "$UI_NAME mounted (seen via $MOUNTED), no missing-deps popup"

# ---------- the allowlisted address is the module's own --------------------------
ADDR_JSON=$(bc_call eth_sign_module address) || ADDR_JSON=""
ADDR=$(printf '%s' "$ADDR_JSON" | jfield address)
case "$ADDR" in 0x*) ;; *) die "eth_sign_module address gave no address: ${ADDR_JSON:-<empty>}" ;; esac
say "eth_sign_module address: $ADDR ($(printf '%s' "$ADDR_JSON" | jfield persisted | sed 's/^/persisted=/'))"
serve "$ADDR"

# ---------- 2. Tier 1: the UI's delegated options -----------------------------------
section "2. Tier 1: register_membership with the UI's eth options"
ui_opts() {
    jq -cn --arg r "$UI_RATE" --arg p "$GPEER" --arg m "$GADDR" \
        '[{key:"rate_limit",value:$r},{key:"delegated",value:"true"},{key:"gifter_peer_id",value:$p},
          {key:"gifter_multiaddr",value:$m},{key:"auth_type",value:"eth-allowlist"},
          {key:"auth_provider",value:"eth_sign_module"}]'
}
register() {
    bc_call liblogos_rln_module register_membership \
        "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$1" --arg o "$(ui_opts)" '[$r,$i,$o]')"
}
# Usage: await_state <rln_id> <want-regex> -> sets STATE/GMS
await_state() {
    STATE=""; GMS=""
    for _t in $(seq 1 "$(polls "$REG_WAIT_S" "$E2E_POLL_INTERVAL_S")"); do
        GMS=$(bc_call liblogos_rln_module get_membership_state \
            "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$1" '[$r,$i]')") || GMS=""
        STATE=$(printf '%s' "$GMS" | grep -oE '"state":"[a-z_]+"' | head -1 | cut -d'"' -f4)
        printf '%s' "$STATE" | grep -qE "^($2)$" && return 0
        sleep "$E2E_POLL_INTERVAL_S"
    done
    return 1
}
RLN_ID=$(openssl rand -hex 32)
DREG=$(register "$RLN_ID") || DREG=""
case "$DREG" in
    *'"state":"pending"'*|*'"state":"active"'*) say "delegated register_membership accepted: $(printf '%s' "$DREG" | jfield state)" ;;
    *) die "delegated register_membership failed: ${DREG:-<empty>}" ;;
esac
await_state "$RLN_ID" "active|grace_period|failed" \
    || die "membership never settled within ${REG_WAIT_S}s (last: ${STATE:-<none>} — $GMS)"
[ "$STATE" != failed ] || die "Tier 1 registration FAILED: $(bc_call liblogos_rln_module get_memberships "$(jq -cn --arg r "$REGISTRY_ID" '[$r]')")"
LEAF=$(printf '%s' "$GMS" | jfield leaf_index)
say "Tier 1: membership $STATE at leaf $LEAF"
GBAL1=$(gbal)
PAID=$(( GBAL0 - GBAL1 ))
EXPECTED=$(( UI_RATE * PRICE ))
[ "$PAID" -ge "$EXPECTED" ] \
    || die "the allocator paid $PAID, less than the price $EXPECTED (rate $UI_RATE x $PRICE) — leaf $LEAF not paid from $GPAYER"
say "allocator paid $PAID = price $EXPECTED + fee $(( PAID - EXPECTED ))"
BCBAL1=$(bc_payer_balance)
[ "$BCBAL1" = "$BCBAL0" ] || die "basecamp's payer moved ($BCBAL0 -> $BCBAL1) across a delegated registration"
say "basecamp payer still holds $BCBAL1 — it paid nothing"

# ---------- 3. negative: a different allowlist refuses the module's key ---------------
section "3. the module key is what signed: another allowlist refuses it"
serve "0x000000000000000000000000000000000000dead"
RLN_ID2=$(openssl rand -hex 32)
DREG2=$(register "$RLN_ID2") || DREG2=""
say "second register_membership: ${DREG2:-<empty>}"
case "$DREG2" in
    *'not allowlisted'*) NEG="refused at register: $(printf '%s' "$DREG2" | head -c 200)" ;;
    *'"state":"pending"'*)
        # Follow this record by its own hash: a scope lookup can be ambiguous
        # once the first (delegated) membership exists, so get_membership_state
        # is logged, not relied on.
        H2=$(printf '%s' "$DREG2" | jfield membership_hash)
        [ -n "$H2" ] || die "second registration reply carries no membership_hash: $DREG2"
        say "scope lookup for the second rln_identifier: $(bc_call liblogos_rln_module get_membership_state \
            "$(jq -cn --arg r "$REGISTRY_ID" --arg i "$RLN_ID2" '[$r,$i]')" | head -c 300)"
        REC=""
        for _t in $(seq 1 "$(polls "$REG_WAIT_S" "$E2E_POLL_INTERVAL_S")"); do
            MEMS=$(bc_call liblogos_rln_module get_memberships "$(jq -cn --arg r "$REGISTRY_ID" '[$r]')") || MEMS=""
            REC=$(printf '%s' "$MEMS" | jq -c --arg h "$H2" '[.memberships[]? | select(.membership_hash == $h)] | first // empty' 2>/dev/null)
            STATE=$(printf '%s' "$REC" | jq -r '.state // empty' 2>/dev/null)
            case "$STATE" in failed|active|grace_period) break ;; esac
            sleep "$E2E_POLL_INTERVAL_S"
        done
        [ "$STATE" = failed ] \
            || die "second registration ($H2) did not fail (state ${STATE:-<none>}; record ${REC:-<none>}; memberships ${MEMS:0:400})"
        case "$REC" in
            *'not allowlisted'*) NEG="failed: $(printf '%s' "$REC" | jq -r '.failed_reason // .error // empty')" ;;
            *) die "second registration failed, but not as 'not allowlisted': $REC" ;;
        esac ;;
    *) die "second register_membership: unexpected reply ${DREG2:-<empty>}" ;;
esac
say "negative: $NEG"
[ "$(gbal)" = "$GBAL1" ] || die "the allocator paid for a refused request ($GBAL1 -> $(gbal))"

# ---------- 4. Tier 2 (non-blocking) -------------------------------------------------
section "4. Tier 2: the UI's flowController through the inspector object tree"
TIER2=$(python3 - "$(bc_port "$BC")" <<'EOF'
import json, socket, sys, time
port = int(sys.argv[1])
deadline = time.time() + 10
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(5)
    f = s.makefile("rwb")
    f.write((json.dumps({"id": 7, "command": "findByProperty",
                         "params": {"property": "objectName", "value": "flowController"}}) + "\n").encode())
    f.flush()
    while time.time() < deadline:
        line = f.readline()
        if not line:
            break
        d = json.loads(line.decode())
        if d.get("id") != 7:
            continue
        r = d.get("result") or d.get("matches")
        if r and not d.get("error") and d.get("ok", True):
            print("reachable " + json.dumps(r)[:200])
            sys.exit(0)
        print("TIER2_SKIPPED=sandbox-unreachable " + json.dumps(d)[:200])
        sys.exit(0)
except Exception as e:
    print("TIER2_SKIPPED=sandbox-unreachable %s" % e)
    sys.exit(0)
print("TIER2_SKIPPED=sandbox-unreachable (no reply within 10s)")
EOF
)
say "Tier 2: $TIER2"
jq -n --arg mounted "$MOUNTED" --arg leaf "$LEAF" --arg paid "$PAID" --arg neg "$NEG" --arg t2 "$TIER2" \
    '{ui_mounted:$mounted, tier1:{state:"active", leaf:$leaf, allocator_paid:$paid}, negative:$neg, tier2:$t2}' > "$SUMMARY"

echo
echo "e2e: PASS — membership-ui-gifter (target $E2E_TARGET)"
echo "e2e:   ui        $UI_NAME mounted in headless Basecamp with all six declared deps installed"
echo "e2e:   tier1     the UI's eth options (rate $UI_RATE, delegated, eth-allowlist via eth_sign_module) -> active at leaf $LEAF; allocator paid $PAID, basecamp paid nothing"
echo "e2e:   negative  allowlist without $ADDR -> $NEG"
echo "e2e:   tier2     $TIER2"
