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
# The only knob is NEG (negative enforcement tests):
#   NEG=0 (default) : the full happy-path E2E.
#   NEG=1 : leave the SENDER UNREGISTERED (never asks the gifter). Its mixDial
#           must be rejected (no valid proof) and not reach the dest.
#   NEG=2 : the sender asks the gifter with a NON-allowlisted key -> auth refused
#           -> sender stays unregistered -> rejected. Exercises the allocation
#           authentication gate specifically.
# Both prove RLN gates delivery (vs the happy path where a member's msg lands).
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

# Fixed sim parameters (RATE must match the baked deployment's rate limit).
MSG_COUNT=3
PROTO="/ipfs/ping/1.0.0"
READ_SIZE=32
RATE=100
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

# Diagnose a failed/again-unconfirmed registration by scanning the node's logs
# for the rln program's assert strings, then print the exact remediation. Set
# LEZ_RLN_DIR to your logos-lez-rln clone so the printed commands show real paths.
LEZ_RLN_DIR="${LEZ_RLN_DIR:-<your logos-lez-rln clone>}"
diagnose_reg(){ local svc="$1"; local logs
  logs=$($DC logs --since 900s "$svc" 2>&1)
  echo "  !! RLN registration for '$svc' did not confirm on-chain." >&2
  if echo "$logs" | grep -qiE "Insufficient balance|may be out of funds|range end index 49"; then
    cat >&2 <<EOF
  CAUSE: the deployment's payment account is OUT OF RLNTOK (each register costs
         price_per_unit*rate; the funded account holds a finite amount).
  FIX: provision a fresh funded payment account on the SAME tree (re-uses the
       wallet, so run_setup mints a new funded holder), then rebuild the image
       against the new deployment (the gifter signs with the baked wallet, so a
       new payment account must be baked in):
    D=docker/testnet/deployments/shared-5ade
    (cd "\$LEZ_RLN_DIR/lez-rln" && PYO3_PYTHON=\$(command -v python3) \\
        cargo build --release --bin run_setup --bin derive_accounts)
    LEZ_RLN_DIR="\$LEZ_RLN_DIR" bash ../provision.sh --name shared-refunded \\
        --tree \$(jq -r .tree_id "\$D/deployment.json") --adopt-wallet "\$D/storage.json"
    docker build -f docker/Dockerfile.testnet-e2e \\
        --build-arg DEPLOYMENT=shared-refunded -t lp2p-mix-e2e .
  If you instead saw "supply holding may be out of funds", the master supply is
  exhausted -> provision a brand-new tree (see "tree full" below).
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

# Root-convergence barrier: run AFTER all registrations, BEFORE the exchange.
# confirm_and_ready makes each node ready at the tree state of ITS OWN
# registration, but every later registration advances the Merkle tree to a new
# root. An earlier node's verification-side valid-roots window (the group
# manager's rootTracker, refreshed on the module's ~epoch proof-refresh timer)
# then lags the newest root — so as a mix hop it rejects a proof built with that
# root ("invalid Merkle root") and silently drops the message (seen as a missing
# reply). Re-sync every wallet to head, wait until all nodes read the SAME
# on-chain valid-roots set, then give the proof-refresh timers one epoch to
# propagate that set into every verifier's window.
roots_sig(){ call "$1" "$RLN_MOD" get_valid_roots "$CONFIG_ACCT" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); r=d.get("result"); a=json.loads(r) if isinstance(r,str) else r
  print(",".join(sorted(x.lower() for x in a)) if a else "EMPTY")
except Exception: print("ERR")'; }
converge_roots(){ local s sig first ok
  for s in $ALL; do sync_wallet "$s" >/dev/null 2>&1; done
  for w in $(seq 1 24); do
    first=""; ok=1
    for s in $ALL; do
      sig=$(roots_sig "$s")
      case "$sig" in ""|ERR|EMPTY) ok=0;; esac
      if [ -z "$first" ]; then first="$sig"; elif [ "$sig" != "$first" ]; then ok=0; fi
    done
    [ "$ok" = "1" ] && break
    sleep 5
  done
  if [ "$ok" = "1" ]; then echo "  valid-roots converged across all 5 nodes; settling one epoch for verifier windows"
  else echo "  !! valid-roots did not fully converge in time — proceeding (a first-hop proof reject may drop one round-trip)" >&2; fi
  sleep 12
}

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

# Config + funder accounts come from the baked deployment profile (/testnet).
CONFIG_ACCT=$(dexec sender sh -c 'tr -d "\n\r" < /testnet/config_account.txt')
HOLDING_ACCT=$(dexec sender sh -c 'tr -d "\n\r" < /testnet/payment_account.txt')
echo "  config=$CONFIG_ACCT holding(funder)=$HOLDING_ACCT"

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
    # relay1 = the membership provider (gifter). It holds the funded wallet, so
    # it self-allocates its OWN membership (register_member funded/signed by its
    # wallet), confirms on-chain, then mounts the gifter service the other nodes
    # authenticate to. Retry transient sequencer failures; register_member is
    # idempotent on the same seed. A persistent failure is diagnosed.
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
    # Mount the gifter service (allowlist auth). Clients dial this codec directly
    # (by peerId+multiaddr, pre-mesh) to obtain a gifted membership.
    al=$(python3 -c 'import json,sys; print(json.dumps([a for a in sys.argv[1].split(",") if a]))' "$GIFTER_ALLOWLIST")
    jcall "$s" libp2p_module rlnGifterServe "{\"config\":\"$CONFIG_ACCT\",\"wallet\":\"$HOLDING_ACCT\",\"allowlist\":$al}" >/dev/null 2>&1
    echo "  $s gifter service mounted ($GIFTER_CODEC, allowlist=4 clients)"
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
  else
    # Gifter client: authenticate (EIP-191 over our idCommitment) and request an
    # allocation from relay1. We derive our identity locally — only the
    # idCommitment is sent; the RLN secret never leaves this node. The gifter
    # funds + signs the tx and returns the leaf; then we run the same on-chain
    # confirmation barrier. Re-sync the GIFTER's wallet first so its next tx uses
    # the freshest nonce (the previous client's registration is already sealed).
    sync_wallet "$GIFTER" >/dev/null 2>&1
    ak=$(gifter_authkey "$s")
    seed=$(python3 -c 'import os;print(os.urandom(32).hex())')
    idc=""; lopt=""; req=""
    for attempt in 1 2 3 4; do
      req=$(jcall "$s" libp2p_module rlnGifterRequest "{\"gifterPeerId\":\"$(gv PEERID "$GIFTER")\",\"gifterMultiaddr\":\"$(gv MADDR "$GIFTER")\",\"config\":\"$CONFIG_ACCT\",\"seed\":\"$seed\",\"authKey\":\"$ak\",\"rate\":$RATE}")
      eval "$(echo "$req" | parse_leaf_idc)"
      [ -n "$idc" ] && break
      echo "  $s rlnGifterRequest attempt $attempt failed ($req) — re-sync gifter + retry in ${REG_RETRY_SLEEP}s" >&2
      sync_wallet "$GIFTER" >/dev/null 2>&1; sleep "$REG_RETRY_SLEEP"
    done
    if [ -z "$idc" ]; then echo "  rlnGifterRequest response: $req" >&2; diagnose_reg "$GIFTER"; exit 1; fi
    confirm_and_ready "$s" "$idc" "$lopt" "$pid"
  fi
done

echo "=== mesh: every node adds the other 4 ==="
for a in $ALL; do for b in $ALL; do [ "$a" = "$b" ] && continue
  jcall "$a" libp2p_module mixNodepoolAdd \
    "{\"peerId\":\"$(gv PEERID "$b")\",\"multiaddr\":\"$(gv MADDR "$b")\",\"mixPubKey\":\"$(gv MIXPUB "$b")\",\"libp2pPubKey\":\"$(gv LPPUB "$b")\"}" >/dev/null 2>&1
done; done
echo "  meshed."

echo "=== rlnIsReady status (each node was confirmed ready before the next registered) ==="
line="  "; for s in $ALL; do line="$line $s=$(call "$s" libp2p_module rlnIsReady | jval)"; done; echo "$line"

echo "=== root convergence: wait until every node's valid-roots window includes the final root ==="
converge_roots

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
vtot=0
for n in $ALL; do
  g=$($DC logs --since 240s "$n" 2>&1 | grep -c 'Generated RLN proof successfully')
  v=$($DC logs --since 240s "$n" 2>&1 | grep -c 'Proof verified successfully')
  echo "  $n: generated=$g verified=$v"; vtot=$((vtot+v))
done
sgen=$($DC logs --since 240s sender 2>&1 | grep -c 'Generated RLN proof successfully')
echo "  replies: sender->dest=$SD dest->sender=$DS ; total verifications=$vtot ; sender proofs=$sgen"
# Gifted allocations succeeded at the gifter (relay1): one log line per client.
greg=$($DC logs --since 1800s "$GIFTER" 2>&1 | grep -c 'RLN gifter registration succeeded')
echo "  gifter($GIFTER): 'RLN gifter registration succeeded' x$greg (expect 4 in the happy path)"

echo "=== VERDICT ==="
if [ "$NEG" != "0" ]; then
  if [ "$SD" = "0" ] && [ "$sgen" = "0" ]; then
    echo "  PASS (negative): sender got 0 replies and generated 0 proofs -> rejected (NEG=$NEG)."
  else
    echo "  FAIL (negative): expected 0 replies / 0 sender proofs, got replies=$SD sgen=$sgen"
    echo "DONE (NEG=$NEG)"; exit 1
  fi
else
  exp="sender->dest=$MSG_COUNT dest->sender=$MSG_COUNT"; ok=1
  [ "$SD" = "$MSG_COUNT" ] || ok=0
  [ "$DS" = "$MSG_COUNT" ] || ok=0
  if [ "$ok" = "1" ]; then echo "  PASS: every round-trip got a reply ($exp)."
  else echo "  FAIL: expected $exp, got sender->dest=$SD dest->sender=$DS"; echo "DONE (NEG=$NEG)"; exit 1; fi
fi
echo "DONE (NEG=$NEG)"
