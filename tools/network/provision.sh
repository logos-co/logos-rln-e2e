#!/usr/bin/env bash
# tools/network/provision.sh — fund a payer on a hosted LEZ zone and provision
# the RLN deployment the e2e targets run against. One command per network:
#
#   bash tools/network/provision.sh networks/devnet.env [step]
#
# step: all (default) | node | payer | fund | deploy | presets | status | stop
#
# Nobody on a hosted zone has genesis powers, so native balance takes the one
# road there is: the bedrock faucet pays a note to a key our own bedrock node
# holds, and a channel deposit from that node bridges it into the zone for the
# payer. The zone credits a deposit once it is final on bedrock (~1 h), and it
# does so even while it is not inscribing — don't wait on the operator for that.
#
# Every step checks before it acts, so a re-run resumes: a running node is
# reused, a payer is minted once, a pending deposit is waited for rather than
# repeated, and a provisioned deployment is never provisioned twice (run_setup
# fails on an initialized tree).
#
# Secrets stay out of the repo, under NETWORK_STATE
# (~/.local/share/logos-rln-e2e/<NETWORK>):
#   bedrock/                      node binary, user_config.yaml, keystore, chain state
#   payer-wallet/                 the LEZ payer (storage.json holds real funds)
#   deployments/<DEPLOYMENT>/     provision.sh output; storage.json is the wallet
#                                 --target <NETWORK> reads (E2E_PAYER_WALLET)
#   state.json                    funding key, pending deposit
# The public descriptor is copied to this repo's deployments/<DEPLOYMENT>/.
#
# Needs: curl, jq, python3, and a logos-lez-rln checkout (LEZ_RLN_CHECKOUT,
# default ../logos-lez-rln) with release builds of mint_payer, run_setup and
# derive_accounts and the guest binaries — the same build --target local uses.
#
# Env overrides: NETWORK_STATE, LEZ_RLN_CHECKOUT, BEDROCK_HTTP (127.0.0.1:8080),
# BEDROCK_NET_PORT (3000), DEPOSIT_WAIT_S (7200).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

say() { printf '%s\n' "network: $*" >&2; }
die() { printf '%s\n' "network: FAIL: $*" >&2; exit 1; }

CONF="${1:-}"
STEP="${2:-all}"
[ -n "$CONF" ] && [ -f "$CONF" ] || die "usage: provision.sh networks/<name>.env [all|node|payer|fund|deploy|presets|status|stop]"
# shellcheck source=/dev/null
. "$CONF"
for v in NETWORK DEPLOYMENT LEZ_SEQUENCER LEZ_CHANNEL BEDROCK_RELEASE BEDROCK_PEERS FAUCET_URL \
         DEPOSIT_AMOUNT PAYER_MIN RLN_EPOCH_SIZE_SEC; do
    [ -n "${!v:-}" ] || die "$CONF does not set $v"
done
for tool in curl jq python3; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

STATE="${NETWORK_STATE:-$HOME/.local/share/logos-rln-e2e/$NETWORK}"
NODE_DIR="$STATE/bedrock"
PAYER_WS="$STATE/payer-wallet"
DEP_OUT="$STATE/deployments"
STATE_JSON="$STATE/state.json"
HTTP="${BEDROCK_HTTP:-127.0.0.1:8080}"
LEZ="${LEZ_RLN_CHECKOUT:-$ROOT/../logos-lez-rln}"
mkdir -p "$STATE"
chmod 700 "$STATE"
[ -f "$STATE_JSON" ] || echo '{}' > "$STATE_JSON"

state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_JSON"; }
state_set() {
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE_JSON" > "$STATE_JSON.tmp" && mv "$STATE_JSON.tmp" "$STATE_JSON"
}
state_del() {
    jq --arg k "$1" 'del(.[$k])' "$STATE_JSON" > "$STATE_JSON.tmp" && mv "$STATE_JSON.tmp" "$STATE_JSON"
}

# ---------- chain reads -------------------------------------------------------

lez_rpc() {
    curl -sS -m 30 -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$LEZ_SEQUENCER"
}
lez_balance() { lez_rpc getAccount "[\"$1\"]" | jq -r '.result.balance // empty'; }
bedrock() { curl -sS -m 60 "$@"; }
bedrock_balance_json() { bedrock "http://$HTTP/wallet/$(state_get funding_key)/balance"; }

# base58 account id -> JSON array of its 32 bytes (the deposit metadata:
# borsh(DepositMetadata { recipient_id }) is the raw id).
account_bytes_json() {
    python3 - "$1" <<'EOF'
import json, sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + A.index(c)
print(json.dumps(list(n.to_bytes(32, "big"))))
EOF
}
ge() { python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$1" "$2"; }

# ---------- node ----------------------------------------------------------------

node_asset() {
    local os arch
    case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) die "unsupported OS $(uname -s)" ;; esac
    case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; x86_64) arch=x86_64 ;; *) die "unsupported arch $(uname -m)" ;; esac
    printf 'logos-blockchain-node-%s-%s-%s.tar.gz' "$os" "$arch" "$BEDROCK_RELEASE"
}

node_up() { curl -s -m 5 "http://$HTTP/cryptarchia/info" >/dev/null 2>&1; }

step_node() {
    mkdir -p "$NODE_DIR"
    local bin="$NODE_DIR/logos-blockchain-node"
    if [ ! -x "$bin" ] || ! "$bin" --version 2>/dev/null | grep -q " $BEDROCK_RELEASE$"; then
        local asset
        asset=$(node_asset)
        say "downloading $asset"
        curl -fsSL -o "$NODE_DIR/$asset" \
            "https://github.com/logos-blockchain/logos-blockchain/releases/download/$BEDROCK_RELEASE/$asset" \
            || die "download of $asset failed"
        tar xzf "$NODE_DIR/$asset" -C "$NODE_DIR" && rm -f "$NODE_DIR/$asset"
        [ -x "$bin" ] || die "no logos-blockchain-node in $asset"
    fi
    if [ ! -f "$NODE_DIR/user_config.yaml" ]; then
        say "init-config (peers from $CONF)"
        local -a peers
        # shellcheck disable=SC2206  # one multiaddr per line/word
        peers=($BEDROCK_PEERS)
        (cd "$NODE_DIR" && ./logos-blockchain-node init-config -o user_config.yaml \
            --http-host "$HTTP" --state-path ./state --net-port "${BEDROCK_NET_PORT:-3000}" \
            -p "${peers[@]}") >/dev/null || die "init-config failed"
    fi
    if [ -z "$(state_get funding_key)" ]; then
        # The first wallet key: not the staking (cryptarchia) or SDP funding key.
        local key
        key=$(awk '/^wallet:/{w=1} w&&/known_keys:/{k=1;next} k&&/^ +[0-9a-f]{64}:/{sub(/:.*/,"");gsub(/ /,"");print;exit}' \
            "$NODE_DIR/user_config.yaml")
        [ -n "$key" ] || die "no wallet key in $NODE_DIR/user_config.yaml"
        state_set funding_key "$key"
    fi
    if node_up; then
        say "node already answering on $HTTP"
    else
        say "starting node ($NODE_DIR, HTTP $HTTP)"
        (cd "$NODE_DIR" && nohup ./logos-blockchain-node user_config.yaml \
            --log-backend file --log-dir ./logs --log-level info >node.stdout 2>&1 &)
        local _t
        for _t in $(seq 1 60); do node_up && break; sleep 2; done
        node_up || die "node did not answer on $HTTP — see $NODE_DIR/node.stdout"
    fi
    local _t info
    for _t in $(seq 1 90); do
        info=$(curl -s -m 5 "http://$HTTP/cryptarchia/info" | jq -r '.cryptarchia_info.state // empty')
        [ "$info" = "Online" ] && break
        sleep 10
    done
    say "node $(curl -s -m 5 "http://$HTTP/cryptarchia/info" | jq -c '{state:.cryptarchia_info.state, height:.cryptarchia_info.height}')" \
        "funding key $(state_get funding_key)"
}

# ---------- payer ---------------------------------------------------------------

step_payer() {
    if [ -n "$(state_get payer)" ] && [ -f "$PAYER_WS/storage.json" ]; then
        say "payer $(state_get payer)"
        return 0
    fi
    [ -x "$LEZ/lez-rln/target/release/mint_payer" ] \
        || die "no mint_payer in $LEZ/lez-rln/target/release (build lez-rln, or set LEZ_RLN_CHECKOUT)"
    mkdir -p "$PAYER_WS"
    jq -n --arg s "$LEZ_SEQUENCER" '{sequencers:[{sequencer_addr:$s}], seq_poll_timeout:"30s",
        seq_tx_poll_max_blocks:15, seq_poll_max_retries:10, seq_block_poll_max_amount:100,
        multi_sequencer_client_config:{distribution_limit:1, calibration_limit:3}}' > "$PAYER_WS/wallet_config.json"
    local payer
    payer=$(HOME="$PAYER_WS" LEE_WALLET_HOME_DIR="$PAYER_WS" "$LEZ/lez-rln/target/release/mint_payer") \
        || die "mint_payer failed"
    chmod 600 "$PAYER_WS/storage.json"
    state_set payer "$payer"
    say "minted payer $payer (wallet $PAYER_WS)"
}

# ---------- fund ----------------------------------------------------------------

wait_note() {
    local amount="$1" _t
    for _t in $(seq 1 90); do
        bedrock_balance_json | jq -e --argjson a "$amount" '.notes | to_entries | any(.value == $a)' >/dev/null 2>&1 \
            && return 0
        sleep 10
    done
    return 1
}

step_fund() {
    local payer bal key
    payer=$(state_get payer)
    [ -n "$payer" ] || die "no payer yet — run the payer step"
    key=$(state_get funding_key)
    [ -n "$key" ] || die "no funding key — run the node step"
    bal=$(lez_balance "$payer")
    [ -n "$bal" ] || die "cannot read the payer's balance from $LEZ_SEQUENCER"

    if [ -z "$(state_get pending_deposit)" ] && ge "$bal" "$PAYER_MIN"; then
        say "payer holds $bal (>= $PAYER_MIN) — no deposit needed"
        return 0
    fi

    if [ -z "$(state_get pending_deposit)" ]; then
        node_up || die "node not answering on $HTTP — run the node step"
        local need total
        need=$(python3 -c "print($DEPOSIT_AMOUNT + 1000000)")
        total=$(bedrock_balance_json | jq -r '.balance // 0')
        if ! ge "$total" "$need"; then
            say "bedrock wallet holds $total — claiming from the faucet"
            local code
            code=$(curl -s -m 30 -o "$STATE/faucet.out" -w '%{http_code}' -X POST "$FAUCET_URL/$key")
            case "$code" in
                202) ;;
                429) die "faucet cooldown: $(cat "$STATE/faucet.out") — re-run later" ;;
                *) die "faucet answered $code: $(cat "$STATE/faucet.out")" ;;
            esac
            local _t
            for _t in $(seq 1 60); do
                total=$(bedrock_balance_json | jq -r '.balance // 0')
                ge "$total" "$need" && break
                sleep 10
            done
            ge "$total" "$need" || die "faucet drip never arrived (bedrock balance $total)"
        fi

        # A deposit spends whole notes: make one of exactly DEPOSIT_AMOUNT.
        if ! bedrock_balance_json | jq -e --argjson a "$DEPOSIT_AMOUNT" '.notes | to_entries | any(.value == $a)' >/dev/null; then
            say "splitting a $DEPOSIT_AMOUNT note"
            bedrock -X POST -H 'Content-Type: application/json' "http://$HTTP/wallet/transactions/transfer-funds" \
                -d "{\"tip\":null,\"change_public_key\":\"$key\",\"funding_public_keys\":[\"$key\"],\"recipient_public_key\":\"$key\",\"amount\":$DEPOSIT_AMOUNT}" \
                >/dev/null || die "transfer-funds failed"
            wait_note "$DEPOSIT_AMOUNT" || die "the $DEPOSIT_AMOUNT note never appeared"
        fi
        local note body resp
        note=$(bedrock_balance_json | jq -r --argjson a "$DEPOSIT_AMOUNT" \
            '[.notes | to_entries[] | select(.value == $a) | .key][0]')
        body=$(jq -cn --arg ch "$LEZ_CHANNEL" --arg note "$note" --arg key "$key" \
            --argjson meta "$(account_bytes_json "$payer")" \
            '{tip:null, deposit:{channel_id:$ch, inputs:[$note], metadata:$meta},
              change_public_key:$key, funding_public_keys:[$key], max_tx_fee:100000}')
        resp=$(bedrock -X POST -H 'Content-Type: application/json' "http://$HTTP/channel/deposit" -d "$body") \
            || die "channel deposit failed"
        state_set pending_deposit "$(printf '%s' "$resp" | jq -r '.hash')"
        state_set pending_from_balance "$bal"
        say "deposited $DEPOSIT_AMOUNT for $payer (bedrock tx $(state_get pending_deposit)); credited once final (~1 h)"
    else
        say "deposit $(state_get pending_deposit) already pending"
    fi

    local from _t budget
    from=$(state_get pending_from_balance)
    budget="${DEPOSIT_WAIT_S:-7200}"
    for _t in $(seq 1 $(( budget / 60 ))); do
        bal=$(lez_balance "$payer")
        if [ -n "$bal" ] && ge "$bal" "$(python3 -c "print(${from:-0} + $DEPOSIT_AMOUNT // 2)")"; then
            state_del pending_deposit
            state_del pending_from_balance
            say "credited: payer holds $bal"
            return 0
        fi
        sleep 60
    done
    die "deposit not credited after ${budget}s (payer holds ${bal:-?}); re-run to keep waiting"
}

# ---------- deploy --------------------------------------------------------------

step_deploy() {
    local out="$DEP_OUT/$DEPLOYMENT" repo_desc="$ROOT/deployments/$DEPLOYMENT/deployment.json" payer
    payer=$(state_get payer)
    if [ -f "$out/deployment.json" ]; then
        say "deployment $DEPLOYMENT already provisioned ($(jq -r .tree_id "$out/deployment.json" | cut -c1-8)…)"
        # The committed descriptor names whoever provisioned it; an adopted
        # copy names this machine's payer and must not overwrite it.
        [ -f "$repo_desc" ] && return 0
    elif [ -f "$repo_desc" ]; then
        # Someone already provisioned this registry and committed it: use it
        # rather than deploying a second one. Only the payer is ours — the
        # descriptor's payer_account is just the account runs fund nodes from,
        # and the staged wallet must hold it.
        [ -n "$payer" ] && [ -f "$PAYER_WS/storage.json" ] || die "no payer — run the payer and fund steps"
        mkdir -p "$out"
        jq --arg p "$payer" '.payer_account = $p' "$repo_desc" > "$out/deployment.json"
        cp "$PAYER_WS/storage.json" "$out/storage.json"
        chmod 600 "$out/storage.json"
        say "adopted the committed deployments/$DEPLOYMENT (config $(jq -r .config_account "$repo_desc")) with payer $payer"
        return 0
    else
        [ -n "$payer" ] || die "no payer — run the payer and fund steps"
        [ -f "$LEZ/tools/deployments/provision.sh" ] || die "no tools/deployments/provision.sh under $LEZ"
        say "provisioning $DEPLOYMENT on $LEZ_SEQUENCER (fresh tree; run_setup takes a few minutes)"
        mkdir -p "$DEP_OUT"
        bash "$LEZ/tools/deployments/provision.sh" --name "$DEPLOYMENT" --sequencer "$LEZ_SEQUENCER" \
            --payer "$payer" --adopt-wallet "$PAYER_WS/storage.json" --outdir "$DEP_OUT" >&2 \
            || die "provision.sh failed"
        chmod 600 "$out/storage.json"
    fi
    mkdir -p "$ROOT/deployments/$DEPLOYMENT"
    cp "$out/deployment.json" "$ROOT/deployments/$DEPLOYMENT/deployment.json"
    say "descriptor: deployments/$DEPLOYMENT/deployment.json (commit it); wallet: $out/storage.json (never commit)"
}

# ---------- presets -------------------------------------------------------------

# The values a delivery preset / module network table needs for this network.
step_presets() {
    local desc="$DEP_OUT/$DEPLOYMENT/deployment.json" hex
    [ -f "$desc" ] || desc="$ROOT/deployments/$DEPLOYMENT/deployment.json"
    [ -f "$desc" ] || die "no deployment.json for $DEPLOYMENT — run the deploy step"
    hex=$(python3 - "$(jq -r .config_account "$desc")" <<'EOF'
import sys
A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + A.index(c)
print(n.to_bytes(32, "big").hex())
EOF
    )
    jq -n --arg net "$NETWORK" --arg reg "logos:$NETWORK:$hex" --arg seq "$LEZ_SEQUENCER" \
        --argjson epoch "$RLN_EPOCH_SIZE_SEC" --slurpfile d "$desc" \
        '{network:$net, registry_id:$reg, epoch_size_sec:$epoch, sequencer:$seq,
          config_account:$d[0].config_account, tree_id:$d[0].tree_id,
          delivery_preset_entry:{enabled:true, "registry-id":$reg, "epoch-size-sec":$epoch}}'
}

# ---------- status / stop -------------------------------------------------------

step_status() {
    local payer
    payer=$(state_get payer)
    say "state: $STATE"
    say "node: $(node_up && curl -s -m 5 "http://$HTTP/cryptarchia/info" | jq -c '.cryptarchia_info | {state,height}' || echo down)"
    [ -n "$(state_get funding_key)" ] && node_up \
        && say "bedrock balance: $(bedrock_balance_json | jq -r '.balance')"
    [ -n "$payer" ] && say "payer $payer: $(lez_balance "$payer") on $LEZ_SEQUENCER"
    [ -n "$(state_get pending_deposit)" ] && say "pending deposit: $(state_get pending_deposit)"
    [ -f "$DEP_OUT/$DEPLOYMENT/deployment.json" ] && say "deployment: $DEPLOYMENT provisioned"
    return 0
}

step_stop() {
    local pids
    pids=$(pgrep -f "$NODE_DIR/logos-blockchain-node|logos-blockchain-node user_config.yaml" || true)
    [ -n "$pids" ] || { say "no node running"; return 0; }
    # shellcheck disable=SC2086
    kill $pids && say "stopped node ($pids)"
}

case "$STEP" in
    node) step_node ;;
    payer) step_payer ;;
    fund) step_fund ;;
    deploy) step_deploy ;;
    presets) step_presets ;;
    status) step_status ;;
    stop) step_stop ;;
    all) step_node; step_payer; step_fund; step_deploy; step_presets ;;
    *) die "unknown step '$STEP'" ;;
esac
