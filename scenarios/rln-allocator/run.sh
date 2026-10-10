#!/usr/bin/env bash
# scenarios/rln-allocator — a third-party RLN membership allocator, on chain.
# What logos-rln-gifter's tools/allocator/verify-chainless.sh proves against a
# stub registry, with a real one; see that repo's docs/running-an-allocator.md.
#
# Topology:
#   g   the allocator: liblogos_lez_rln_module + liblogos_rln_module +
#       libp2p_module + rln_gifter_module + eth_auth_module, its own funded
#       payer, a libp2p identity from a persisted private key (a stable
#       PeerId), serving with an eth-allowlist verifier and a consumed-
#       nullifiers file.
#   c   a client: the same RLN stack (never funded; its lez module only reads)
#       + libp2p_module + rln_gifter_module (the client half).
#
# The signed requests go through rln_gifter_module.request with a commitment
# the test chooses: the eth-allowlist payload signs the commitment, and
# liblogos_rln_module mints the commitment inside register_membership, so no
# caller can sign it in advance — and no eth producer module exists to sign it
# during the call. The membership-module leg (register_membership -> pending
# -> active through a gifter) is delivery-rln-gifter's, on an open gifter.
#
# What it proves:
#   1. a request signed by a key that is not allowlisted is refused, and the
#      gifter pays nothing for it; so is an allowlisted request for a
#      commitment that is not a BN254 field element (liblogos_lez_rln_module
#      >= 5.1.0 refuses it before signing — before, the guest panicked on
#      chain and the registry module re-sent it five times, each charged);
#   2. client A's signed request lands: the registry holds the commitment at
#      the leaf the gifter answered;
#   3. the allocator restarts on the same key: the same PeerId, re-served, and
#      client B — still holding the old (peer id, multiaddr) — gets a membership;
#   4. A's address is refused after the restart ("credential already used"):
#      the spent-credential record survived it;
#   5. the gifter's payer paid for exactly the two memberships it granted;
#   6. (E2E_ALLOC_MISMATCH=1, the default) a client asking for a registry the
#      gifter does not serve: the gifter re-served open registers on ITS
#      registry, and the client's record for the other one goes from pending to
#      failed after the confirmation window. Pinned as observed — time and
#      failed_reason are reported.
#
# Required:
#   LIBP2P_LGX | LIBP2P_MODULE_CHECKOUT, GIFTER_LGX | GIFTER_CHECKOUT (>= 0.3.0),
#   ETH_AUTH_LGX (nix build logos-rln-gifter/rust/eth-auth-module#lgx), and
#   foundry's cast (CAST, default `cast`).
#
# Env beyond docs/contract.md:
#   E2E_ALLOC_PORT=62200     the gifter's libp2p port (+1: the client's)
#   E2E_ALLOC_MISMATCH=1     run the mismatched-registry case (0 skips it: it
#                            provisions a second deployment and waits out the
#                            300 s confirmation window)
#   E2E_REQ_WAIT_S=240       budget for a signed request to show on chain
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain delivery; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

CAST="${CAST:-cast}"
command -v "$CAST" >/dev/null || die "foundry's cast is needed to sign the eth-allowlist payloads (set CAST)"
[ -f "${ETH_AUTH_LGX:-}" ] || die "ETH_AUTH_LGX must name the eth_auth_module .lgx"
install_lgx "$ETH_AUTH_LGX"

RATE=100
GPORT="${E2E_ALLOC_PORT:-62200}"
CPORT=$(( GPORT + 1 ))
GADDR="/ip4/127.0.0.1/tcp/$GPORT"
REQ_WAIT_S="${E2E_REQ_WAIT_S:-240}"
MISMATCH="${E2E_ALLOC_MISMATCH:-1}"
trap 'daemon_stop_all' EXIT

REGISTRY_ID=$(delivery_registry_id)
CFG="$E2E_CONFIG_ACCOUNT"

# Signing keys: two allowlisted, one not. EIP-191 personal_sign over the
# commitment's lowercase hex (no 0x), which is what eth_auth_module verifies.
PK_A=0x4242424242424242424242424242424242424242424242424242424242424242
PK_B=0x4444444444444444444444444444444444444444444444444444444444444444
PK_X=0x4343434343434343434343434343434343434343434343434343434343434343
addr_of() { "$CAST" wallet address --private-key "$1" | tr 'A-F' 'a-f'; }
ADDR_A=$(addr_of "$PK_A"); ADDR_B=$(addr_of "$PK_B")
sign() { "$CAST" wallet sign --private-key "$1" "$2" | sed 's/^0x//'; }
# A commitment below the BN254 field modulus. The registry reads it
# little-endian, so the zero byte that keeps it there is the LAST one.
new_idc() { printf '%s00' "$(openssl rand -hex 31)"; }

# ---------- the allocator ----------------------------------------------------------
section "allocator (g)"
daemon_self_paying g "$E2E_RUN_DIR/wallet-g"
daemon_start g || die "daemon_start g failed"
g_modules() {
    daemon_load_modules g liblogos_lez_rln_module liblogos_rln_module libp2p_module \
        rln_gifter_module eth_auth_module || die "g: load-module failed"
    wallet_open g || die "g: wallet open failed"
    wallet_sync g >/dev/null || die "g: wallet sync failed"
}
g_modules
PRICE=$(node_call g liblogos_lez_rln_module get_registry_bounds "$(argfile gcfg "$CFG")" | jres | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in the registry bounds"
GPAYER=$(wallet_payer g) || die "g published no payer"
wallet_fund g >/dev/null || die "funding the allocator's payer never landed"
gbal() { wallet_native_balance g "$GPAYER"; }
GBAL0=$(gbal)
say "allocator payer $GPAYER holds $GBAL0; price $PRICE per unit"

KEYFILE="$E2E_RUN_DIR/allocator-node-key.hex"
# libp2p's own key encoding: a protobuf PrivateKey { Type = Secp256k1 (2),
# Data = 32 bytes }, hex. Minted here rather than by libp2p_module's
# newPrivateKey, which answers success:false on the upstream build.
printf '08021220%s' "$(openssl rand -hex 32)" > "$KEYFILE"
NULLIFIERS="$E2E_RUN_DIR/allocator-nullifiers"
SERVE_EAUTH=$(jq -cn --arg c "$CFG" --arg w "$GPAYER" --arg a "$ADDR_A" --arg b "$ADDR_B" --arg n "$NULLIFIERS" \
    '{config:$c, wallet:$w, consumedNullifiersPath:$n, maxRateLimit:100,
      authVerifiers:{"eth-allowlist":{module:"eth_auth_module", config:{allowlist:[$a,$b]}}}}')
g_up() {
    node_call g libp2p_module createNode \
        "{\"addrs\":[\"$GADDR\"],\"transport\":\"tcp\",\"privKey\":\"$(cat "$KEYFILE")\"}" | jres >/dev/null \
        || die "g: libp2p createNode failed"
    node_call g libp2p_module start | jres >/dev/null || die "g: libp2p start failed"
    local info
    info=$(node_call g libp2p_module peerInfo | jres | jval) || info=""
    # createNode takes a config it cannot parse and starts on defaults (a fresh
    # key, a random port), so check the node is the one asked for.
    case "$info" in
        *"/tcp/$GPORT"*) ;;
        *) die_node g "libp2p is not listening on $GADDR (createNode config rejected?): ${info:-<empty>}" ;;
    esac
    printf '%s' "$info" | jfield peerId
}
g_serve() {
    local res
    res=$(node_call g rln_gifter_module serve "$1" | jres) || res=""
    case "$res" in
        *mounted*true*) say "g: serving ($2)" ;;
        *) die_node g "serve failed: ${res:-<empty>}" ;;
    esac
}
GPEER=$(g_up)
[ -n "$GPEER" ] || die "g: no peerId"
g_serve "$SERVE_EAUTH" "eth-allowlist: $ADDR_A, $ADDR_B"
say "allocator peer $GPEER @ $GADDR"

# ---------- the client --------------------------------------------------------------
section "client (c)"
daemon_self_paying c "$E2E_RUN_DIR/wallet-c"
daemon_start c || die "daemon_start c failed"
daemon_load_modules c liblogos_lez_rln_module liblogos_rln_module libp2p_module rln_gifter_module \
    || die "c: load-module failed"
wallet_open c || die "c: wallet open failed"
wallet_sync c >/dev/null || die "c: wallet sync failed"
node_call c libp2p_module createNode "{\"addrs\":[\"/ip4/127.0.0.1/tcp/$CPORT\"],\"transport\":\"tcp\"}" | jres >/dev/null \
    || die "c: libp2p createNode failed"
node_call c libp2p_module start | jres >/dev/null || die "c: libp2p start failed"

# Usage: request <idc> <private key> -> the gifter's reply ("" when none came back
# within the CLI's deadline; the chain is the authority either way)
request() {
    local body
    body=$(jq -cn --arg p "$GPEER" --arg m "$GADDR" --arg i "$1" --arg s "$(sign "$2" "$1")" \
        '{gifterPeerId:$p, gifterMultiaddr:$m, identityCommitment:$i, rate:100,
          authType:"eth-allowlist", authPayload:$s}')
    node_call c rln_gifter_module request "$body" | jres
}
# Usage: onchain_leaf <idc> -> the leaf the registry holds it at, "" when absent
onchain_leaf() {
    local m
    m=$(node_call c liblogos_lez_rln_module get_membership "$(argfile oc_cfg "$CFG")" \
        "$(argfile oc_idc "$1")" | jres) || m=""
    [ "$(printf '%s' "$m" | jq -r '.registered' 2>/dev/null)" = "true" ] || return 0
    printf '%s' "$m" | jq -r '.leaf_index'
}
# Usage: await_onchain <idc> <label> -> sets LEAF, or dies. Not called in a
# command substitution: die must end the run, not a subshell.
await_onchain() {
    LEAF=""
    for _t in $(seq 1 "$(polls "$REQ_WAIT_S" "$E2E_POLL_INTERVAL_S")"); do
        LEAF=$(onchain_leaf "$1")
        [ -n "$LEAF" ] && return 0
        sleep "$E2E_POLL_INTERVAL_S"
    done
    die "$2: commitment ${1:0:10}… never registered on chain within ${REQ_WAIT_S}s"
}

# ---------- 1. not allowlisted --------------------------------------------------------
section "1. a key that is not allowlisted is refused"
B0=$(gbal)
IDC_X=$(new_idc)
R=$(request "$IDC_X" "$PK_X") || R=""
case "$R" in
    *"not allowlisted"*) say "refused: $R" ;;
    *) die "a non-allowlisted signature should be refused by name, got: ${R:-<no reply>}" ;;
esac
[ -z "$(onchain_leaf "$IDC_X")" ] || die "a refused request registered on chain anyway"
[ "$(gbal)" = "$B0" ] || die "the allocator paid for a refused request ($B0 -> $(gbal))"

# A's key, but a commitment above the field modulus (top byte, little-endian,
# past 0x30). A refusal before submission releases the credential, so A's key
# is still good for step 2.
IDC_BAD="$(openssl rand -hex 31)ff"
B0=$(gbal)
R=$(request "$IDC_BAD" "$PK_A") || R=""
case "$R" in
    *invalid_commitment*) say "refused before signing: $R" ;;
    *) die "a commitment that is not a field element should be refused as invalid_commitment, got: ${R:-<no reply>}" ;;
esac
[ "$(gbal)" = "$B0" ] || die "the allocator paid for an invalid commitment ($B0 -> $(gbal))"

# ---------- 2. client A ---------------------------------------------------------------
section "2. client A: signed request lands on chain"
IDC_A=$(new_idc)
R=$(request "$IDC_A" "$PK_A") || R=""
say "gifter reply: ${R:-<none within the CLI deadline>}"
await_onchain "$IDC_A" "client A"; LEAF_A="$LEAF"
RLEAF=$(printf '%s' "$R" | jfield leaf_index)
[ -z "$RLEAF" ] || [ "$RLEAF" = "$LEAF_A" ] || die "the gifter answered leaf $RLEAF, the registry holds $LEAF_A"
say "client A registered at leaf $LEAF_A"

# ---------- 3. restart on the same key ---------------------------------------------------
section "3. allocator restart: same key, same PeerId"
daemon_restart g || die "g restart failed"
g_modules
GPEER2=$(g_up)
[ "$GPEER2" = "$GPEER" ] || die "the PeerId changed across a restart on the same key: $GPEER -> $GPEER2"
g_serve "$SERVE_EAUTH" "eth-allowlist, after restart"
say "same PeerId after restart: $GPEER"
IDC_B=$(new_idc)
R=$(request "$IDC_B" "$PK_B") || R=""
await_onchain "$IDC_B" "client B"; LEAF_B="$LEAF"
say "client B, on the old (peer id, multiaddr), registered at leaf $LEAF_B"

# ---------- 4. spent credentials survive the restart --------------------------------------
section "4. A's credential is still spent"
B1=$(gbal)
IDC_A2=$(new_idc)
R=$(request "$IDC_A2" "$PK_A") || R=""
case "$R" in
    *"credential already used"*) say "refused: $R" ;;
    *) die "A's address should be refused as already used after the restart, got: ${R:-<no reply>}" ;;
esac
[ -z "$(onchain_leaf "$IDC_A2")" ] || die "a replayed credential registered on chain"
[ "$(gbal)" = "$B1" ] || die "the allocator paid for a replayed credential ($B1 -> $(gbal))"

# ---------- 5. the bill -----------------------------------------------------------------
section "5. the allocator paid for exactly two memberships"
PAID=$(( GBAL0 - $(gbal) ))
EACH=$(( RATE * PRICE ))
[ "$PAID" -ge $(( 2 * EACH )) ] || die "paid $PAID, less than two registrations' price ($(( 2 * EACH )))"
# One registration costs the price plus ~7.4e7 in fees: a third would put the
# bill past 3x the price plus two fees' worth of headroom.
[ "$PAID" -lt $(( 3 * EACH + 2 * 100000000 )) ] || die "paid $PAID: more than two registrations' worth"
say "allocator paid $PAID for 2 memberships (price $EACH each, the rest fees)"

# ---------- 6. a registry the allocator does not serve -------------------------------------
if [ "$MISMATCH" = 1 ]; then
    section "6. client asks for a registry the allocator does not serve"
    "$E2E_LEZ_RLN/tools/deployments/provision.sh" --name second --payer "$E2E_PAYER" \
        --adopt-wallet "$E2E_WALLET_HOME/storage.json" --sequencer "$E2E_SEQUENCER" \
        --outdir "$E2E_RUN_DIR/deployments-second" > "$E2E_RUN_DIR/provision-second.log" 2>&1 \
        || die "provisioning the second deployment failed (see provision-second.log)"
    CFG2=$(jq -r .config_account "$E2E_RUN_DIR/deployments-second/second/deployment.json")
    REGISTRY_ID2=$(E2E_CONFIG_ACCOUNT="$CFG2" delivery_registry_id)
    say "second registry $REGISTRY_ID2; the allocator serves $REGISTRY_ID"
    # Open, so the membership module's own delegated path can reach it (no eth
    # producer exists).
    g_serve "$(jq -cn --arg c "$CFG" --arg w "$GPAYER" '{config:$c, wallet:$w, maxRateLimit:100}')" "open"
    RLN_ID=$(delivery_rln_identifier)
    START=$(node_call c liblogos_rln_module start \
        "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID2\"],\"provision\":false}" | jres | jval) || START=""
    case "$START" in *'"started":true'*) ;; *) die "c: rln start failed: ${START:-<empty>}" ;; esac
    OPTS=$(jq -cn --arg p "$GPEER" --arg m "$GADDR" \
        '[{key:"rate_limit",value:"100"},{key:"delegated",value:"true"},{key:"gifter_peer_id",value:$p},{key:"gifter_multiaddr",value:$m}]')
    T0=$(date +%s)
    REG=$(node_call c liblogos_rln_module register_membership "$REGISTRY_ID2" "$(argfile mrid "$RLN_ID")" "$OPTS" | jres) || REG=""
    case "$REG" in *'"state":"pending"'*) say "accepted: $REG" ;; *) die "register_membership: ${REG:-<empty>}" ;; esac
    STATE=""
    for _t in $(seq 1 "$(polls 420 10)"); do
        STATE=$(node_call c liblogos_rln_module get_membership_state "$REGISTRY_ID2" "$(argfile mst "$RLN_ID")" \
            | jres | jfield state) || STATE=""
        case "$STATE" in failed|active|grace_period) break ;; esac
        sleep 10
    done
    T1=$(date +%s)
    REASON=$(node_call c liblogos_rln_module get_memberships "$REGISTRY_ID2" | jres \
        | jq -c '[.memberships[] | {state, failed_reason}]' 2>/dev/null) || REASON=""
    [ "$STATE" = "failed" ] || die "expected the mismatched registration to fail, it is '${STATE:-<none>}' after $(( T1 - T0 ))s: $REASON"
    say "mismatch: pending -> failed after $(( T1 - T0 ))s; record: $REASON"
fi

say "PASS — rln-allocator (target $E2E_TARGET): allowlisted requests landed on chain across a restart \
on the same PeerId (leaves $LEAF_A, $LEAF_B), refusals cost nothing, the allocator paid $PAID"
