#!/usr/bin/env bash
# scenarios/rln-allocator — a third-party RLN membership allocator, on chain,
# serving two registries. What logos-rln-gifter's tools/allocator/
# verify-chainless.sh proves against a stub registry, with real ones; see that
# repo's docs/running-an-allocator.md.
#
# Topology:
#   b   a bootstrap peer: libp2p_module alone with service discovery
#       mounted — the registrar the allocator's advertisement lands on and
#       the clients' lookups ask (an allocator registers with the peers in
#       its routing table at advertise time, so one must be there first).
#   g   the allocator: liblogos_lez_rln_module + libp2p_module +
#       rln_gifter_module + rln_auth_module, its own funded payer, a libp2p
#       identity from a persisted private key (a stable PeerId), serving the
#       default registry D and the mix registry M with the peer-any and
#       eth-allowlist verifiers and a consumed-nullifiers file, advertising
#       what it serves under /logos/rln/membership/1.0.0.
#   c1, c2  clients: the RLN stack (never funded; their lez module only
#       reads) + libp2p_module + rln_gifter_module (the client half) +
#       rln_sign_module (the eth producer), bootstrapped to b and told no
#       allocator peer id.
#
# Every registration goes through liblogos_rln_module.register_membership
# (delegated), the path an application takes: the module mints the commitment,
# names its scope's registry to the gifter, and confirms from the registry.
#
# What it proves:
#   0. serve advertises the served (registry, auth type) pairs and a client
#      discovers the allocator for each pair it asks about, nothing for a
#      pair nobody serves;
#   1. c1 gets a membership on D with peer-any, from an allocator it
#      DISCOVERED: no key material beyond its libp2p identity, a constant
#      payload; the leaf is the chain's;
#   2. the same peer asking D again is refused "credential already used"
#      (<D>:peer-any:<peer>) and the allocator pays nothing;
#   3. the same peer gets a membership on M: one per peer PER REGISTRY, the
#      request naming its registry;
#   4. another peer (c2) gets one on D through the configured pair alone
#      (discovery off), the fallback path;
#   5. eth-allowlist through the real producer: c1's rln_sign_module address
#      is allowlisted and lands; c2's is not and is refused by name;
#   6. a request naming a registry the allocator does not serve is refused
#      "registry not served" at once, and an invalid commitment never leaves
#      the client — nothing paid for either;
#   7. the allocator restarts on the same key: the same PeerId, re-served, c1
#      is still refused on D (the spent record survived) and c2 lands on M;
#   8. the allocator's payer paid for exactly the five memberships it granted.
#
# Required:
#   LIBP2P_LGX | LIBP2P_MODULE_CHECKOUT (libp2p_module >= 1.1.0: the accepted
#   stream reports the peer id), GIFTER_LGX, AUTH_LGX, SIGN_LGX |
#   GIFTER_CHECKOUT (logos-rln-gifter refactor/auth-vector-pipeline:
#   rln_gifter_module >= 0.5.0 (discovery), rln_auth_module >= 0.2.0,
#   rln_sign_module >= 0.2.0), liblogos_rln_module >= 0.15.0 (delegated
#   registration discovers).
#
# Env beyond docs/contract.md:
#   E2E_ALLOC_PORT=62200     the gifter's libp2p port (+1, +2: the clients',
#                            +3: the bootstrap peer's)
#   E2E_REG_WAIT_S=300       budget for a delegated registration to settle
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain registry; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE=100
GPORT="${E2E_ALLOC_PORT:-62200}"
GADDR="/ip4/127.0.0.1/tcp/$GPORT"
BADDR="/ip4/127.0.0.1/tcp/$(( GPORT + 3 ))"
SERVICE_ID="/logos/rln/membership/1.0.0"
REG_WAIT_S="${E2E_REG_WAIT_S:-300}"
D_EPOCH="${E2E_DELIVERY_EPOCH_SIZE_SEC:-600}"
M_EPOCH="${E2E_MIX_EPOCH_SIZE_SEC:-10}"
M_GAP="${E2E_MIX_MAX_EPOCH_GAP:-3}"
trap 'daemon_stop_all' EXIT

case " ${E2E_REGISTRIES:-default} " in
    *" mix "*) ;;
    *) die "this scenario needs the mix registry (REGISTRIES=\"default mix\"; E2E_REGISTRIES=${E2E_REGISTRIES:-<unset>})" ;;
esac
D=$(registry_id default) || exit 1
M=$(registry_id mix) || exit 1
D_CFG=$(registry_config_account default) || exit 1
M_CFG=$(registry_config_account mix) || exit 1
# The hex the gifter keys its registries and spent credentials by.
D_HEX="${D##*:}"
M_HEX="${M##*:}"
say "registries: D $D, M $M"

# The peer-any payload is the bare frame: version 2, no part, no evidence,
# rate_max as u64 little-endian.
PEER_PAYLOAD=$(python3 -c 'import struct, sys; print("02" + struct.pack("<Q", int(sys.argv[1])).hex())' "$RATE")
# A commitment below the BN254 field modulus. The registry reads it
# little-endian, so the zero byte that keeps it there is the LAST one.
new_idc() { printf '%s00' "$(openssl rand -hex 31)"; }
new_rid() { openssl rand -hex 32; }

# ---------- the bootstrap peer -----------------------------------------------------
section "bootstrap peer (b)"
daemon_start b || die "daemon_start b failed"
daemon_load_modules b libp2p_module || die "b: load-module failed"
node_call b libp2p_module createNode "{\"addrs\":[\"$BADDR\"],\"transport\":\"tcp\",\"mountServiceDiscovery\":true}" | jres >/dev/null \
    || die "b: libp2p createNode failed"
node_call b libp2p_module start | jres >/dev/null || die "b: libp2p start failed"
BPEER=$(node_call b libp2p_module peerInfo | jres | jval | jfield peerId) || BPEER=""
[ -n "$BPEER" ] || die "b: no peerId"
# Every other node's libp2p: discovery mounted, bootstrapped to b.
disco_node_config() {
    printf '{"addrs":["%s"],"transport":"tcp","mountServiceDiscovery":true,"bootstrapNodes":[{"peerId":"%s","addrs":["%s"]}]%s}' \
        "$1" "$BPEER" "$BADDR" "${2:+,$2}"
}
say "bootstrap peer $BPEER @ $BADDR"

# ---------- the allocator ----------------------------------------------------------
section "allocator (g)"
daemon_self_paying g "$E2E_RUN_DIR/wallet-g"
daemon_start g || die "daemon_start g failed"
g_modules() {
    daemon_load_modules g liblogos_lez_rln_module libp2p_module rln_gifter_module rln_auth_module \
        || die "g: load-module failed"
    wallet_open g || die "g: wallet open failed"
    wallet_sync g >/dev/null || die "g: wallet sync failed"
}
g_modules
PRICE=$(node_call g liblogos_lez_rln_module get_registry_bounds "$(argfile gcfg "$D_CFG")" | jres | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in the registry bounds"
GPAYER=$(wallet_payer g) || die "g published no payer"
wallet_fund g >/dev/null || die "funding the allocator's payer never landed"
gbal() { wallet_native_balance g "$GPAYER"; }
GBAL0=$(gbal)
say "allocator payer $GPAYER holds $GBAL0; price $PRICE per unit"

KEYFILE="$E2E_RUN_DIR/allocator-node-key.hex"
# libp2p's own key encoding: a protobuf PrivateKey { Type = Secp256k1 (2),
# Data = 32 bytes }, hex. Minted here rather than by libp2p_module's
# newPrivateKey, which answers success:false on some builds.
printf '08021220%s' "$(openssl rand -hex 32)" > "$KEYFILE"
NULLIFIERS="$E2E_RUN_DIR/allocator-nullifiers"
g_up() {
    node_call g libp2p_module createNode "$(disco_node_config "$GADDR" "\"privKey\":\"$(cat "$KEYFILE")\"")" | jres >/dev/null \
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
# Usage: g_serve <allowlisted eth address> <label>
# advertise:true explicitly: a node that cannot advertise must fail serve,
# not serve unfound.
g_serve() {
    local body res
    body=$(jq -cn --arg d "$D_CFG" --arg m "$M_CFG" --arg w "$GPAYER" --arg a "$1" --arg n "$NULLIFIERS" --argjson r "$RATE" \
        '{config:$d, registries:[{config:$m, maxRateLimit:$r}], wallet:$w, consumedNullifiersPath:$n, maxRateLimit:$r, advertise:true,
          authVerifiers:{"peer-any":{module:"rln_auth_module", config:{}},
                         "eth-allowlist":{module:"rln_auth_module", config:{allowlist:[$a]}}}}')
    local raw
    raw=$(node_call g rln_gifter_module serve "$body") || raw=""
    res=$(printf '%s' "$raw" | jres) || res=""
    case "$res" in
        *mounted*true*"$M_HEX"*) ;;
        *) die_node g "serve failed or does not list M: ${res:-<empty>} (cli: ${raw:-<nothing>})" ;;
    esac
    case "$res" in
        *'"advertised":true'*"$SERVICE_ID"*) say "g: serving D and M ($2), advertised: $res" ;;
        *) die_node g "serve did not advertise: $res" ;;
    esac
}
GPEER=$(g_up)
[ -n "$GPEER" ] || die "g: no peerId"
say "allocator peer $GPEER @ $GADDR"

# ---------- the clients --------------------------------------------------------------
section "clients (c1, c2): never funded"
# Usage: assert_deps_loaded <node>
# load-module liblogos_rln_module brings the allocator client and libp2p
# with it (declared dependencies, loaded by logoscore): the CLI's reply in
# the node log names both under dependencies_loaded.
assert_deps_loaded() {
    local loaded name
    loaded=$(node_logs "$1" | grep -m1 '"module":"liblogos_rln_module"' | python3 -c '
import json, sys
line = sys.stdin.read().strip()
print(" ".join(sorted(json.loads(line).get("dependencies_loaded", []))) if line else "")') || loaded=""
    for name in rln_gifter_module libp2p_module; do
        case " $loaded " in
            *" $name "*) ;;
            *) die "$1: loading liblogos_rln_module did not bring $name along (dependencies_loaded: '$loaded')" ;;
        esac
    done
    say "$1: loading liblogos_rln_module loaded [$loaded]"
}
START_CFG="{\"epoch_size_sec\":$D_EPOCH,\"registries\":[\"$D\",{\"registry_id\":\"$M\",\"epoch_size_sec\":$M_EPOCH,\"max_epoch_gap\":$M_GAP}],\"provision\":false}"
# Usage: client_up <node> <port>   -> sets CLIENT_PEER (not a command
# substitution: the node's registration must land in this shell)
client_up() {
    local node="$1" port="$2" started peer
    daemon_self_paying "$node" "$E2E_RUN_DIR/wallet-$node"
    daemon_start "$node" || die "daemon_start $node failed"
    # rln_gifter_module and libp2p_module are liblogos_rln_module's declared
    # dependencies: logoscore loads them with it.
    daemon_load_modules "$node" liblogos_lez_rln_module liblogos_rln_module rln_sign_module \
        || die "$node: load-module failed"
    assert_deps_loaded "$node"
    wallet_open "$node" || die "$node: wallet open failed"
    wallet_sync "$node" >/dev/null || die "$node: wallet sync failed"
    node_call "$node" libp2p_module createNode "$(disco_node_config "/ip4/127.0.0.1/tcp/$port")" | jres >/dev/null \
        || die "$node: libp2p createNode failed"
    node_call "$node" libp2p_module start | jres >/dev/null || die "$node: libp2p start failed"
    peer=$(node_call "$node" libp2p_module peerInfo | jres | jval | jfield peerId) || peer=""
    [ -n "$peer" ] || die "$node: no peerId"
    # provision:false: the clients never self-provision; every membership
    # comes from the allocator.
    started=$(node_call "$node" liblogos_rln_module start "$START_CFG" | jres | jval) || started=""
    case "$started" in *'"started":true'*) ;; *) die "$node: rln start failed: ${started:-<empty>}" ;; esac
    say "$node: up, peer $peer, rln started on D and M (provision off)"
    CLIENT_PEER="$peer"
}
client_up c1 $(( GPORT + 1 )); C1PEER="$CLIENT_PEER"
client_up c2 $(( GPORT + 2 )); C2PEER="$CLIENT_PEER"
[ "$C1PEER" != "$C2PEER" ] || die "c1 and c2 share a peer id"
# Usage: eth_address <node> -> the node's rln_sign_module eth identity
eth_address() { node_call "$1" rln_sign_module identity '{"scheme":"eth"}' | jres | jfield id; }
ADDR_C1=$(eth_address c1); ADDR_C2=$(eth_address c2)
[ -n "$ADDR_C1" ] && [ -n "$ADDR_C2" ] && [ "$ADDR_C1" != "$ADDR_C2" ] \
    || die "the clients' eth identities are not two addresses: '$ADDR_C1' / '$ADDR_C2'"
say "eth identities: c1 $ADDR_C1 (allowlisted), c2 $ADDR_C2 (not)"
g_serve "$ADDR_C1" "peer-any + eth-allowlist[$ADDR_C1]"

# ---------- 0. discovery -------------------------------------------------------------
section "0. the clients discover the allocator per (registry, auth type)"
# Usage: discovered <node> <config account> <auth type> -> the candidate peer ids
discovered() {
    node_call "$1" rln_gifter_module discover "$(jq -cn --arg c "$2" --arg t "$3" '{config:$c, authType:$t}')" | jres \
        | jq -r '.candidates[].peerId' 2>/dev/null
}
for pair in "$D_CFG peer-any" "$M_CFG eth-allowlist"; do
    set -- $pair
    found=$(discovered c1 "$1" "$2") || found=""
    [ "$found" = "$GPEER" ] || die_node c1 "discover $2 on ${1:0:12}… found '${found:-nothing}', not $GPEER"
    say "c1 discovered $GPEER for $2 on ${1:0:12}…"
done
UNSERVED=$(printf 'e%.0s' $(seq 1 64))
found=$(discovered c2 "$UNSERVED" peer-any) || found=""
[ -z "$found" ] || die_node c2 "discover found '$found' for a registry nobody serves"
found=$(discovered c2 "$D_CFG" keycard-attestation) || found=""
[ -z "$found" ] || die_node c2 "discover found '$found' for an auth type the allocator does not verify"
say "c2 discovered nothing for an unserved registry and an unverified auth type"

# ---------- helpers ------------------------------------------------------------------
# Usage: delegated <node> <registry_id> <rln_id> <auth_type> <payload-hex or ""> <provider or ""> [pinned]
# Drives register_membership and polls get_membership_state BY SCOPE until it
# settles — the scope's own record answers whatever else the registry holds
# (liblogos_rln_module >= 0.14.4; before, a second record on the registry
# made the scope ambiguous). The allocator is DISCOVERED (no gifter_* keys);
# with [pinned] it is the configured pair alone, discovery off. Sets STATE
# (active|grace_period|failed|…), MS (the record, read back by
# membership_hash) and REASON.
delegated() {
    local node="$1" reg="$2" rid="$3" atype="$4" payload="$5" provider="$6" pinned="${7:-}" opts reg_reply
    opts=$(jq -cn --arg r "$RATE" --arg p "$GPEER" --arg m "$GADDR" --arg t "$atype" --arg pl "$payload" --arg pr "$provider" --arg pin "$pinned" '
        [{key:"rate_limit",value:$r},{key:"delegated",value:"true"},{key:"auth_type",value:$t}]
        + (if $pin != "" then [{key:"discover",value:"false"},{key:"gifter_peer_id",value:$p},{key:"gifter_multiaddr",value:$m}] else [] end)
        + (if $pl != "" then [{key:"auth_payload",value:$pl}] else [] end)
        + (if $pr != "" then [{key:"auth_provider",value:$pr}] else [] end)')
    reg_reply=$(node_call "$node" liblogos_rln_module register_membership "$reg" "$(argfile rid "$rid")" "$opts" | jres) || reg_reply=""
    case "$reg_reply" in
        *'"state":"pending"'*|*'"state":"active"'*) ;;
        *) die_node "$node" "register_membership on ${reg:0:18}…: ${reg_reply:-<empty>}" ;;
    esac
    local hash view
    hash=$(printf '%s' "$reg_reply" | jfield membership_hash)
    [ -n "$hash" ] || die_node "$node" "register_membership answered no membership_hash: $reg_reply"
    STATE=""; MS=""; REASON=""
    for _t in $(seq 1 "$(polls "$REG_WAIT_S" "$E2E_POLL_INTERVAL_S")"); do
        view=$(node_call "$node" liblogos_rln_module get_membership_state "$reg" "$(argfile st "$rid")" | jres) || view=""
        case "$view" in
            *ambiguous_selection*) die_node "$node" "get_membership_state by scope is ambiguous again: $view" ;;
        esac
        [ "$(printf '%s' "$view" | jfield membership_hash)" = "$hash" ] \
            || die_node "$node" "get_membership_state answers for another record than this scope's ($hash): $view"
        STATE=$(printf '%s' "$view" | jfield state)
        case "$STATE" in active|grace_period|failed) break ;; esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    MS=$(node_call "$node" liblogos_rln_module get_memberships "$reg" | jres \
        | jq -c --arg h "$hash" '.memberships[] | select(.membership_hash == $h)' 2>/dev/null) || MS=""
    REASON=$(printf '%s' "$MS" | jfield failed_reason)
}
# Usage: expect_active <node> <registry name> <auth_type> <payload> <provider> <label> [pinned]
# A delegated registration that must land: active, confirmed on the registry
# at the leaf the module reports. Sets LEAF.
expect_active() {
    local node="$1" name="$2" reg idc
    reg=$(registry_id "$name")
    delegated "$node" "$reg" "$(new_rid)" "$3" "$4" "$5" "${7:-}"
    case "$STATE" in
        active|grace_period) ;;
        *) die_node "$node" "$6: expected active, got '${STATE:-<none>}' after ${REG_WAIT_S}s: ${REASON:-$MS}" ;;
    esac
    LEAF=$(printf '%s' "$MS" | jfield leaf_index)
    idc=$(printf '%s' "$MS" | jq -r '.credential.identity_commitment' 2>/dev/null) || idc=""
    [ -n "$idc" ] && [ "$idc" != null ] || die_node "$node" "$6: the record names no identity_commitment: $MS"
    confirm_and_ready "$node" "$idc" "" "$6" "$name" || die "$6: the registry never confirmed ${idc:0:18}…"
    [ "$LEAF" = "$E2E_ACTUAL_LEAF" ] || die_node "$node" "$6: the module reports leaf ${LEAF:-<none>}, the registry holds $E2E_ACTUAL_LEAF"
    say "$6: $STATE at leaf $LEAF on $name"
}
# Usage: expect_refused <node> <registry name> <auth_type> <payload> <provider> <label> <reason needle>
# A delegated registration the allocator must refuse: failed, by that reason,
# with the allocator's balance unchanged.
expect_refused() {
    local node="$1" b0
    b0=$(gbal)
    delegated "$node" "$(registry_id "$2")" "$(new_rid)" "$3" "$4" "$5"
    [ "$STATE" = failed ] || die_node "$node" "$6: expected a refusal, got '${STATE:-<none>}': $MS"
    case "$REASON" in
        *"$7"*) say "$6: refused — $REASON" ;;
        *) die_node "$node" "$6: refused for the wrong reason: ${REASON:-<none>}" ;;
    esac
    [ "$(gbal)" = "$b0" ] || die "$6: the allocator paid for a refused request ($b0 -> $(gbal))"
}

# ---------- 1. peer-any on D ----------------------------------------------------------
section "1. c1: peer-any on D"
expect_active c1 default peer-any "$PEER_PAYLOAD" "" "c1 peer-any D"
LEAF_C1_D="$LEAF"

# ---------- 2. once per peer ---------------------------------------------------------------
section "2. c1 again on D: refused, nothing paid"
expect_refused c1 default peer-any "$PEER_PAYLOAD" "" "c1 peer-any D again" "credential already used: $D_HEX:peer-any:"

# ---------- 3. per registry ----------------------------------------------------------------
section "3. c1 on M: the same peer, another registry"
expect_active c1 mix peer-any "$PEER_PAYLOAD" "" "c1 peer-any M"

# ---------- 4. another peer, the configured pair ----------------------------------------------
section "4. c2: peer-any on D through the configured pair, discovery off"
expect_active c2 default peer-any "$PEER_PAYLOAD" "" "c2 peer-any D (pinned)" pinned
[ "$LEAF" != "$LEAF_C1_D" ] || die "c2 landed on c1's leaf $LEAF"

# ---------- 5. eth-allowlist through the producer -----------------------------------------------
section "5. eth-allowlist: c1's address is listed, c2's is not"
expect_active c1 default eth-allowlist "" rln_sign_module "c1 eth-allowlist D"
expect_refused c2 default eth-allowlist "" rln_sign_module "c2 eth-allowlist D" "address not allowlisted: $ADDR_C2"

# ---------- 6. refusals before any chain work ----------------------------------------------------
section "6. an unserved registry and an invalid commitment"
# Usage: raw_request <node> <config> <idc> [pinned] -> the gifter client's reply
raw_request() {
    local body
    body=$(jq -cn --arg p "$GPEER" --arg m "$GADDR" --arg c "$2" --arg i "$3" --arg pl "$PEER_PAYLOAD" --arg pin "${4:-}" --argjson r "$RATE" \
        '{config:$c, identityCommitment:$i, rate:$r, authType:"peer-any", authPayload:$pl}
         + (if $pin != "" then {discover:false, gifterPeerId:$p, gifterMultiaddr:$m} else {} end)')
    node_call "$1" rln_gifter_module request "$body" | jres
}
B0=$(gbal)
# Discovered: nobody advertises the registry, so nothing is dialled; pinned:
# the allocator refuses it by name.
R=$(raw_request c2 "$UNSERVED" "$(new_idc)") || R=""
case "$R" in
    *"no allocator granted and none is configured"*"no allocator advertises $UNSERVED/peer-any"*) say "unserved registry: $R" ;;
    *) die "a registry nobody advertises should find no allocator, got: ${R:-<no reply>}" ;;
esac
R=$(raw_request c2 "$UNSERVED" "$(new_idc)" pinned) || R=""
case "$R" in
    *"registry not served: $UNSERVED"*) say "unserved registry refused by the pinned allocator: $R" ;;
    *) die "a registry the allocator does not serve should be refused by name, got: ${R:-<no reply>}" ;;
esac
R=$(raw_request c2 "$D_CFG" "$(openssl rand -hex 31)ff") || R=""
case "$R" in
    *invalid_commitment*) say "invalid commitment refused before the dial: $R" ;;
    *) die "a commitment that is not a field element should be refused as invalid_commitment, got: ${R:-<no reply>}" ;;
esac
[ "$(gbal)" = "$B0" ] || die "the allocator paid for a refused request ($B0 -> $(gbal))"

# ---------- 7. restart on the same key ----------------------------------------------------------
section "7. allocator restart: same key, same PeerId, spent record kept"
daemon_restart g || die "g restart failed"
g_modules
GPEER2=$(g_up)
[ "$GPEER2" = "$GPEER" ] || die "the PeerId changed across a restart on the same key: $GPEER -> $GPEER2"
g_serve "$ADDR_C1" "after restart"
say "same PeerId after restart: $GPEER"
found=$(discovered c1 "$D_CFG" peer-any) || found=""
[ "$found" = "$GPEER" ] || die_node c1 "after the restart c1 discovers '${found:-nothing}', not $GPEER"
expect_refused c1 default peer-any "$PEER_PAYLOAD" "" "c1 peer-any D after restart" "credential already used: $D_HEX:peer-any:"
expect_active c2 mix peer-any "$PEER_PAYLOAD" "" "c2 peer-any M after restart"

# ---------- 8. the bill -----------------------------------------------------------------------
section "8. the allocator paid for exactly five memberships"
GRANTED=5
PAID=$(( GBAL0 - $(gbal) ))
EACH=$(( RATE * PRICE ))
[ "$PAID" -ge $(( GRANTED * EACH )) ] || die "paid $PAID, less than $GRANTED registrations' price ($(( GRANTED * EACH )))"
# One registration costs the price plus ~7.4e7 in fees: a sixth would put the
# bill past (N+1) prices plus N fees' worth of headroom.
[ "$PAID" -lt $(( (GRANTED + 1) * EACH + GRANTED * 100000000 )) ] || die "paid $PAID: more than $GRANTED registrations' worth"
say "allocator paid $PAID for $GRANTED memberships (price $EACH each, the rest fees)"

say "PASS — rln-allocator (target $E2E_TARGET): peer-any once per peer per registry (D and M), eth-allowlist \
through rln_sign_module, refusals free, the same PeerId and spent record across a restart, $GRANTED paid"
