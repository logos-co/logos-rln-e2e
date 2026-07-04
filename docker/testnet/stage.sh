#!/usr/bin/env bash
# VENDORED from logos-lez-rln/tools/deployments/stage.sh — keep in sync with the
# canonical copy there. The image build must be self-contained (it runs stage.sh
# at build time, before logos-lez-rln is available), so this copy lives in the
# build context. jq is present in the image + on host.
# Stage a deployment descriptor into a flat fixture dir the daemons/binaries consume.
# FEATURE: deployment-profile tooling — one descriptor+wallet is the source of truth.
#
#   bash stage.sh <deployment_dir> <out_dir>
#
# A deployment is fully captured by tree_id + wallet (storage.json). config is a
# derived cache of tree_id; payment/supply are pointers into the wallet. This emits
# the flat files (storage.json, wallet_config.json, {config,payment,supply}.txt,
# env.sh) enforcing the wallet<->deployment binding so a mismatched wallet fails
# here, not at runtime. Bash+jq (no Python) so every sim + the image build share it.
# The guest-drift guard (re-deriving config from the guest binaries) is verify.sh.
set -euo pipefail

DEP_DIR="${1:?usage: stage.sh <deployment_dir> <out_dir>}"
OUT="${2:?usage: stage.sh <deployment_dir> <out_dir>}"
DESC="$DEP_DIR/deployment.json"
WALLET="$DEP_DIR/storage.json"
command -v jq >/dev/null || { echo "stage: FAIL: jq not found (apt install jq)" >&2; exit 1; }
[ -f "$DESC" ]   || { echo "stage: FAIL: missing $DESC" >&2; exit 1; }
[ -f "$WALLET" ] || { echo "stage: FAIL: missing $WALLET" >&2; exit 1; }

fail(){ echo "stage: FAIL: $1" >&2; exit 1; }
field(){ jq -re ".$1 // empty" "$DESC" 2>/dev/null || fail "descriptor missing required field '$1'"; }

NAME=$(field name); TREE=$(field tree_id); SEQ=$(field sequencer)
CFG=$(field config_account); PAY=$(field payment_account); SUP=$(field supply_holding)
field registration_program_id >/dev/null
[[ "$TREE" =~ ^[0-9a-f]{64}$ ]] || fail "tree_id must be 64 lowercase hex chars, got '$TREE'"

# rc6 wallet schema — refuse a wallet whose schema doesn't match the guest version.
jq -e '.key_chain.accounts' "$WALLET" >/dev/null 2>&1 \
  || fail "wallet schema is not rc6 (expected top-level 'key_chain.accounts')"
# wallet<->deployment binding: the wallet must actually hold payment + supply.
holds(){ jq -e --arg a "$1" 'any(.key_chain.accounts[]; .Public.account_id == $a)' "$WALLET" >/dev/null 2>&1; }
holds "$PAY" || fail "wallet does not contain payment_account=$PAY — descriptor and storage.json are mismatched (wrong wallet)"
holds "$SUP" || fail "wallet does not contain supply_holding=$SUP — descriptor and storage.json are mismatched (wrong wallet)"

mkdir -p "$OUT"
printf '%s' "$CFG" > "$OUT/config_account.txt"
printf '%s' "$PAY" > "$OUT/payment_account.txt"
printf '%s' "$SUP" > "$OUT/supply_holding.txt"
jq '.last_synced_block = 0' "$WALLET" > "$OUT/storage.json.seed"
jq -n --arg s "$SEQ" '{sequencer_addr:$s, seq_poll_timeout:"30s", seq_tx_poll_max_blocks:15, seq_poll_max_retries:10, seq_block_poll_max_amount:100}' > "$OUT/wallet_config.json"
cat > "$OUT/env.sh" <<EOF
#!/usr/bin/env bash
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export LEE_WALLET_HOME_DIR="\$SCRIPT_DIR"
export NSSA_WALLET_HOME_DIR="\$SCRIPT_DIR"
export LEZ_RLN_TREE_ID_HEX=$TREE
EOF

echo "stage: OK  $NAME  tree=${TREE:0:8}…  config=$CFG  payment=$PAY  supply=$SUP  -> $OUT"
