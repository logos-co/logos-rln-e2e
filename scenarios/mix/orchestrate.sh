#!/usr/bin/env bash
# Run the 5-node gifted-RLN-over-mix E2E on testnet, via docker-compose (one
# logoscore daemon per container, all on a shared network).
#
# Every node obtains a DISTINCT RLN membership through a GIFTER
# (membership-allocation, LIP-158): relay1 is the gifter, the ONLY node holding
# the funded wallet. It self-allocates its own membership, then serves
# /logos/rln/membership/1.0.0; the other 4 nodes authenticate with an EIP-191-
# signed request and receive a gifted on-chain registration — they never fund or
# sign a tx. Every mix node ends up a member (per-hop RLN: each hop verifies the
# incoming proof AND regenerates one for the next hop). Then src and dest each do
# 3 request/reply round-trips over the 3-hop mix, RLN-enforced on both legs.
#
# Gifted allocation: the client derives its own identity locally (only the
# idCommitment is sent; the RLN secret never leaves the node). The gifter funds
# and signs register_member with its own wallet and returns the leaf. Distinct
# seeds -> distinct leaves. Registrations are serialized (each client's on-chain
# confirmation barrier passes before the next requests) to avoid nonce races on
# the single gifter wallet.
#
# Knobs:
#   NEG=0 (default) : the full happy-path E2E.
#   NEG=1 : leave the SENDER UNREGISTERED (never asks the gifter). Its mixDial
#           must be rejected (no valid proof) and not reach the dest.
#   NEG=2 : the sender asks the gifter with a NON-allowlisted key -> auth refused
#           -> sender stays unregistered -> rejected. Exercises the allocation
#           authentication gate specifically.
#   NEG=3 : keycard auth NOT mounted, but the sender presents a VALID synthetic
#           attestation -> "unsupported authentication_type" -> rejected.
#           (NEG=3 ignores KEYCARD: dest onboards via eth like before.)
#   KEYCARD=1 (default) : dest onboards via a SYNTHETIC keycard attestation and
#           its address is DROPPED from the allowlist (the card alone must
#           suffice); 4 auth-refusal probes run inline. Others stay EIP-191.
#   KEYCARD=0    : the all-EIP-191 behavior, byte-identical to before.
#   KEYCARD=real : dest onboards via a PHYSICAL Status Keycard over PC/SC
#           (kc-capture; IDENTIFY_CARD is a public command — no pairing/PIN.
#           Interactive TLV paste fallback when kc-capture isn't built).
#   KEYCARD_CLAMP=1   : post-verdict probe: a rate-600 keycard grant is clamped
#           to 100 by the gifter (costs one extra registration: +1M budget).
#   KEYCARD_PERSIST=1 : post-verdict probe: consumed card nullifiers survive a
#           gifter restart (consumedNullifiersPath reload).
# NEG=1/2/3 prove RLN gates delivery (vs the happy path where a member's msg lands).
#
# Roles: relay1 (gifter+relay) + relay2/relay3 + dest + sender — ALL RLN members.
# Setup order: rlnEnable MUST precede mixSetNodeInfo (factory read at mix mount).
# Mesh keys host-derived (keys.py). Node addr = /ip4/<container-ip>/tcp/9000.
# bash 3.2 (macOS): no assoc arrays; via sv/gv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DC="docker compose -f $HERE/docker-compose.yml"
KEYS="python3 $HERE/keys.py"
LOGOSCORE=/logoscore/bin/logoscore
NEG="${NEG:-0}"
KEYCARD="${KEYCARD:-1}"
KEYCARD_CLAMP="${KEYCARD_CLAMP:-0}"
KEYCARD_PERSIST="${KEYCARD_PERSIST:-0}"

# Fixed sim parameters (RATE must match the baked deployment's rate limit).
MSG_COUNT=3
PROTO="/ipfs/ping/1.0.0"
READ_SIZE=32
RATE=100
# Per-run RLNTOK budget put into a FRESH payment account at setup: a happy
# run does 5 registrations x (price_per_unit 10000 x RATE 100) = 5M, +1M slack.
# How the account is funded follows the deployment's funding mode (staged
# funding.txt): faucet deployments claim from the program's own payment PDA
# (no human mint key anywhere); wallet-key deployments mint with the
# definition key that ships in the deployment wallet. Either way any clone
# funds itself — no fixed pre-funded account to drain.
# (The rate-clamp extra registers one MORE membership, clamped to rate 100 =
# 1M, hence its higher default. A user-supplied MINT_AMOUNT always wins.)
if [ "$KEYCARD_CLAMP" = "1" ]; then MINT_AMOUNT="${MINT_AMOUNT:-7000000}"
else MINT_AMOUNT="${MINT_AMOUNT:-6000000}"; fi
# Faucet mode claims per-call amounts <= the deployment's faucet_claim_cap
# (shared-faucet's cap = the provision default 10M), so the budget is claimed
# in slices of at most CLAIM_CHUNK. Lower this if a deployment has a smaller cap.
CLAIM_CHUNK="${CLAIM_CHUNK:-10000000}"
RPC_URL="https://testnet.lez.logos.co/"
SYNC_STEP=3000
REG_RETRY_SLEEP=15
ALL="relay1 relay2 relay3 dest sender"
WALLET_MOD="logos_execution_zone"
RLN_MOD="liblogos_rln_module"
GIFTER_CODEC="/logos/rln/membership/1.0.0"

# relay1 is the gifter (membership provider). The other 4 nodes authenticate to
# it with a distinct EIP-191 key from the fixtures to receive a gifted on-chain
# registration. Fixtures are sourced host-side (orchestrate runs on the host);
# these keys never enter the image. relay1 needs no client key.
GIFTER="relay1"
FIX="$HERE/fixtures/gifter_auth"
[ -f "$FIX/keys.env" ] && . "$FIX/keys.env"
[ -f "$FIX/addresses.env" ] && . "$FIX/addresses.env"
[ -f "$FIX/keycard.env" ] && . "$FIX/keycard.env"
gifter_authkey(){ case "$1" in
  relay2) printf '%s' "${KEY_MIX2:-}";;
  relay3) printf '%s' "${KEY_MIX3:-}";;
  dest)   printf '%s' "${KEY_RECEIVER:-}";;
  sender) printf '%s' "${KEY_SENDER:-}";;
  *) printf '';; esac; }
# The gifter's allowlist = the 4 client addresses (JSON array for rlnGifterServe).
GIFTER_ALLOWLIST="${ADDR_MIX2:-},${ADDR_MIX3:-},${ADDR_RECEIVER:-},${ADDR_SENDER:-}"
# A key deliberately NOT on the allowlist, for the NEG=2 refusal test.
NEG2_KEY="${KEY_RECEIVER2:-}"
# Keycard auth is mounted for every run except KEYCARD=0 and NEG=3 (NEG=3's
# whole point is a valid attestation hitting a gifter WITHOUT keycard auth).
kc_mount=0; [ "$KEYCARD" != "0" ] && [ "$NEG" != "3" ] && kc_mount=1
# With keycard mounted, dest onboards via attestation: DROP its address from
# the allowlist to prove the card alone suffices (3 eth clients remain).
[ "$kc_mount" = "1" ] && GIFTER_ALLOWLIST="${ADDR_MIX2:-},${ADDR_MIX3:-},${ADDR_SENDER:-}"
# Synthetic attestation minter (sibling checkout, see bootstrap.sh) + the
# real-card capture/verify tools from the rln-zone experiment (KEYCARD=real).
MINT_TOOL="${MINT_TOOL:-$HERE/../../../../logos-rln-gifter/tools/mint_attest.py}"
KC_CAPTURE="${KC_CAPTURE:-$HERE/../../../../rln-zone/logos-rln-stealth/keycard/capture/kc-capture}"
KEYCARD_RLN="${KEYCARD_RLN:-$HERE/../../../../rln-zone/logos-rln-stealth/target/debug/keycard-rln}"
# Status production IdentApplet CA — the trust anchor for genuine retail cards.
STATUS_CA=029ab99ee1e7a71bdf45b3f9c58c99866ff1294d2c1e304e228a86e10c3343501c

sv(){ eval "_${1}_${2}=\"\$3\""; }
gv(){ eval "printf '%s' \"\${_${1}_${2}:-}\""; }
dexec(){ local svc="$1"; shift; $DC exec -T "$svc" "$@" 2>&1; }
jcall(){ local svc="$1" mod="$2" meth="$3" json="$4"
  printf '%s' "$json" | $DC exec -T "$svc" sh -c 'cat > /tmp/arg.json'
  dexec "$svc" "$LOGOSCORE" --json call "$mod" "$meth" @/tmp/arg.json
}
call(){ local svc="$1" mod="$2" meth="$3"; shift 3; dexec "$svc" "$LOGOSCORE" --json call "$mod" "$meth" "$@"; }
lc(){ local svc="$1"; shift; dexec "$svc" "$LOGOSCORE" "$@"; }
jval(){ python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); r=d.get("result"); print(r.get("value") if isinstance(r,dict) else r)
except Exception: print("ERR")'; }
parse_leaf_idc(){ python3 -c 'import json,sys
try:
  v=json.load(sys.stdin)["result"]["value"]; print("lopt=%s; idc=%s"%(v["leaf_index"],v["id_commitment"]))
except Exception: print("lopt=ERR; idc=")'; }
# Derive the RLN identity commitment a given seed will produce — the SAME
# deterministic derivation rlnGifterRequest runs internally, so an attestation
# minted/captured against this commitment binds to the later request. The hex
# is opaque little-endian field bytes: pass it through VERBATIM, never re-encode.
gen_idc(){ call "$1" "$RLN_MOD" generate_identity "$2" | python3 -c 'import json,sys
try:
  r=json.load(sys.stdin)["result"]
  if isinstance(r,str): r=json.loads(r)
  print(r.get("id_commitment",""))
except Exception: print("")'; }
# rlnGifterRequest args for the keycard path (attestation instead of authKey).
kc_req_json(){ printf '{"gifterPeerId":"%s","gifterMultiaddr":"%s","config":"%s","seed":"%s","attestation":"%s","rate":%s}' \
  "$(gv PEERID "$GIFTER")" "$(gv MADDR "$GIFTER")" "$CONFIG_ACCT" "$1" "$2" "$3"; }
mint_tlv(){ python3 "$MINT_TOOL" mint "$1" "$2" "$3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tlv"])'; }
# Auth-refusal probe: the gifter must reject with the expected error substring.
# Refusals reserve-then-release the nullifier and never touch the prober's
# adopted identity or the gifter wallet, so probes are free and safe anywhere.
KC_FAIL=0
kc_probe(){ local r; r=$(jcall dest libp2p_module rlnGifterRequest "$(kc_req_json "$2" "$3" "$RATE")")
  if echo "$r" | grep -q "$4"; then echo "  probe $1: OK (refused: $4)"
  else echo "  probe $1: FAIL — want '$4', got: $r"; KC_FAIL=$((KC_FAIL+1)); fi; }
svc_ip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$($DC ps -q "$1")"; }
chain_head(){ curl -s -m 15 -X POST "$RPC_URL" -H 'content-type: application/json' --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"])'; }
sync_wallet(){ local svc="$1" head cur n
  head=$(chain_head); cur=$(call "$svc" "$WALLET_MOD" get_last_synced_block | jval)
  while [ "$cur" != "$head" ] 2>/dev/null; do
    local tgt=$((cur+SYNC_STEP)); [ $tgt -gt $head ] && tgt=$head
    call "$svc" "$WALLET_MOD" sync_to_block $tgt >/dev/null 2>&1
    n=$(call "$svc" "$WALLET_MOD" get_last_synced_block | jval); [ "$n" = "$cur" ] && break; cur=$n
  done
  echo "$cur"
}
# Poll until $2 holds at least $3 RLNTOK on $1 (credit lands async). Prints the
# last seen balance; fails after ~150s.
wait_balance(){ local svc="$1" acct="$2" want="$3" bal=0 w
  for w in $(seq 1 30); do
    bal=$(call "$svc" "$RLN_MOD" get_token_balance "$acct" | python3 -c 'import json,sys
try:
  r=json.loads(json.load(sys.stdin)["result"]); print(r.get("balance","0"))
except Exception: print(0)')
    [ "${bal:-0}" -ge "$want" ] 2>/dev/null && { echo "$bal"; return 0; }
    sleep 5
  done
  echo "${bal:-0}"; return 1
}

# Diagnose a failed/again-unconfirmed registration by scanning the node's logs
# for the rln program's assert strings, then print the exact remediation. Set
# LEZ_RLN_DIR to your logos-lez-rln clone so the printed commands show real paths.
LEZ_RLN_DIR="${LEZ_RLN_DIR:-<your logos-lez-rln clone>}"
diagnose_reg(){ local svc="$1"; local logs
  logs=$($DC logs --since 900s "$svc" 2>&1)
  echo "  !! RLN registration for '$svc' did not confirm on-chain." >&2
  if echo "$logs" | grep -qiE "Insufficient balance|may be out of funds|range end index 49"; then
    cat >&2 <<EOF
  CAUSE: the run's payment account ran out of RLNTOK mid-run (each register
         costs price_per_unit*rate = 1M at rate=$RATE). The account is funded
         fresh per run with MINT_AMOUNT=$MINT_AMOUNT, so this normally means
         the budget knob is too low for a modified run shape (more nodes /
         higher rate), or a registration was double-paid after retries.
  FIX: re-run with a bigger budget — the sim mints what it needs, nothing to
       re-provision or rebuild:
    MINT_AMOUNT=$((MINT_AMOUNT * 2)) bash orchestrate.sh
EOF
  elif echo "$logs" | grep -qiE "Would exceed max total rate limit|max_total_rate_limit"; then
    cat >&2 <<EOF
  CAUSE: the RLN rate-limit pool is exhausted (the tree is effectively full).
  FIX: provision a fresh deployment on a new tree (tree_id is the single knob),
       then rebuild the image against it:
    1. (cd "\$LEZ_RLN_DIR/lez-rln" && PYO3_PYTHON=\$(command -v python3) \\
          cargo build --release --bin run_setup --bin derive_accounts)
    2. LEZ_RLN_DIR="\$LEZ_RLN_DIR" bash ../provision.sh --name <new-name>
    3. docker build -f docker/Dockerfile.testnet-e2e \\
          --build-arg DEPLOYMENT=<new-name> -t lp2p-mix-e2e .
  To reuse the same accounts across sims, add --adopt-wallet <storage.json> in (2).
  See docker/testnet/deployments/README.md for the full flow.
EOF
  else
    cat >&2 <<EOF
  CAUSE: unknown. Inspect the node log:
    docker compose -f docker-compose.yml logs $svc | grep -iE 'register|balance|rate limit|payment|tree'
  Most common is out-of-funds -> re-run run_setup (docker/testnet/deployments/README.md).
EOF
  fi
}

# On-chain confirmation barrier + readiness gate for a membership (used by BOTH
# the gifter's self-allocation and each gifted client). Waits until the rln
# module reports registered:true for our idCommitment on the CANONICAL tree
# BEFORE the caller proceeds, so the next membership lands on a DISTINCT leaf
# (rlnIsReady alone was unreliable: get_merkle_proofs returns a proof for the
# optimistic leaf before the tree advances, so leaves collided). Reads the ACTUAL
# leaf and flags any mismatch with the optimistic one. Args: svc idc lopt pid.
confirm_and_ready(){ local s="$1" idc="$2" lopt="$3" pid="$4" res lact="" conf=false rdy=False flag=""
  for w in $(seq 1 80); do
    res=$(call "$s" "$RLN_MOD" is_member_registered "$CONFIG_ACCT" "$idc")
    eval "$(echo "$res" | python3 -c 'import json,sys
try:
  r=json.loads(json.load(sys.stdin)["result"]); print("conf=%s; lact=%s"%(str(r.get("registered",False)).lower(), r.get("leaf_index","")))
except Exception: print("conf=false; lact=")')"
    [ "$conf" = "true" ] && break
    sleep 10
  done
  if [ "$conf" != "true" ]; then diagnose_reg "$s"; exit 1; fi
  for w in $(seq 1 40); do rdy=$(call "$s" libp2p_module rlnIsReady | jval); [ "$rdy" = "True" ] && break; sleep 10; sync_wallet "$s" >/dev/null 2>&1; done
  [ "$lopt" != "$lact" ] && flag=" !! LEAF MISMATCH (proof for $lopt, actual $lact)"
  echo "  $s peerId=${pid:-EMPTY} leaf_opt=$lopt leaf_actual=$lact confirmed=$conf rlnIsReady=$rdy$flag"
}

# NOTE: there is deliberately no root-convergence barrier between registration
# and the exchange. A verifier whose valid-roots window lags the newest root
# (later registrations advance the Merkle tree) recovers IN-LINE: the plugin's
# verifyProof requests an on-demand valid-roots refresh from the module on a
# root-window miss and re-checks before rejecting ("Root miss - requesting
# on-demand valid-roots refresh" / "On-demand root refresh recovered proof
# root" in the node logs — counted in the observe step below).

# Keycard preflight (host side, before anything starts): fixtures, the minter
# and a keycard-aware .lgx must all be present. An OLD .lgx would silently
# DROP the request's attestation field and die 4 retries deep into the run
# with a misleading out-of-funds diagnosis — abort loudly up front instead.
if [ "$kc_mount" = "1" ] || [ "$NEG" = "3" ]; then
  [ -f "$MINT_TOOL" ] || { echo "!! mint tool not found: $MINT_TOOL (clone logos-rln-gifter feat/keycard next to this repo — see bootstrap.sh)" >&2; exit 1; }
  [ -n "${KC_CA_PRIV:-}" ] && [ -n "${KC_CARD_PRIV:-}" ] || { echo "!! fixtures/gifter_auth/keycard.env missing or incomplete" >&2; exit 1; }
  # grep -c (not -q): -q's early exit SIGPIPEs gzip, which pipefail then
  # reports as failure even on a match. -c drains the stream.
  [ "$(gzip -dc "$HERE/../../lp2p-out/libp2p_module.lgx" 2>/dev/null | grep -ac keycard-attestation)" -gt 0 ] \
    || { echo "!! libp2p_module.lgx predates keycard auth — rebuild: bash docker/build_lgx_linux.sh" >&2; exit 1; }
  KC_CA_PUB=$(python3 "$MINT_TOOL" pub "$KC_CA_PRIV")
  tca="[\"$KC_CA_PUB\"]"
  if [ "$KEYCARD" = "real" ] && [ "$kc_mount" = "1" ]; then
    tca="[\"$STATUS_CA\"]"
    [ -x "$KC_CAPTURE" ] || [ -e /dev/tty ] || { echo "!! KEYCARD=real needs the kc-capture binary ($KC_CAPTURE) or an interactive tty to paste the TLV" >&2; exit 1; }
  fi
fi

echo "=== up: 5 daemons (force-recreate for FRESH daemons) ==="
# Force-recreate so each run starts from clean daemons. Module state (e.g. the
# RLN SpamProtection factory registered by rlnEnable) is a process-global that
# lives as long as the daemon process; reusing a daemon would leak stale RLN
# state into the next run.
$DC down --remove-orphans >/dev/null 2>&1
$DC up -d --force-recreate
for s in $ALL; do
  for i in $(seq 1 90); do lc "$s" load-module libp2p_module >/dev/null 2>&1 && break; sleep 1; done
done

# Config account + funding mode come from the baked deployment profile
# (/testnet, staged at image build). The funder is NOT baked anymore: relay1
# creates a fresh payment account and puts this run's budget into it during
# its setup (see the gifter branch). Pre-policy images have no funding.txt ==
# the legacy wallet-key model.
CONFIG_ACCT=$(dexec sender sh -c 'tr -d "\n\r" < /testnet/config_account.txt')
FUNDING=$(dexec sender sh -c 'cat /testnet/funding.txt 2>/dev/null' | tr -d '\n\r')
FUNDING="${FUNDING:-wallet-key}"
HOLDING_ACCT=""
echo "  config=$CONFIG_ACCT funding=$FUNDING holding(funder)=<funded per-run by relay1>"

echo "=== per-node setup (load chain -> wallet+rln -> start -> mixSetNodeInfo -> peerInfo -> register) ==="
for s in $ALL; do
  lc "$s" load-module "$WALLET_MOD" >/dev/null 2>&1
  lc "$s" load-module "$RLN_MOD" >/dev/null 2>&1
  lc "$s" load-module libp2p_module >/dev/null 2>&1
  priv=$(python3 -c 'import os;print(os.urandom(32).hex())'); sv MIXPRIV "$s" "$priv"
  sv MIXPUB "$s" "$($KEYS mixpub "$priv")"
  ip=$(svc_ip "$s"); sv MADDR "$s" "/ip4/$ip/tcp/9000"

  dexec "$s" sh -c '[ -f /testnet/storage.json ] || cp /testnet/storage.json.seed /testnet/storage.json'
  call "$s" "$WALLET_MOD" open /testnet/wallet_config.json /testnet/storage.json >/dev/null 2>&1
  synced=$(sync_wallet "$s"); echo "  $s wallet synced to $synced"
  jcall "$s" libp2p_module rlnEnable "{\"useOnchainLEZ\":true,\"configAccount\":\"$CONFIG_ACCT\",\"userMessageLimit\":$RATE,\"epochDurationSeconds\":10.0}" >/dev/null 2>&1

  call "$s" libp2p_module start >/dev/null 2>&1
  jcall "$s" libp2p_module mixSetNodeInfo "{\"multiaddr\":\"$(gv MADDR "$s")\",\"mixPrivKeyHex\":\"$priv\"}" >/dev/null 2>&1
  pid=$(call "$s" libp2p_module peerInfo | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["value"]["peerId"])
except Exception: print("")')
  sv PEERID "$s" "$pid"
  sv LPPUB "$s" "$($KEYS peerpub "$pid" 2>/dev/null || echo DECODE_FAIL)"

  if [ "$s" = "$GIFTER" ]; then
    # Fund this run: create a FRESH payment account in relay1's (container-
    # local) wallet and put the run budget into it, per the deployment's
    # funding mode. Both paths need only the RLN config account — the token
    # program id + definition (authority) account are recorded in its on-chain
    # state — and both credit the uninitialized fresh account directly
    # (Claim::Authorized, co-signed by it):
    #  - faucet: claim_tokens mints from the program's own payment PDA,
    #    PDA-authorized — no signing key involved beyond the destination.
    #    Per-call cap on-chain => the budget is claimed in CLAIM_CHUNK slices.
    #  - wallet-key: mint_tokens signs with the definition key in the opened
    #    deployment wallet.
    #
    # create_account_public derives accounts DETERMINISTICALLY from the shared
    # wallet's key chain, so early derivations collide with accounts other
    # provisioning runs already created on-chain (e.g. another tree's supply
    # holding) — walk the chain until an account with no on-chain data. Each
    # completed run leaves its account on-chain, so the next run derives one
    # step further: genuinely fresh per run.
    echo "  funding: fresh per-run payment account ($FUNDING, $MINT_AMOUNT RLNTOK)"
    HOLDING_ACCT=""
    for d in $(seq 1 30); do
      cand=$(call "$s" "$WALLET_MOD" create_account_public | jval)
      case "$cand" in ""|ERR|None) continue;; esac
      if call "$s" "$RLN_MOD" get_token_balance "$cand" | grep -q '\\"exists\\":false'; then
        HOLDING_ACCT="$cand"; echo "  fresh account after $d derivation(s): $HOLDING_ACCT"; break
      fi
    done
    if [ -z "$HOLDING_ACCT" ]; then
      echo "  !! no unused wallet account in 30 derivations — inspect the key chain" >&2; exit 1
    fi
    # The CLI double-encodes the module's JSON result, so match the bare word
    # (the quotes around "pending" arrive backslash-escaped).
    if [ "$FUNDING" = faucet ]; then
      claimed=0
      while [ "$claimed" -lt "$MINT_AMOUNT" ]; do
        step=$((MINT_AMOUNT - claimed)); [ "$step" -gt "$CLAIM_CHUNK" ] && step=$CLAIM_CHUNK
        tx=$(call "$s" "$RLN_MOD" claim_tokens "$CONFIG_ACCT" "$HOLDING_ACCT" "$step")
        if ! echo "$tx" | grep -q 'pending'; then
          echo "  !! claim_tokens failed: $tx" >&2
          echo "  (claims mint from the program's payment PDA — check testnet reachability" >&2
          echo "   and that CLAIM_CHUNK=$CLAIM_CHUNK <= this deployment's faucet_claim_cap)" >&2
          exit 1
        fi
        claimed=$((claimed + step))
        if ! bal=$(wait_balance "$s" "$HOLDING_ACCT" "$claimed"); then
          echo "  !! claim not credited in time (balance=$bal want=$claimed) — check the fund step output + testnet" >&2
          exit 1
        fi
      done
    else
      mint=$(call "$s" "$RLN_MOD" mint_tokens "$CONFIG_ACCT" "$HOLDING_ACCT" "$MINT_AMOUNT")
      if ! echo "$mint" | grep -q 'pending'; then
        echo "  !! mint_tokens failed: $mint" >&2
        echo "  (mint submits via the wallet's generic tx — check testnet reachability" >&2
        echo "   and that the deployment wallet holds the payment-token definition key)" >&2
        exit 1
      fi
      if ! bal=$(wait_balance "$s" "$HOLDING_ACCT" "$MINT_AMOUNT"); then
        echo "  !! mint not credited in time (balance=$bal) — check the fund step output + testnet" >&2
        exit 1
      fi
    fi
    echo "  funded: payment=$HOLDING_ACCT balance=$bal"

    # relay1 = the membership provider (gifter). It holds the freshly funded
    # payment account, so it self-allocates its OWN membership (register_member
    # funded/signed by its wallet), confirms on-chain, then mounts the gifter
    # service the other nodes authenticate to. Retry transient sequencer
    # failures; register_member is idempotent on the same seed. A persistent
    # failure is diagnosed.
    seed=$(python3 -c 'import os;print(os.urandom(32).hex())')
    idc=""; lopt=""; reg=""
    for attempt in 1 2 3 4; do
      reg=$(jcall "$s" libp2p_module rlnRegister "{\"config\":\"$CONFIG_ACCT\",\"wallet\":\"$HOLDING_ACCT\",\"seed\":\"$seed\",\"rate\":$RATE}")
      eval "$(echo "$reg" | parse_leaf_idc)"
      [ -n "$idc" ] && break
      echo "  $s rlnRegister attempt $attempt failed ($reg) — re-sync + retry in ${REG_RETRY_SLEEP}s" >&2
      sync_wallet "$s" >/dev/null 2>&1; sleep "$REG_RETRY_SLEEP"
    done
    if [ -z "$idc" ]; then echo "  rlnRegister response: $reg" >&2; diagnose_reg "$s"; exit 1; fi
    confirm_and_ready "$s" "$idc" "$lopt" "$pid"
    # Mount the gifter service. Clients dial this codec directly (by
    # peerId+multiaddr, pre-mesh) to obtain a gifted membership. With keycard
    # enabled the mount carries BOTH auths — the (3-address) eth allowlist and
    # the trusted attestation CA — plus an append-only consumed-nullifier file
    # so a card's one-shot grant survives a gifter restart (KEYCARD_PERSIST).
    al=$(python3 -c 'import json,sys; print(json.dumps([a for a in sys.argv[1].split(",") if a]))' "$GIFTER_ALLOWLIST")
    if [ "$kc_mount" = "1" ]; then
      jcall "$s" libp2p_module rlnGifterServe "{\"config\":\"$CONFIG_ACCT\",\"wallet\":\"$HOLDING_ACCT\",\"allowlist\":$al,\"trustedCAs\":$tca,\"consumedNullifiersPath\":\"/testnet/consumed_nullifiers.txt\"}" >/dev/null 2>&1
      echo "  $s gifter service mounted ($GIFTER_CODEC, allowlist=3 clients + keycard CA)"
    else
      jcall "$s" libp2p_module rlnGifterServe "{\"config\":\"$CONFIG_ACCT\",\"wallet\":\"$HOLDING_ACCT\",\"allowlist\":$al}" >/dev/null 2>&1
      echo "  $s gifter service mounted ($GIFTER_CODEC, allowlist=4 clients)"
    fi
  elif [ "$NEG" = "1" ] && [ "$s" = "sender" ]; then
    # NEG=1: leave the sender UNREGISTERED (never asks the gifter). rlnEnable +
    # mix are set up above; we just skip the allocation request.
    echo "  $s peerId=${pid:-EMPTY} UNREGISTERED (negative) rlnIsReady=$(call "$s" libp2p_module rlnIsReady | jval)"
  elif [ "$NEG" = "2" ] && [ "$s" = "sender" ]; then
    # NEG=2: sender asks the gifter with a NON-allowlisted key -> auth refused ->
    # no membership. Exercises the allocation authentication gate specifically.
    seed=$(python3 -c 'import os;print(os.urandom(32).hex())')
    req=$(jcall "$s" libp2p_module rlnGifterRequest "{\"gifterPeerId\":\"$(gv PEERID "$GIFTER")\",\"gifterMultiaddr\":\"$(gv MADDR "$GIFTER")\",\"config\":\"$CONFIG_ACCT\",\"seed\":\"$seed\",\"authKey\":\"$NEG2_KEY\",\"rate\":$RATE}")
    echo "  $s peerId=${pid:-EMPTY} REFUSED (negative, non-allowlisted key) rlnIsReady=$(call "$s" libp2p_module rlnIsReady | jval)"
  elif [ "$NEG" = "3" ] && [ "$s" = "sender" ]; then
    # NEG=3: keycard auth NOT mounted (legacy allowlist-only serve above), but
    # the sender presents a VALID synthetic attestation -> the gifter must
    # refuse with 'unsupported authentication_type' -> sender stays
    # unregistered. Assert the EXACT error string so a stale (pre-keycard)
    # artifact, which drops the attestation field, cannot false-pass.
    seed=$(python3 -c 'import os;print(os.urandom(32).hex())')
    idc3=$(gen_idc "$s" "$seed")
    tlv3=$(mint_tlv "$KC_CA_PRIV" "$KC_CARD_PRIV" "$idc3")
    req=$(jcall "$s" libp2p_module rlnGifterRequest "$(kc_req_json "$seed" "$tlv3" "$RATE")")
    NEG3_OK=0; echo "$req" | grep -q "unsupported authentication_type: 'keycard-attestation'" && NEG3_OK=1
    echo "  $s peerId=${pid:-EMPTY} REFUSED (negative, keycard not mounted, exact_err=$NEG3_OK) rlnIsReady=$(call "$s" libp2p_module rlnIsReady | jval)"
  else
    # Gifter client: request an allocation from relay1. We derive our identity
    # locally — only the idCommitment is sent; the RLN secret never leaves this
    # node. The gifter funds + signs the tx and returns the leaf; then we run
    # the same on-chain confirmation barrier. Re-sync the GIFTER's wallet first
    # so its next tx uses the freshest nonce (the previous client's
    # registration is already sealed).
    #
    # Auth: EIP-191 over the idCommitment (authKey) — EXCEPT dest with keycard
    # enabled, which presents an IDENTIFY_CARD attestation TLV instead. The
    # attestation is bound to the commitment (challenge =
    # SHA256("logos/rln/keycard-attest/1" || idc)); generate_identity(seed) is
    # deterministic, so we derive the commitment FIRST, mint/capture against
    # it, and the request then re-derives the same identity from the same
    # seed. Mint/capture stays OUTSIDE the retry loop: the same seed+TLV pair
    # re-verifies on retry (the nullifier is only consumed on success).
    sync_wallet "$GIFTER" >/dev/null 2>&1
    seed=$(python3 -c 'import os;print(os.urandom(32).hex())')
    if [ "$s" = "dest" ] && [ "$kc_mount" = "1" ]; then
      idc0=$(gen_idc "$s" "$seed")
      [ -n "$idc0" ] || { echo "  !! generate_identity failed on $s" >&2; exit 1; }
      KC_DEST_NULLIFIER=""
      if [ "$KEYCARD" = "real" ]; then
        ch=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(b"logos/rln/keycard-attest/1"+bytes.fromhex(sys.argv[1])).hexdigest())' "$idc0")
        # IDENTIFY_CARD is a PUBLIC applet command: no pairing, PIN or secret
        # is involved — the card signs any challenge for anyone holding it.
        if [ -x "$KC_CAPTURE" ]; then
          echo "  REAL CARD: IDENTIFY_CARD over PC/SC (challenge $ch)"
          tlv=$("$KC_CAPTURE" "$ch" | awk '/^response/{print $2}')
        else
          echo "  REAL CARD: run   kc-capture $ch"
          printf '  paste the response TLV hex: '
          read -r tlv < /dev/tty
        fi
        [ -n "$tlv" ] || { echo "  !! no attestation TLV captured" >&2; exit 1; }
        # Offline pre-verify against the pinned production CA when the
        # rln-zone verifier is built: catches a wrong card/pairing before the
        # gifter round-trip, and yields the nullifier for the observe assert.
        if [ -x "$KEYCARD_RLN" ]; then
          v=$("$KEYCARD_RLN" attest "$tlv" "$idc0")
          echo "$v" | grep -q '"verified": *true' || { echo "  !! offline attestation verify failed: $v" >&2; exit 1; }
          KC_DEST_NULLIFIER=$(echo "$v" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("nullifier",""))')
        fi
      else
        mj=$(python3 "$MINT_TOOL" mint "$KC_CA_PRIV" "$KC_CARD_PRIV" "$idc0")
        tlv=$(echo "$mj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tlv"])')
        KC_DEST_NULLIFIER=$(echo "$mj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["nullifier"])')
      fi
      auth_field="\"attestation\":\"$tlv\""
      KC_DEST_SEED="$seed"; KC_DEST_TLV="$tlv"
      echo "  $s onboarding via keycard attestation (KEYCARD=$KEYCARD)"
    else
      auth_field="\"authKey\":\"$(gifter_authkey "$s")\""
    fi
    idc=""; lopt=""; req=""
    for attempt in 1 2 3 4; do
      req=$(jcall "$s" libp2p_module rlnGifterRequest "{\"gifterPeerId\":\"$(gv PEERID "$GIFTER")\",\"gifterMultiaddr\":\"$(gv MADDR "$GIFTER")\",\"config\":\"$CONFIG_ACCT\",\"seed\":\"$seed\",$auth_field,\"rate\":$RATE}")
      eval "$(echo "$req" | parse_leaf_idc)"
      [ -n "$idc" ] && break
      echo "  $s rlnGifterRequest attempt $attempt failed ($req) — re-sync gifter + retry in ${REG_RETRY_SLEEP}s" >&2
      sync_wallet "$GIFTER" >/dev/null 2>&1; sleep "$REG_RETRY_SLEEP"
    done
    if [ -z "$idc" ]; then echo "  rlnGifterRequest response: $req" >&2; diagnose_reg "$GIFTER"; exit 1; fi
    confirm_and_ready "$s" "$idc" "$lopt" "$pid"
  fi
done

# Keycard auth-layer negatives, probed inline: each is a request-level refusal
# (distinct server error string), so nothing registers, no budget is spent and
# the prober's adopted membership is untouched. One probe seed serves all four.
if [ "$kc_mount" = "1" ] && [ "$NEG" = "0" ]; then
  echo "=== keycard negative probes (auth refusals — nothing registered, no budget spent) ==="
  pseed=$(python3 -c 'import os;print(os.urandom(32).hex())')
  pidc=$(gen_idc dest "$pseed")
  fake_idc=$(python3 -c 'import os;print(os.urandom(32).hex())')
  if [ "$KEYCARD" = "real" ]; then
    # Real card: replaying dest's own grant exercises reuse (same binding) and
    # wrong-binding (fresh seed) without another card tap.
    kc_probe "card-reuse   " "$KC_DEST_SEED" "$KC_DEST_TLV" "card already used"
    kc_probe "wrong-binding" "$pseed" "$KC_DEST_TLV" "challenge signature does not verify"
  else
    kc_probe "card-reuse   " "$pseed" "$(mint_tlv "$KC_CA_PRIV" "$KC_CARD_PRIV" "$pidc")" "card already used"
    kc_probe "wrong-binding" "$pseed" "$(mint_tlv "$KC_CA_PRIV" "$KC_CARD2_PRIV" "$fake_idc")" "challenge signature does not verify"
  fi
  kc_probe "untrusted-CA " "$pseed" "$(mint_tlv "$KC_UNTRUSTED_CA_PRIV" "$KC_CARD2_PRIV" "$pidc")" "attestation CA is not trusted"
  kc_probe "garbage-TLV  " "$pseed" "deadbeef" "attestation parse failed"
fi

echo "=== mesh: every node adds the other 4 ==="
for a in $ALL; do for b in $ALL; do [ "$a" = "$b" ] && continue
  jcall "$a" libp2p_module mixNodepoolAdd \
    "{\"peerId\":\"$(gv PEERID "$b")\",\"multiaddr\":\"$(gv MADDR "$b")\",\"mixPubKey\":\"$(gv MIXPUB "$b")\",\"libp2pPubKey\":\"$(gv LPPUB "$b")\"}" >/dev/null 2>&1
done; done
echo "  meshed."

echo "=== rlnIsReady status (each node was confirmed ready before the next registered) ==="
line="  "; for s in $ALL; do line="$line $s=$(call "$s" libp2p_module rlnIsReady | jval)"; done; echo "$line"

echo "=== register dest-read-behavior on all nodes (the SURB exit is random) ==="
for s in $ALL; do
  jcall "$s" libp2p_module mixRegisterDestReadBehavior "{\"proto\":\"$PROTO\",\"behavior\":0,\"sizeParam\":$READ_SIZE}" >/dev/null 2>&1
done
echo "  registered ($PROTO, READ_EXACTLY, $READ_SIZE bytes)"

# One request/reply round-trip: dial-with-reply -> write request -> read the SURB
# reply -> close+release. Returns 0 iff a reply came back (read succeeded). N
# round-trips = N dials (the reply future is one-shot).
roundtrip(){ local from="$1" to="$2" idx="$3" dial sid payload rd
  dial=$(jcall "$from" libp2p_module mixDialWithReply \
    "{\"peerId\":\"$(gv PEERID "$to")\",\"multiaddr\":\"$(gv MADDR "$to")\",\"proto\":\"$PROTO\",\"expectReply\":1,\"numSurbs\":1}")
  sid=$(echo "$dial" | jval)
  case "$sid" in ""|ERR|None) return 1;; esac
  # ASCII payload exactly READ_SIZE bytes (ping echoes it back).
  payload=$(python3 -c "print(('m%d-%s'%(${idx},'$from'))[:${READ_SIZE}].ljust(${READ_SIZE},'.'))")
  call "$from" libp2p_module streamWrite "$sid" "$payload" >/dev/null 2>&1
  rd=$(call "$from" libp2p_module streamReadExactly "$sid" "$READ_SIZE")
  call "$from" libp2p_module streamClose "$sid" >/dev/null 2>&1
  call "$from" libp2p_module streamRelease "$sid" >/dev/null 2>&1
  echo "$rd" | grep -q '"success":true'
}

run_dir(){ local from="$1" to="$2" ok=0 i
  for i in $(seq 1 "$MSG_COUNT"); do
    roundtrip "$from" "$to" "$i" && ok=$((ok+1))
  done
  echo "  $from->$to: $ok/$MSG_COUNT replies received"
  LAST_OK=$ok
}

echo "=== exchange: $MSG_COUNT request/reply round-trip(s) per initiator ==="
run_dir sender dest; SD=$LAST_OK; DS=0
# In a negative run only the (rejected) sender->dest direction is the test.
if [ "$NEG" = "0" ]; then run_dir dest sender; DS=$LAST_OK; fi
sleep 4

echo "=== observe: RLN proofs (forward request + SURB reply legs) ==="
# root_misses/refresh_recovered are DIAGNOSTIC only (not asserted): whether a
# hop's window lags at exchange time is a race against the module's periodic
# proof push, so a lucky run can legitimately show 0/0. misses > recovered
# means a packet was dropped after an unrecovered miss.
vtot=0
for n in $ALL; do
  g=$($DC logs --since 240s "$n" 2>&1 | grep -c 'Generated RLN proof successfully')
  v=$($DC logs --since 240s "$n" 2>&1 | grep -c 'Proof verified successfully')
  rm=$($DC logs --since 240s "$n" 2>&1 | grep -c 'Root miss - requesting on-demand')
  rr=$($DC logs --since 240s "$n" 2>&1 | grep -c 'On-demand root refresh recovered')
  echo "  $n: generated=$g verified=$v root_misses=$rm refresh_recovered=$rr"; vtot=$((vtot+v))
done
sgen=$($DC logs --since 240s sender 2>&1 | grep -c 'Generated RLN proof successfully')
echo "  replies: sender->dest=$SD dest->sender=$DS ; total verifications=$vtot ; sender proofs=$sgen"
# Gifted allocations succeeded at the gifter (relay1): one log line per client.
greg=$($DC logs --since 1800s "$GIFTER" 2>&1 | grep -c 'RLN gifter registration succeeded')
echo "  gifter($GIFTER): 'RLN gifter registration succeeded' x$greg (expect 4 in the happy path)"
# Keycard observability: the mount must have enabled keycard auth, and dest's
# consumed nullifier must have been persisted (exact match when known — the
# synthetic mint and the offline verifier both report it).
if [ "$kc_mount" = "1" ]; then
  kce=$($DC logs --since 1800s "$GIFTER" 2>&1 | grep -c 'keycard attestation auth enabled')
  nul=$(dexec "$GIFTER" sh -c 'cat /testnet/consumed_nullifiers.txt 2>/dev/null')
  nulf=$(printf '%s' "$nul" | grep -c .)
  echo "  gifter($GIFTER): keycard auth mount log x$kce ; consumed_nullifiers lines=$nulf"
  [ "$kce" -ge 1 ] || { echo "  !! keycard auth mount log missing"; KC_FAIL=$((KC_FAIL+1)); }
  if [ -n "${KC_DEST_NULLIFIER:-}" ]; then
    printf '%s' "$nul" | grep -qi "$KC_DEST_NULLIFIER" \
      || { echo "  !! dest nullifier $KC_DEST_NULLIFIER not in consumed_nullifiers.txt"; KC_FAIL=$((KC_FAIL+1)); }
  else
    [ "$nulf" -ge 1 ] || { echo "  !! consumed_nullifiers.txt empty"; KC_FAIL=$((KC_FAIL+1)); }
  fi
fi

echo "=== VERDICT ==="
if [ "$NEG" != "0" ]; then
  # NEG=3 additionally requires the EXACT refusal string (recorded above) so a
  # stale artifact's generic failure can't masquerade as the keycard refusal.
  if [ "$SD" = "0" ] && [ "$sgen" = "0" ] && [ "${KC_FAIL:-0}" = "0" ] && { [ "$NEG" != "3" ] || [ "${NEG3_OK:-0}" = "1" ]; }; then
    echo "  PASS (negative): sender got 0 replies and generated 0 proofs -> rejected (NEG=$NEG)."
  else
    echo "  FAIL (negative): expected 0 replies / 0 sender proofs, got replies=$SD sgen=$sgen kc_fail=${KC_FAIL:-0} neg3_exact=${NEG3_OK:-n/a}"
    echo "DONE (NEG=$NEG)"; exit 1
  fi
else
  exp="sender->dest=$MSG_COUNT dest->sender=$MSG_COUNT"; ok=1
  [ "$SD" = "$MSG_COUNT" ] || ok=0
  [ "$DS" = "$MSG_COUNT" ] || ok=0
  [ "${KC_FAIL:-0}" = "0" ] || { ok=0; echo "  keycard probe/observe failures: $KC_FAIL"; }
  if [ "$ok" = "1" ]; then echo "  PASS: every round-trip got a reply ($exp)."
  else echo "  FAIL: expected $exp, got sender->dest=$SD dest->sender=$DS"; echo "DONE (NEG=$NEG)"; exit 1; fi
fi

# Post-verdict extras (opt-in). The rate-clamp probe SUCCEEDS at the gifter,
# and a successful rlnGifterRequest OVERWRITES the caller's adopted RLN
# identity — hence post-verdict, from the sender, whose exchange is done.
if [ "$KEYCARD_CLAMP" = "1" ]; then
  if [ "$KEYCARD" = "1" ] && [ "$NEG" = "0" ]; then
    echo "=== extra: keycard rate-clamp probe (KC_CARD2, rate 600 -> registered at 100) ==="
    cseed=$(python3 -c 'import os;print(os.urandom(32).hex())')
    cidc=$(gen_idc sender "$cseed")
    ctlv=$(mint_tlv "$KC_CA_PRIV" "$KC_CARD2_PRIV" "$cidc")
    sync_wallet "$GIFTER" >/dev/null 2>&1
    req=$(jcall sender libp2p_module rlnGifterRequest "$(kc_req_json "$cseed" "$ctlv" 600)")
    eval "$(echo "$req" | parse_leaf_idc)"
    [ -n "$idc" ] || { echo "  FAIL: clamp registration refused: $req"; exit 1; }
    mrate=""
    for w in $(seq 1 60); do
      mrate=$(call sender "$RLN_MOD" get_membership "$CONFIG_ACCT" "$cidc" | python3 -c 'import json,sys
try:
  r=json.loads(json.load(sys.stdin)["result"]); print(r.get("rate_limit","") if r.get("registered") else "")
except Exception: print("")')
      [ -n "$mrate" ] && break; sleep 10
    done
    cl=$($DC logs --since 1800s "$GIFTER" 2>&1 | grep -c 'clamping keycard grant rate limit')
    if [ "$mrate" = "100" ] && [ "$cl" -ge 1 ]; then echo "  PASS: on-chain rate_limit=100, clamp log x$cl"
    else echo "  FAIL: on-chain rate_limit='$mrate' clamp_log=$cl"; exit 1; fi
  else
    echo "=== extra: rate-clamp probe SKIPPED (needs KEYCARD=1 and NEG=0) ==="
  fi
fi
if [ "$KEYCARD_PERSIST" = "1" ]; then
  if [ "$kc_mount" = "1" ] && [ -n "${KC_DEST_TLV:-}" ]; then
    echo "=== extra: consumed-nullifier persistence across a gifter restart ==="
    # docker compose restart preserves the container fs (consumed_nullifiers
    # .txt, mutated storage.json) and its IP, but NOT the daemon: modules,
    # wallet and the libp2p identity (peerId!) reset. Remount just the gifter
    # — the direct-dial membership codec needs no rlnEnable/mix state.
    $DC restart "$GIFTER" >/dev/null 2>&1
    for i in $(seq 1 90); do lc "$GIFTER" load-module libp2p_module >/dev/null 2>&1 && break; sleep 1; done
    lc "$GIFTER" load-module "$WALLET_MOD" >/dev/null 2>&1
    lc "$GIFTER" load-module "$RLN_MOD" >/dev/null 2>&1
    call "$GIFTER" "$WALLET_MOD" open /testnet/wallet_config.json /testnet/storage.json >/dev/null 2>&1
    sync_wallet "$GIFTER" >/dev/null 2>&1
    call "$GIFTER" libp2p_module start >/dev/null 2>&1
    sv MADDR "$GIFTER" "/ip4/$(svc_ip "$GIFTER")/tcp/9000"
    sv PEERID "$GIFTER" "$(call "$GIFTER" libp2p_module peerInfo | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["value"]["peerId"])
except Exception: print("")')"
    jcall "$GIFTER" libp2p_module rlnGifterServe "{\"config\":\"$CONFIG_ACCT\",\"wallet\":\"$HOLDING_ACCT\",\"allowlist\":$al,\"trustedCAs\":$tca,\"consumedNullifiersPath\":\"/testnet/consumed_nullifiers.txt\"}" >/dev/null 2>&1
    req=$(jcall dest libp2p_module rlnGifterRequest "$(kc_req_json "$KC_DEST_SEED" "$KC_DEST_TLV" "$RATE")")
    if echo "$req" | grep -q "card already used"; then
      echo "  PASS: restarted gifter reloaded the consumed set from disk"
    else echo "  FAIL: expected 'card already used' after restart, got: $req"; exit 1; fi
  else
    echo "=== extra: persistence probe SKIPPED (needs keycard mounted + a dest grant) ==="
  fi
fi
echo "DONE (NEG=$NEG)"
