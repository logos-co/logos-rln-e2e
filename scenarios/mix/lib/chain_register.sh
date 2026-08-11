# shellcheck shell=bash
# scenarios/mix/lib/chain_register.sh — the chain bridge: compile + run the
# credential tool, register its members.json on-chain through the registry
# provider, and assert the defining equality — the plugin tree's root is a
# valid root of the on-chain registry.
#
# Uses the harness daemon/wallet/chain libs; expects the target contract env
# (deployment provisioned, E2E_MODULES_DIR resolved) and $MIX_STACK from
# stack.sh (the tool compiles inside the checkout so nimble.paths resolves
# the plugin imports; their build_setup.sh does the same).

_MIX_TOOL_BIN=""

mix_tool_build() {
    [ -n "$MIX_STACK" ] || die "mix_tool_build before mix_stack_checkout"
    [ -f "$MIX_STACK/nimble.paths" ] || die "no nimble.paths in $MIX_STACK (run stack.sh build)"
    local src dst
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/setup_chain_credentials.nim"
    dst="$MIX_STACK/simulations/mixnet/e2e_setup_chain_credentials.nim"
    cp "$src" "$dst"
    _MIX_TOOL_BIN="$E2E_RUN_DIR/mix/setup_chain_credentials"
    mkdir -p "$E2E_RUN_DIR/mix"
    say "mix: compiling credential tool"
    ( cd "$MIX_STACK" \
      && export PATH="$HOME/.nimble/bin:$PATH" \
      && nim c -d:release --mm:refc \
            --passL:"$MIX_STACK/librln_v2.0.2.a" --passL:-lm \
            -o:"$_MIX_TOOL_BIN" "$dst" ) \
        > "$E2E_RUN_DIR/mix/tool-build.log" 2>&1 \
        || { tail -20 "$E2E_RUN_DIR/mix/tool-build.log" >&2; die "credential tool build failed"; }
}

# mix_creds_setup <creds-dir> — run the tool (cwd = creds dir: the plugin
# resolves rln_tree.db / keystores relative to cwd). Exports MIX_TREE_ROOT.
mix_creds_setup() {
    local creds="$1"
    [ -x "$_MIX_TOOL_BIN" ] || die "mix_creds_setup before mix_tool_build"
    mkdir -p "$creds"
    ( cd "$creds" && "$_MIX_TOOL_BIN" ) > "$creds/setup.log" 2>&1 \
        || { tail -20 "$creds/setup.log" >&2; die "credential setup failed"; }
    MIX_TREE_ROOT=$(grep -oE 'TREE_ROOT=[0-9a-f]{64}' "$creds/setup.log" | cut -d= -f2)
    [ -n "$MIX_TREE_ROOT" ] || die "tool printed no TREE_ROOT (see $creds/setup.log)"
    [ -f "$creds/members.json" ] || die "tool wrote no members.json"
    say "mix: credentials ready, plugin tree root $MIX_TREE_ROOT"
}

# mix_chain_register <node> <creds-dir> — register members.json in insertion
# order via the registry provider on an already-running harness daemon, then
# assert MIX_TREE_ROOT is a valid on-chain root.
mix_chain_register() {
    local node="$1" creds="$2"
    local members="$creds/members.json"
    local count price total commitment rate i leaf reg

    count=$(jq length "$members")
    price=$(node_call "$node" "$E2E_REGISTRY_MOD" get_registry_bounds \
        "$(argfile mixreg_cfg "$E2E_CONFIG_ACCOUNT")" | jres | jfield price_per_unit)
    case "$price" in ''|*[!0-9]*) die "cannot read price_per_unit from bounds" ;; esac

    say "mix: funding $count registrations (price $price/unit)"
    local holding
    holding=$(wallet_fresh_holding "$node") || die "no unused holding account"
    total=0
    for i in $(seq 0 $((count - 1))); do
        rate=$(jq -r ".[$i].rate_limit" "$members")
        total=$((total + rate * price))
    done
    wallet_claim_chunked "$node" "$E2E_CONFIG_ACCOUNT" "$holding" "$total"

    say "mix: registering $count members in tree order"
    for i in $(seq 0 $((count - 1))); do
        commitment=$(jq -r ".[$i].id_commitment" "$members")
        rate=$(jq -r ".[$i].rate_limit" "$members")
        reg=$(node_call "$node" "$E2E_REGISTRY_MOD" register_member \
            "$(argfile mixreg_cfg2 "$E2E_CONFIG_ACCOUNT")" \
            "$(argfile mixreg_hold "$holding")" \
            "$(argfile mixreg_idc "$commitment")" "$rate" | jres) || reg=""
        case "$reg" in
            *'"pending":true'*|*'"already_registered":true'*) ;;
            *) die "register_member($i) failed: ${reg:-<empty>}" ;;
        esac
        leaf=$(printf '%s' "$reg" | jfield leaf_index)
        # Sequential confirmation keeps the single funding wallet nonce-safe
        # and pins the on-chain insertion order to the manifest order.
        confirm_and_ready "$node" "$commitment" "$leaf" "member $i" \
            || die "member $i never confirmed (leaf ${leaf:-?})"
        [ "${E2E_ACTUAL_LEAF:-$leaf}" = "$i" ] \
            || die "member $i landed at leaf ${E2E_ACTUAL_LEAF:-$leaf} — on-chain order diverged from the manifest; roots cannot match"
    done

    say "mix: asserting plugin root on-chain"
    local proofs chain_roots
    proofs=$(node_call "$node" "$E2E_REGISTRY_MOD" get_merkle_proofs \
        "$(argfile mixreg_cfg3 "$E2E_CONFIG_ACCOUNT")" '[0]' | jres) || proofs=""
    [ -n "$proofs" ] || die "get_merkle_proofs failed after registration"
    chain_roots=$(printf '%s' "$proofs" | python3 -c '
import json, sys
p = json.load(sys.stdin)[0]
print("\n".join([p["root"]] + p.get("valid_roots", [])))')
    if printf '%s\n' "$chain_roots" | grep -qx "$MIX_TREE_ROOT"; then
        say "mix: ROOT MATCH — plugin tree root $MIX_TREE_ROOT is an on-chain valid root"
    else
        say "chain roots:"; printf '%s\n' "$chain_roots" >&2
        die "plugin root $MIX_TREE_ROOT not among the chain's valid roots — leaf construction or order diverged"
    fi
}
