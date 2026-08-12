#!/usr/bin/env bash
# scenarios/mix-core — the mix protocol over the libp2p_module with per-hop
# RLN backed by the real module stack. Every node is its own economic actor:
#
#   per node (serial): daemon + 4 modules -> FRESH wallet (create_new) -> sync
#   -> fresh holding -> faucet claim -> unlock_keystore -> register (the
#   membership module mints the credential in-module) -> active poll ->
#   on-chain confirmation barrier (distinct leaves)
#   then: createNode (mountMix, fixture nodekey/mixkey) -> rlnEnable (shared
#   scope) -> start -> rlnIsReady poll (membership active + valid-roots window
#   warm) -> prover warm-up -> self-exclusive nodepool mesh -> request/reply
#   roundtrips through the sphinx mix, echoed by the destination over a
#   mounted protocol.
#
# Per-hop RLN is what the roundtrip proves: every hop verifies the incoming
# proof with the cbind's zerokit verifier against the on-chain root window and
# fetches a fresh module-generated proof for the next hop — a delivered reply
# means module proofs verified at every hop of both legs.
#
# Node identities are the mix scenario's fixture table (nodekey -> peerId,
# mixkey); multiaddrs are this scenario's own (loopback tcp 61001+).
#
# The sphinx path is a fixed L=3 hops (libp2p_mix sphinx.nim PathLength). A
# node's pool must EXCLUDE itself: the path selector would happily pick self
# as the first request hop (or the SURB relay before the self terminus), and
# that hop is a self-dial the switch refuses. With self and the destination
# both out, a dial needs N-2 >= 3 relay identities: 5 live nodes. Smaller
# E2E_MIX_CORE_NODES requests run the floor.
#
# Env beyond docs/contract.md:
#   E2E_MIX_CORE_NODES=5            node count (fixture table caps at 5;
#                                   requests < 5 are raised to the mix floor)
#   E2E_MIX_CORE_ROUNDTRIPS=3       request/reply roundtrips to deliver
#   E2E_MIX_CORE_RATE_LIMIT=100     per-membership rate limit
#   E2E_MIX_CORE_READY_TIMEOUT_S=240  rlnIsReady budget per run (the module's
#                                   roots read is a 90s-budget chain call)
#   E2E_MIX_CORE_REPLY_GRACE_S=20   write-to-read grace per roundtrip (see the
#                                   Qt-thread note at roundtrip())
#   LIBP2P_LGX=<bundle>             libp2p_module bundle override
#   LIBP2P_MODULE_CHECKOUT=<dir>    checkout to nix-build #lgx from (default
#                                   ../logos-libp2p-module; see PINS.env for
#                                   becomes a PINS.env rev at push time)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done
# The 5-node fixture table (_mix_fixture: nodekey mixkey peerId).
# shellcheck source=/dev/null
. "$ROOT/scenarios/mix/lib/nodes.sh"
KEYS="$ROOT/scenarios/mix/keys.py"

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_POLL_INTERVAL_S" -ge 1 ] 2>/dev/null || die "E2E_POLL_INTERVAL_S must be a positive integer"
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target funding=$E2E_FUNDING — this scenario pays registrations from faucet claims"

REQ_NODES="${E2E_MIX_CORE_NODES:-5}"
case "$REQ_NODES" in ''|*[!0-9]*) die "E2E_MIX_CORE_NODES must be an integer" ;; esac
N="$REQ_NODES"
if [ "$N" -lt 5 ]; then
    say "E2E_MIX_CORE_NODES=$REQ_NODES is below the mix floor (sphinx L=3 needs 3 relays besides self and the destination) — running 5 nodes"
    N=5
fi
[ "$N" -le 5 ] || die "E2E_MIX_CORE_NODES=$N exceeds the 5-identity fixture table"
ROUNDTRIPS="${E2E_MIX_CORE_ROUNDTRIPS:-3}"
RATE_LIMIT="${E2E_MIX_CORE_RATE_LIMIT:-100}"
READY_TIMEOUT_S="${E2E_MIX_CORE_READY_TIMEOUT_S:-240}"
REPLY_GRACE_S="${E2E_MIX_CORE_REPLY_GRACE_S:-20}"
# The application rate-limit epoch: every proof generator and verifier of the
# mix network must share it (rlnEnable forwards it to the membership module).
EPOCH_SIZE_SEC=10
PROTO="/logos/e2e/mix-core-echo/1.0.0"
READ_MAX=65536
PORT_BASE=61000

# Poll count for a budget, floor 1.
polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

PUMP_PID=""
cleanup() {
    [ -n "$PUMP_PID" ] && kill "$PUMP_PID" 2>/dev/null
    daemon_stop_all
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
# ONE scope for the whole network: the rln_identifier is a public input of
# every proof (external nullifiers bind to it), so a hop verifying under a
# different identifier rejects everything.
RLN_ID=$(openssl rand -hex 32)
say "registry: $REGISTRY_ID"
say "scope rln_identifier: ${RLN_ID:0:16}… (shared by all $N nodes)"

# ---------- libp2p module bundle -------------------------------------------
section "artifacts: libp2p_module"
if [ -z "${LIBP2P_LGX:-}" ]; then
    # The checkout should match scenarios/mix-core/PINS.env.
    LIBP2P_CHECKOUT="${LIBP2P_MODULE_CHECKOUT:-$ROOT/../logos-libp2p-module}"
    [ -d "$LIBP2P_CHECKOUT" ] || die "no libp2p module checkout at $LIBP2P_CHECKOUT (set LIBP2P_LGX or LIBP2P_MODULE_CHECKOUT)"
    _out=$(nix build "$LIBP2P_CHECKOUT#lgx" --no-link --print-out-paths | tail -1) \
        || die "nix build $LIBP2P_CHECKOUT#lgx failed"
    LIBP2P_LGX=$(lgx_of "$_out")
fi
install_lgx "$LIBP2P_LGX"
say "installed $(basename "$LIBP2P_LGX")"

# ---------- fixture accessors ----------------------------------------------
node_of() { printf 'n%s' "$1"; }         # fixture idx (0-based) -> node id
fx_nodekey() { _mix_fixture "$1" | awk '{print $1}'; }
fx_mixkey()  { _mix_fixture "$1" | awk '{print $2}'; }
fx_peerid()  { _mix_fixture "$1" | awk '{print $3}'; }
node_maddr() { printf '/ip4/127.0.0.1/tcp/%s' $((PORT_BASE + $1 + 1)); }

# ---------- per-node chain lifecycle (serial: shared tree) ------------------
# Registrations are serialized behind confirm_and_ready so every membership
# lands on a DISTINCT leaf of the shared tree.
PRICE=""
setup_node() {
    local idx="$1" node home holding unlock reg commit state_json state leaf _t
    node=$(node_of "$idx")
    home="$E2E_RUN_DIR/wallet-homes/$node"

    section "$node: chain (fixture $idx)"
    local saved_home="$E2E_WALLET_HOME"
    E2E_WALLET_HOME="$home"
    daemon_start "$node"
    E2E_WALLET_HOME="$saved_home"
    daemon_load_modules "$node" logos_execution_zone liblogos_lez_rln_module \
        liblogos_rln_module libp2p_module

    # create_new leaves the fresh wallet OPEN in the daemon; no open() after
    # it (storage.json is not materialized synchronously, and open would
    # re-open over the live wallet anyway).
    wallet_create_new "$node" "$home"
    wallet_sync "$node" >/dev/null || die_node "$node" "wallet sync failed"

    holding=$(wallet_fresh_holding "$node") || holding=""
    [ -n "$holding" ] || die_node "$node" "no unused holding account"
    if [ -z "$PRICE" ]; then
        PRICE=$(node_call "$node" liblogos_lez_rln_module get_registry_bounds \
            "$(argfile bounds_cfg "$E2E_CONFIG_ACCOUNT")" | jres | jfield price_per_unit)
        [ -n "$PRICE" ] || die_node "$node" "get_registry_bounds gave no price_per_unit"
        say "price_per_unit $PRICE -> claim $((RATE_LIMIT * PRICE)) per node"
    fi
    wallet_claim_chunked "$node" "$E2E_CONFIG_ACCOUNT" "$holding" "$((RATE_LIMIT * PRICE))"

    unlock=$(node_call "$node" liblogos_rln_module unlock_keystore e2e-test-password | jres) || unlock=""
    case "$unlock" in
        *'"unlocked":true'*) ;;
        *) die_node "$node" "unlock_keystore failed: ${unlock:-<empty>}" ;;
    esac

    say "$node: register($REGISTRY_ID, rate $RATE_LIMIT)"
    reg=$(node_call "$node" liblogos_rln_module register \
        "$REGISTRY_ID" "$(argfile reg_rlnid "$RLN_ID")" "$RATE_LIMIT" \
        "{\"funding_holding_account_id\":\"$holding\"}" | jres) || reg=""
    case "$reg" in
        *'"state":"pending"'*|*'"state":"active"'*) ;;
        *) die_node "$node" "register failed: ${reg:-<empty>}" ;;
    esac
    commit=$(printf '%s' "$reg" | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("credential",{}).get("identity_commitment",""))' \
        2>/dev/null || true)
    [ -n "$commit" ] || die_node "$node" "register reply carries no identity_commitment: $reg"

    state=""
    for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        state_json=$(node_call "$node" liblogos_rln_module get_membership_state \
            "$REGISTRY_ID" "$(argfile state_rlnid "$RLN_ID")" | jres) || state_json=""
        state=$(printf '%s' "$state_json" | jfield state)
        case "$state" in
            active) break ;;
            failed) die_node "$node" "registration FAILED: $state_json" ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    [ "$state" = "active" ] || die_node "$node" "membership never became active (last: ${state:-<none>})"
    leaf=$(printf '%s' "$state_json" | jfield leaf_index)

    confirm_and_ready "$node" "$commit" "$leaf" "$node" \
        || die_node "$node" "membership never confirmed on the canonical tree"
    sv COMMIT "$node" "$commit"
    sv LEAF "$node" "$E2E_ACTUAL_LEAF"
    say "$node: ACTIVE at leaf $E2E_ACTUAL_LEAF"
}

# ---------- per-node mix bring-up -------------------------------------------
# Order matters: createNode applies the node config, rlnEnable must precede
# start (spam protection changes the wire packet size and cannot be toggled on
# a mounted mix protocol), start mounts mix on the listen address.
mixup_node() {
    local idx="$1" node nodekey mixkey peerid maddr res got
    node=$(node_of "$idx")
    nodekey=$(fx_nodekey "$idx"); mixkey=$(fx_mixkey "$idx"); peerid=$(fx_peerid "$idx")
    maddr=$(node_maddr "$idx")

    # JSON blobs go via @file (argjson): a bare {...} argument is parsed by
    # the CLI into a JSON object, not the string the module's dispatch takes.
    # privKey is the libp2p protobuf serialization: 08 02 (secp256k1) 12 20 <raw>.
    res=$(node_call "$node" libp2p_module createNode \
        "$(argjson create_node '{"addrs":["%s"],"privKey":"08021220%s","mountMix":true,"mixPrivKeyHex":"%s","mixMultiaddr":"%s"}' \
            "$maddr" "$nodekey" "$mixkey" "$maddr")" \
        | jres) || res=""
    case "$res" in *'"success":true'*) ;; *) die_node "$node" "createNode failed: ${res:-<empty>}" ;; esac

    res=$(node_call "$node" libp2p_module rlnEnable \
        "$(argjson rln_enable '{"registry_id":"%s","rln_identifier_hex":"%s","epoch_size_sec":%s}' \
            "$REGISTRY_ID" "$RLN_ID" "$EPOCH_SIZE_SEC")" \
        | jres) || res=""
    case "$res" in *'"success":true'*) ;; *) die_node "$node" "rlnEnable failed: ${res:-<empty>}" ;; esac

    res=$(node_call "$node" libp2p_module start | jres) || res=""
    case "$res" in *'"success":true'*) ;; *) die_node "$node" "libp2p start failed: ${res:-<empty>}" ;; esac

    got=$(node_call "$node" libp2p_module peerInfo | jres | jval | jfield peerId)
    [ "$got" = "$peerid" ] \
        || die_node "$node" "peerId drift: fixture $peerid, node reports ${got:-<none>}"

    sv MADDR "$node" "$maddr"
    sv PEERID "$node" "$peerid"
    sv MIXPUB "$node" "$(python3 "$KEYS" mixpub "$mixkey")"
    sv LPPUB "$node" "$(python3 "$KEYS" peerpub "$peerid")"
    say "$node: mix mounted on $maddr (peer ${peerid:0:16}…)"
}

# ---------- phases ----------------------------------------------------------
T_START=$(date +%s)
i=0
while [ "$i" -lt "$N" ]; do
    setup_node "$i"
    i=$((i + 1))
done
T_CHAIN=$(date +%s)
say "timing: chain phase (wallets + $N registrations) $((T_CHAIN - T_START))s"

section "mix bring-up"
i=0
while [ "$i" -lt "$N" ]; do
    mixup_node "$i"
    i=$((i + 1))
done

say "polling rlnIsReady on all nodes (budget ${READY_TIMEOUT_S}s)…"
i=0
while [ "$i" -lt "$N" ]; do
    node=$(node_of "$i")
    ready=""
    for _t in $(seq 1 "$(polls "$READY_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        ready=$(node_call "$node" libp2p_module rlnIsReady | jres | jval)
        [ "$ready" = "true" ] && break
        sleep "$E2E_POLL_INTERVAL_S"
    done
    [ "$ready" = "true" ] || die_node "$node" "rlnIsReady never turned true (membership/root-window)"
    say "$node: rlnIsReady"
    i=$((i + 1))
done

# Warm each node's prover: the first module proof pays the merkle-path read
# (90s-budget chain call), which would otherwise land inside a mix hop's 15s
# fetch window and drop the packet.
say "warming provers (one module proof per node)…"
WARM_SIG=$(printf 'mix-core warm' | to_hex)
i=0
while [ "$i" -lt "$N" ]; do
    node=$(node_of "$i")
    res=$(node_call "$node" liblogos_rln_module generate_proof \
        "$REGISTRY_ID" "$(argfile warm_rlnid "$RLN_ID")" "$(argfile warm_sig "$WARM_SIG")" \
        "str:$(date +%s)" | jres | jval) || res=""
    case "$res" in
        *'"proof"'*) ;;
        *) die_node "$node" "prover warm-up generate_proof failed: ${res:-<empty>}" ;;
    esac
    i=$((i + 1))
done
T_READY=$(date +%s)
say "timing: mix bring-up + ready + prover warm $((T_READY - T_CHAIN))s"

# Self-exclusive: nim's path selector treats every pool entry as a relay
# candidate, and self as the first hop (or a SURB relay) is a self-dial the
# switch refuses (see the sphinx note at the top).
section "mesh: nodepool ($N x $((N - 1)), self-exclusive)"
i=0
while [ "$i" -lt "$N" ]; do
    a=$(node_of "$i")
    j=0
    while [ "$j" -lt "$N" ]; do
        if [ "$j" -ne "$i" ]; then
            b=$(node_of "$j")
            res=$(node_call "$a" libp2p_module mixNodepoolAdd \
                "$(argjson pool_add '{"peerId":"%s","multiaddr":"%s","mixPubKey":"%s","libp2pPubKey":"%s"}' \
                    "$(gv PEERID "$b")" "$(gv MADDR "$b")" "$(gv MIXPUB "$b")" "$(gv LPPUB "$b")")" \
                | jres) || res=""
            case "$res" in *'"success":true'*) ;; *) die_node "$a" "mixNodepoolAdd($b) failed: ${res:-<empty>}" ;; esac
        fi
        j=$((j + 1))
    done
    i=$((i + 1))
done
say "meshed"

# The SURB exit is random, so every node registers how the exit reads the
# destination's reply. READ_LP end to end: LP frames survive the mix verbatim
# (the exit re-adds the prefix on the reply leg), so both sides use the
# JSON-blob stream calls.
i=0
while [ "$i" -lt "$N" ]; do
    node=$(node_of "$i")
    res=$(node_call "$node" libp2p_module mixRegisterDestReadBehavior \
        "$(argjson read_behavior '{"proto":"%s","behavior":1,"sizeParam":%s}' "$PROTO" "$READ_MAX")" | jres) || res=""
    case "$res" in *'"success":true'*) ;; *) die_node "$node" "mixRegisterDestReadBehavior failed: ${res:-<empty>}" ;; esac
    i=$((i + 1))
done

# ---------- traffic ---------------------------------------------------------
SRC=$(node_of 0)
DEST=$(node_of $((N - 1)))
section "traffic: $SRC -> $DEST, $ROUNDTRIPS request/reply roundtrip(s) over $PROTO"

res=$(node_call "$DEST" libp2p_module mountProtocol "$PROTO" | jres) || res=""
case "$res" in *'"success":true'*) ;; *) die_node "$DEST" "mountProtocol failed: ${res:-<empty>}" ;; esac

# Destination echo pump: the exit dials the destination once per roundtrip;
# accept -> read LP -> echo LP -> close. Background so the sender's dials and
# the accepts interleave.
PUMP_LOG="$E2E_RUN_DIR/mix-core-pump.log"
(
    # pump_-prefixed argfiles: the sender's rt_ argfiles are written
    # concurrently in the same args dir.
    #
    # Accepts poll in short windows: one long blocking accept outlives the
    # daemon's per-call wire deadline (~20s) and dies just before the exit's
    # dial lands, and its in-module wait would hold the destination's
    # dispatch thread the whole time.
    pump_ok=0
    for _r in $(seq 1 "$ROUNDTRIPS"); do
        sid=""
        _pump_deadline=$(($(date +%s) + 120))
        while [ "$(date +%s)" -lt "$_pump_deadline" ]; do
            acc=$(node_call "$DEST" libp2p_module protocolAcceptStream \
                "$(argjson pump_acc '{"proto":"%s","timeoutMs":10000}' "$PROTO")" | jres | jval) || acc=""
            sid=$(printf '%s' "$acc" | jfield streamId)
            case "$sid" in ''|*[!0-9]*) sid="" ;; *) break ;; esac
        done
        case "$sid" in
            '') printf 'pump: accept %s failed: no stream within 120s\n' "$_r"; continue ;;
        esac
        req=$(node_call "$DEST" libp2p_module streamReadLpJson \
            "$(argjson pump_read '{"streamId":%s,"maxSize":%s,"timeoutMs":30000}' "$sid" "$READ_MAX")" \
            | jres | jval | jfield dataB64)
        if [ -n "$req" ]; then
            node_call "$DEST" libp2p_module streamWriteLpJson \
                "$(argjson pump_write '{"streamId":%s,"dataB64":"%s"}' "$sid" "$req")" >/dev/null 2>&1
            pump_ok=$((pump_ok + 1))
            printf 'pump: echoed %s\n' "$_r"
        else
            printf 'pump: read %s failed\n' "$_r"
        fi
        node_call "$DEST" libp2p_module streamCloseJson \
            "$(argjson pump_close '{"streamId":%s}' "$sid")" >/dev/null 2>&1
        node_call "$DEST" libp2p_module streamReleaseJson \
            "$(argjson pump_rel '{"streamId":%s}' "$sid")" >/dev/null 2>&1
    done
    printf 'pump: done %s/%s\n' "$pump_ok" "$ROUNDTRIPS"
) >"$PUMP_LOG" 2>&1 &
PUMP_PID=$!

# One roundtrip: dial-with-reply -> LP-write the request (the sphinx packet is
# built and the entry proof fetched on this write) -> LP-read the SURB reply.
# The reply future is one-shot: N roundtrips = N dials.
#
# The module's QtRO dispatch and its RLN fetch-drain timer share one Qt
# thread, so any blocking stream call on the sender starves the drain that
# serves the sender's own proof fetches:
# - the write's C++ await always expires (~10s) while the entry proof fetch
#   waits for the drain the write itself blocks; the packet still goes out
#   once the await returns and the drain runs — treat the write as soft.
# - the reply read must not start until hops that may be the sender itself
#   (self-inclusive pool) have re-generated their proofs, so a grace sleep
#   separates write and read. Retrying short reads instead would be unsafe:
#   a timed-out nim read keeps running and consumes the reply.
roundtrip() {
    local k="$1" sid b64 wr reply
    sid=$(node_call "$SRC" libp2p_module mixDialWithReply \
        "$(argjson rt_dial '{"peerId":"%s","multiaddr":"%s","proto":"%s","expectReply":1,"numSurbs":1}' \
            "$(gv PEERID "$DEST")" "$(gv MADDR "$DEST")" "$PROTO")" \
        | jres | jval)
    case "$sid" in
        ''|*[!0-9]*) say "rt $k: mixDialWithReply failed: ${sid:-<empty>}"; return 1 ;;
    esac
    b64=$(printf 'mix-core rt %s' "$k" | base64)
    wr=$(node_call "$SRC" libp2p_module streamWriteLpJson \
        "$(argjson rt_write '{"streamId":%s,"dataB64":"%s"}' "$sid" "$b64")" | jres) || wr=""
    case "$wr" in
        *'"success":true'*) ;;
        *) say "rt $k: write reported: ${wr:-<empty>} (soft — the reply read decides)" ;;
    esac
    sleep "$REPLY_GRACE_S"
    # 25s: within the daemon's per-call wire deadline, so a missed reply frees
    # the module's dispatch thread when the CLI call returns instead of
    # holding it for a minute and starving the next roundtrip's dial. The
    # reply leg normally lands within seconds of the grace sleep.
    reply=$(node_call "$SRC" libp2p_module streamReadLpJson \
        "$(argjson rt_read '{"streamId":%s,"maxSize":%s,"timeoutMs":25000}' "$sid" "$READ_MAX")" \
        | jres | jval | jfield dataB64)
    node_call "$SRC" libp2p_module streamCloseJson \
        "$(argjson rt_close '{"streamId":%s}' "$sid")" >/dev/null 2>&1
    node_call "$SRC" libp2p_module streamReleaseJson \
        "$(argjson rt_rel '{"streamId":%s}' "$sid")" >/dev/null 2>&1
    if [ "$reply" = "$b64" ]; then
        say "rt $k: reply delivered"
        return 0
    fi
    say "rt $k: reply missing or mangled (want $b64, got '${reply:-}')"
    return 1
}

DELIVERED=0
k=1
while [ "$k" -le "$ROUNDTRIPS" ]; do
    roundtrip "$k" && DELIVERED=$((DELIVERED + 1))
    k=$((k + 1))
done
wait "$PUMP_PID" 2>/dev/null
PUMP_PID=""
T_TRAFFIC=$(date +%s)
say "timing: traffic $((T_TRAFFIC - T_READY))s"

# ---------- verdict ---------------------------------------------------------
section "verdict"
FAIL=0
[ "$DELIVERED" = "$ROUNDTRIPS" ] || { say "!! delivered $DELIVERED/$ROUNDTRIPS roundtrips"; FAIL=1; }

ACTIVE=0
printf 'e2e:   %-4s %-18s %-6s %-12s %s\n' node peer leaf membership rlnIsReady
i=0
while [ "$i" -lt "$N" ]; do
    node=$(node_of "$i")
    cross=$(node_call "$SRC" liblogos_lez_rln_module get_membership \
        "$(argfile verdict_cfg "$E2E_CONFIG_ACCOUNT")" "$(argfile verdict_idc "$(gv COMMIT "$node")")" \
        | jres) || cross=""
    m_state=$(printf '%s' "$cross" | jfield state)
    case "$cross" in
        *'"registered":true'*) ACTIVE=$((ACTIVE + 1)) ;;
        *) m_state="UNREGISTERED"; FAIL=1 ;;
    esac
    ready=$(node_call "$node" libp2p_module rlnIsReady | jres | jval)
    [ "$ready" = "true" ] || FAIL=1
    printf 'e2e:   %-4s %-18s %-6s %-12s %s\n' "$node" "$(gv PEERID "$node" | cut -c1-16)…" \
        "$(gv LEAF "$node")" "${m_state:-?}" "${ready:-?}"
    i=$((i + 1))
done
[ "$ACTIVE" = "$N" ] || say "!! only $ACTIVE/$N memberships registered on-chain"
say "pump: $(tail -1 "$PUMP_LOG" 2>/dev/null || echo '<no log>')"

[ "$FAIL" = 0 ] || die "mix-core FAILED (delivered $DELIVERED/$ROUNDTRIPS, on-chain $ACTIVE/$N)"
echo
echo "e2e: PASS — $DELIVERED/$ROUNDTRIPS mix roundtrips delivered across $N nodes"
echo "e2e:   registry   $REGISTRY_ID"
echo "e2e:   scope      ${RLN_ID:0:16}… (shared)"
echo "e2e:   total      $(( $(date +%s) - T_START ))s after target-up"
