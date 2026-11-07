#!/usr/bin/env bash
# scenarios/two-registries — one membership module, two registries on one
# chain, two epochs. 0.4 puts the mix network on its own membership tree
# (10 s epoch) beside the delivery tree (600 s epoch), both reached through
# one liblogos_rln_module in one process. This drives that module directly:
#
#   each registry's config carries its own rate-limit range (D 100..=600,
#   M 20..=100), reported by get_registry_bounds / get_registry_parameters
#   -> one start() naming both registries (the mix one at its own epoch)
#   -> a rate outside a registry's range is refused before anything is paid
#   -> register on each (relay scope on D at 100, the LIP mix scope on M at
#      20), both active
#   -> keystore and registry parameters are per registry
#   -> proofs on each validate; the mix wire shape (no external_nullifier)
#      validates on M; a proof from one registry is invalid under the other
#   -> M's quota resets after its 10 s epoch while D's does not
#   -> validating on M does not forget D's nullifiers (re-validating D's
#      proof after M traffic reads `duplicate`, never `valid`)
#   -> a later start() naming only D leaves M at 10 s
#   -> a tampered signal is invalid on each
#
# What it is for: two defects a 10 s registry beside a 600 s one hit in the
# module before 0.14.2 — one shared nullifier log pruned by the fast
# registry's epoch index (every mix validate emptied the delivery log), and a
# start() that replaced another consumer's per-registry epoch.
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100               rate limit of the D registration
#   E2E_MIX_RATE_LIMIT=20            rate limit of the M registration
#   E2E_DELIVERY_RATE_BOUNDS="100 600", E2E_MIX_RATE_BOUNDS="20 100"
#                                    the ranges the target provisioned
#                                    (profiles/local-default/registry-*.env)
#   E2E_DELIVERY_EPOCH_SIZE_SEC=600  D's epoch (the instance default)
#   E2E_MIX_EPOCH_SIZE_SEC=10        M's epoch; E2E_MIX_MAX_EPOCH_GAP=3 its gap
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain registry; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
M_RATE_LIMIT="${E2E_MIX_RATE_LIMIT:-20}"
D_BOUNDS="${E2E_DELIVERY_RATE_BOUNDS:-100 600}"
M_BOUNDS="${E2E_MIX_RATE_BOUNDS:-20 100}"
D_EPOCH="${E2E_DELIVERY_EPOCH_SIZE_SEC:-600}"
M_EPOCH="${E2E_MIX_EPOCH_SIZE_SEC:-10}"
M_GAP="${E2E_MIX_MAX_EPOCH_GAP:-3}"
NODE=n1

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_PAYER E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S E2E_ROOT_WINDOW_TIMEOUT_S \
          E2E_REGISTRIES; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_POLL_INTERVAL_S" -ge 1 ] 2>/dev/null || die "E2E_POLL_INTERVAL_S must be a positive integer"
case " $E2E_REGISTRIES " in
    *" mix "*) ;;
    *) die "the target provisioned no 'mix' registry (E2E_REGISTRIES=$E2E_REGISTRIES)" ;;
esac

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODE_UP=0
DYING=0
die() {
    printf '%s\n' "e2e: FAIL: $*" >&2
    if [ "$DYING" = 0 ] && [ "$NODE_UP" = 1 ]; then
        DYING=1
        echo "---- node log tail ----" >&2
        node_logs "$NODE" 40 >&2 || true
    fi
    exit 1
}
cleanup() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving node $NODE up, state in $E2E_RUN_DIR"
        return
    fi
    [ "$NODE_UP" = 1 ] && daemon_stop "$NODE"
}
trap cleanup EXIT

# ---------- the two registries -----------------------------------------------
D=$(registry_id default) || die "no default registry id"
M=$(registry_id mix) || die "no mix registry id"
[ "$D" != "$M" ] || die "the two registries resolve to one id: $D"
D_CFG=$(registry_config_account default)
M_CFG=$(registry_config_account mix)
# The LIP LOGOS-MIXNET profile's scope ("mix-rln-spam-protection/v1",
# zero-padded); the relay scope is this run's own.
MIX_ID=6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000
RELAY_ID=$(openssl rand -hex 32)
say "D (delivery, ${D_EPOCH}s): $D (tree $(registry_tree default | cut -c1-8)…)"
say "M (mix, ${M_EPOCH}s/gap $M_GAP): $M (tree $(registry_tree mix | cut -c1-8)…)"

# JSON plumbing beyond json.sh: a nested field, and a membership-hash lookup.
jpath() { python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[k]
print(d if not isinstance(d, (dict, list)) else json.dumps(d))' "$@" 2>/dev/null; }

# Usage: rln <method> [args…]  -> the value of a liblogos_rln_module call
rln() { node_call "$NODE" liblogos_rln_module "$@" | jres | jval; }

# ---------- node --------------------------------------------------------------
section "node"
export E2E_DAEMON_ENV="${E2E_DAEMON_ENV:-} LOGOS_RLN_DISABLE_AUTO_UNLOCK=1"
daemon_self_paying "$NODE" "$E2E_RUN_DIR/wallet-$NODE"
daemon_start "$NODE" || die "daemon_start $NODE failed"
NODE_UP=1
daemon_load_modules "$NODE" liblogos_lez_rln_module liblogos_rln_module \
    || die "load-module failed"

section "wallet"
wallet_open "$NODE" || die "wallet open failed"
CHAIN_HEAD=$(chain_head) || die "cannot probe chain head at $E2E_SEQUENCER"
say "syncing wallet to chain head $CHAIN_HEAD"
wallet_sync "$NODE" >/dev/null || die "wallet sync failed"
BOUNDS=$(node_call "$NODE" liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$D_CFG")" | jres) || BOUNDS=""
[ -n "$BOUNDS" ] || die "get_registry_bounds failed on D (rln module up?)"
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
say "the registrations cost $(( (RATE_LIMIT + M_RATE_LIMIT) * ${PRICE:-0} )) native plus the fees; funding for two"
PAYER=$(wallet_payer "$NODE") || die "the registry module published no payer"
wallet_fund "$NODE" >/dev/null || die "funding the payer $PAYER never landed"
say "payer funded: $PAYER"

# ---------- each registry's own rate-limit range -------------------------------
section "registry bounds"
# The range is config state, set when the registry was provisioned
# (registry-<name>.env in the profile), so two registries on one program
# deployment differ. The registry module reads it off the chain; the
# descriptor the target staged says what was asked for.
# Usage: assert_bounds <name> <config-account> <want "min max">
assert_bounds() {
    local name="$1" cfg="$2" want="$3" got staged
    got=$(node_call "$NODE" liblogos_lez_rln_module get_registry_bounds "$(argfile "b_$name" "$cfg")" | jres) \
        || die "get_registry_bounds failed on $name"
    [ "$(printf '%s' "$got" | jfield min_rate_limit) $(printf '%s' "$got" | jfield max_rate_limit)" = "$want" ] \
        || die "$name: on-chain rate-limit bounds != $want: $got"
    staged=$(registry_bounds "$name") || exit 1
    [ "$staged" = "$want" ] || die "$name: the staged descriptor records bounds '$staged', the run expects '$want'"
}
assert_bounds default "$D_CFG" "$D_BOUNDS"
assert_bounds mix "$M_CFG" "$M_BOUNDS"
say "bounds: D $(printf '%s' "$D_BOUNDS" | tr ' ' -), M $(printf '%s' "$M_BOUNDS" | tr ' ' -) (config state, per registry)"

# ---------- one start() for both registries -----------------------------------
section "start: both registries, two epochs"
START_CFG="{\"epoch_size_sec\":$D_EPOCH,\"registries\":[\"$D\",{\"registry_id\":\"$M\",\"epoch_size_sec\":$M_EPOCH,\"max_epoch_gap\":$M_GAP}],\"provision\":false}"
START=$(rln start "$START_CFG") || START=""
case "$START" in
    *'"started":true'*) ;;
    *) die "start failed: ${START:-<empty>}" ;;
esac
# The reply's per-registry table must carry M at its epoch; D's is asserted
# through get_registry_parameters below (the table's shape for a plain-string
# entry changed in 0.14.2 and is not what this scenario is about).
[ "$(printf '%s' "$START" | jpath overrides "$M" epoch_size_sec)" = "$M_EPOCH" ] \
    || die "start reply does not carry M at ${M_EPOCH}s: $START"
say "start: D ${D_EPOCH}s, M ${M_EPOCH}s/gap $M_GAP in one call"

# ---------- a membership on each --------------------------------------------
section "registration: D then M"
UNLOCK=$(node_call "$NODE" liblogos_rln_module unlock_keystore e2e-test-password | jres) || UNLOCK=""
case "$UNLOCK" in
    *'"unlocked":true'*) say "keystore unlocked" ;;
    *) die "unlock_keystore failed: ${UNLOCK:-<empty>}" ;;
esac
# Usage: rate_options <rate>  -> the RegistryOptions JSON for a rate limit
rate_options() { printf '[{"key":"rate_limit","value":"%s"}]' "$1"; }

# Out of range is refused by the module's pre-check, before a credential is
# minted or anything is paid — in the terms of the registry asked, not of a
# constant: 101 is fine on D and refused on M, 99 the other way round.
# Usage: refuse_rate <registry> <rlnid> <tag> <name> <rate>
refuse_rate() {
    local raw
    raw=$(node_call "$NODE" liblogos_rln_module register_membership \
        "$1" "$(argfile "bad_$3" "$2")" "$(rate_options "$5")") || raw=""
    case "$raw" in
        *"outside registry bounds"*) say "$4: rate $5 refused — $(printf '%s' "$raw" | grep -o 'rate_limit [0-9]* outside registry bounds \[[0-9]*, [0-9]*\]' | head -1)" ;;
        *'"state":"pending"'*) die "$4: a registration at rate $5 was ACCEPTED (bounds $(registry_bounds "$4")): $raw" ;;
        *) die "$4: rate $5 failed for another reason than the bounds: ${raw:-<empty>}" ;;
    esac
}
refuse_rate "$M" "$MIX_ID" m mix "$(( ${M_BOUNDS#* } + 1 ))"
refuse_rate "$D" "$RELAY_ID" d default "$(( ${D_BOUNDS%% *} - 1 ))"

# Usage: register_on <registry> <rlnid> <tag> <name> <rate>
# Registers, polls to active, cross-checks on chain through the registry
# module; records sv HASH/LEAF/IDC <tag>.
register_on() {
    local registry="$1" rlnid="$2" tag="$3" name="$4" rate="$5" reg hash idc state state_json _t
    reg=$(node_call "$NODE" liblogos_rln_module register_membership \
        "$registry" "$(argfile "rlnid_$tag" "$rlnid")" "$(rate_options "$rate")" | jres) || reg=""
    case "$reg" in
        *'"state":"pending"'*) ;;
        *) die "register on $name failed: ${reg:-<empty>}" ;;
    esac
    hash=$(printf '%s' "$reg" | jfield membership_hash)
    idc=$(printf '%s' "$reg" | jpath credential identity_commitment)
    say "$name: pending membership $hash at rate $rate"
    state=""
    for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        state_json=$(node_call "$NODE" liblogos_rln_module get_membership_state \
            "$registry" "$(argfile "st_$tag" "$rlnid")" | jres) || state_json=""
        state=$(printf '%s' "$state_json" | jfield state)
        say "  $name poll $_t: ${state:-<none>}"
        case "$state" in
            active|grace_period) break ;;
            failed) die "$name: registration FAILED: $(rln get_memberships "$registry")" ;;
        esac
        sleep "$E2E_POLL_INTERVAL_S"
    done
    [ "$state" = "active" ] || [ "$state" = "grace_period" ] \
        || die "$name: membership never became active (last state: ${state:-<none>})"
    confirm_and_ready "$NODE" "$idc" "$(printf '%s' "$state_json" | jfield leaf_index)" "$name" "$name" \
        || die "$name: the registry module does not see the membership on chain"
    sv HASH "$tag" "$hash"
    sv LEAF "$tag" "$E2E_ACTUAL_LEAF"
    sv IDC "$tag" "$idc"
}
register_on "$D" "$RELAY_ID" d default "$RATE_LIMIT"
register_on "$M" "$MIX_ID" m mix "$M_RATE_LIMIT"
say "active: D leaf $(gv LEAF d) at rate $RATE_LIMIT, M leaf $(gv LEAF m) at rate $M_RATE_LIMIT"

# ---------- per-registry state -----------------------------------------------
section "per-registry state"
LIST_D=$(rln get_memberships "$D") || LIST_D=""
LIST_M=$(rln get_memberships "$M") || LIST_M=""
case "$LIST_D" in *"$(gv HASH d)"*) ;; *) die "get_memberships(D) lacks D's membership: $LIST_D" ;; esac
case "$LIST_M" in *"$(gv HASH m)"*) ;; *) die "get_memberships(M) lacks M's membership: $LIST_M" ;; esac
case "$LIST_D" in *"$(gv HASH m)"*) die "get_memberships(D) lists M's membership: $LIST_D" ;; esac
case "$LIST_M" in *"$(gv HASH d)"*) die "get_memberships(M) lists D's membership: $LIST_M" ;; esac
say "keystore: each registry lists only its own membership"

PARAMS_D=$(rln get_registry_parameters "$D" "$(argfile p_d "$RELAY_ID")") || PARAMS_D=""
PARAMS_M=$(rln get_registry_parameters "$M" "$(argfile p_m "$MIX_ID")") || PARAMS_M=""
[ "$(printf '%s' "$PARAMS_D" | jfield epoch_size_sec)" = "$D_EPOCH" ] \
    || die "get_registry_parameters(D) epoch != $D_EPOCH: $PARAMS_D"
[ "$(printf '%s' "$PARAMS_M" | jfield epoch_size_sec)" = "$M_EPOCH" ] \
    || die "get_registry_parameters(M) epoch != $M_EPOCH: $PARAMS_M"
[ "$(printf '%s' "$PARAMS_M" | jfield max_epoch_gap)" = "$M_GAP" ] \
    || die "get_registry_parameters(M) gap != $M_GAP: $PARAMS_M"
# The bounds ride along, per registry, from the registry module's read.
[ "$(printf '%s' "$PARAMS_D" | jfield min_rate_limit) $(printf '%s' "$PARAMS_D" | jfield max_rate_limit)" = "$D_BOUNDS" ] \
    || die "get_registry_parameters(D) bounds != $D_BOUNDS: $PARAMS_D"
[ "$(printf '%s' "$PARAMS_M" | jfield min_rate_limit) $(printf '%s' "$PARAMS_M" | jfield max_rate_limit)" = "$M_BOUNDS" ] \
    || die "get_registry_parameters(M) bounds != $M_BOUNDS: $PARAMS_M"
say "registry parameters: D ${D_EPOCH}s rate $(printf '%s' "$D_BOUNDS" | tr ' ' -), M ${M_EPOCH}s/gap $M_GAP rate $(printf '%s' "$M_BOUNDS" | tr ' ' -)"

# ---------- proofs on each ---------------------------------------------------
section "proofs"
# Re-warm after the registrations: start is idempotent and names the same
# registries, so the root windows pick up the post-registration roots now
# rather than on the next refresher tick.
rln start "$START_CFG" >/dev/null

# Usage: prove <registry> <rlnid> <signal_hex> <ts> <tag>  -> proof json
prove() {
    local proof
    proof=$(rln generate_proof "$1" "$(argfile "g_$5" "$2")" "$(argfile "gs_$5" "$3")" "str:$4") || proof=""
    case "$proof" in
        *'"proof"'*'"nullifier"'*|*'"nullifier"'*'"proof"'*) printf '%s' "$proof" ;;
        *) die "generate_proof on $5 failed: ${proof:-<empty>}" ;;
    esac
}
# Usage: verdict <registry> <rlnid> <signal_hex> <ts> <proof> <tag>  -> verdict word (or the raw reply)
verdict() {
    local out
    out=$(rln validate_proof "$1" "$(argfile "v_$6" "$2")" "$(argfile "vs_$6" "$3")" "str:$4" "$(argfile "vp_$6" "$5")") || out=""
    case "$out" in
        *'"verdict":"'*) printf '%s' "$out" | jfield verdict ;;
        *) printf '%s' "${out:-<empty>}" ;;
    esac
}
# Usage: verdict_warm <registry> <rlnid> <signal_hex> <ts> <proof> <tag>
# The first validation on a registry: polls not_ready (cold window) and a
# window that has not adopted the registration's root yet away.
verdict_warm() {
    local v _t
    for _t in $(seq 1 "$(polls "$E2E_ROOT_WINDOW_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
        v=$(verdict "$@")
        case "$v" in
            valid|duplicate|rate_limit_violation) printf '%s' "$v"; return 0 ;;
            invalid|*not_ready*) say "  $6: window not warm yet ($v, $_t)"; sleep "$E2E_POLL_INTERVAL_S" ;;
            *) die "validate_proof on $6 failed: $v" ;;
        esac
    done
    die "$6: validate_proof never left $v (root window warm-up)"
}

SIG_D=$(printf 'delivery signal' | to_hex)
SIG_M=$(printf 'mix signal' | to_hex)
TS_D=$(date +%s)
PROOF_D=$(prove "$D" "$RELAY_ID" "$SIG_D" "$TS_D" D) || exit 1
QUOTA_D=$(rln get_epoch_quota "$D" "$(argfile q_d "$RELAY_ID")" "str:$TS_D")
V=$(verdict_warm "$D" "$RELAY_ID" "$SIG_D" "$TS_D" "$PROOF_D" D) || exit 1
[ "$V" = valid ] || die "D's own proof read $V"
say "D: proof valid (epoch $(printf '%s' "$PROOF_D" | jfield epoch_index))"

TS_M=$(date +%s)
PROOF_M=$(prove "$M" "$MIX_ID" "$SIG_M" "$TS_M" M) || exit 1
QUOTA_M=$(rln get_epoch_quota "$M" "$(argfile q_m "$MIX_ID")" "str:$TS_M")
V=$(verdict_warm "$M" "$MIX_ID" "$SIG_M" "$TS_M" "$PROOF_M" M) || exit 1
[ "$V" = valid ] || die "M's own proof read $V"
say "M: proof valid (epoch $(printf '%s' "$PROOF_M" | jfield epoch_index))"

# The Mix wire shape: a decomposed proof that omits external_nullifier. The
# module derives it from the scope + the caller timestamp, verifies against
# that binding and echoes the derived value; the same stripped proof under a
# foreign rln_identifier must still read invalid.
TS_W=$(date +%s)
SIG_W=$(printf 'mix wire probe' | to_hex)
PROOF_W=$(prove "$M" "$MIX_ID" "$SIG_W" "$TS_W" W) || exit 1
EN_W=$(printf '%s' "$PROOF_W" | jfield external_nullifier)
[ -n "$EN_W" ] || die "generate_proof reply carries no external_nullifier to strip"
WIRE=$(printf '%s' "$PROOF_W" | python3 -c '
import json, sys
p = json.load(sys.stdin)
p.pop("external_nullifier", None)
json.dump(p, sys.stdout, separators=(",", ":"))')
OUT=$(rln validate_proof "$M" "$(argfile v_w "$MIX_ID")" "$(argfile vs_w "$SIG_W")" "str:$TS_W" "$(argfile vp_w "$WIRE")") || OUT=""
[ "$(printf '%s' "$OUT" | jfield verdict)" = valid ] || die "mix-shape proof did not validate on M: ${OUT:-<empty>}"
[ "$(printf '%s' "$OUT" | jfield external_nullifier)" = "$EN_W" ] \
    || die "mix-shape reply's derived external_nullifier != the issued one: $OUT"
V=$(verdict "$M" "$(printf 'aa%.0s' $(seq 1 32))" "$SIG_W" "$TS_W" "$WIRE" WF)
[ "$V" = invalid ] || die "mix-shape proof under a foreign rln_identifier read $V"
say "M: mix wire shape validates, derived external_nullifier echoed, foreign scope invalid"

# ---------- cross-registry ---------------------------------------------------
section "cross-registry"
# A current timestamp on both: the proof's carried epoch is an index in the
# other registry's epoch size, so the binding fails before any root check.
V=$(verdict "$M" "$RELAY_ID" "$SIG_D" "$(date +%s)" "$PROOF_D" DM)
[ "$V" = invalid ] || die "D's proof validated under M: $V"
V=$(verdict "$D" "$MIX_ID" "$SIG_M" "$(date +%s)" "$PROOF_M" MD)
[ "$V" = invalid ] || die "M's proof validated under D: $V"
say "a proof from one registry is invalid under the other"

# ---------- epochs are independent -------------------------------------------
section "epochs"
R_D=$(printf '%s' "$QUOTA_D" | jfield remaining)
R_M=$(printf '%s' "$QUOTA_M" | jfield remaining)
[ "$R_D" = "$(( RATE_LIMIT - 1 ))" ] || die "D quota after one proof: remaining $R_D (want $(( RATE_LIMIT - 1 ))): $QUOTA_D"
[ "$R_M" = "$(( M_RATE_LIMIT - 1 ))" ] || die "M quota after one proof: remaining $R_M (want $(( M_RATE_LIMIT - 1 ))): $QUOTA_M"
say "waiting $(( M_EPOCH + 2 ))s for M's epoch to roll…"
sleep $(( M_EPOCH + 2 ))
NOW=$(date +%s)
Q=$(rln get_epoch_quota "$M" "$(argfile q_m2 "$MIX_ID")" "str:$NOW")
[ "$(printf '%s' "$Q" | jfield remaining)" = "$M_RATE_LIMIT" ] \
    || die "M's quota did not reset after its epoch: $Q"
Q=$(rln get_epoch_quota "$D" "$(argfile q_d2 "$RELAY_ID")" "str:$NOW")
if [ "$(printf '%s' "$Q" | jfield epoch_index)" = "$(printf '%s' "$QUOTA_D" | jfield epoch_index)" ]; then
    [ "$(printf '%s' "$Q" | jfield remaining)" = "$(( RATE_LIMIT - 1 ))" ] \
        || die "D's quota moved inside its epoch: $Q"
    say "epochs: M reset to $M_RATE_LIMIT after ${M_EPOCH}s, D still $(( RATE_LIMIT - 1 )) in epoch $(printf '%s' "$Q" | jfield epoch_index)"
else
    say "epochs: M reset to $M_RATE_LIMIT; D's ${D_EPOCH}s epoch rolled meanwhile (not asserted)"
fi

# ---------- D's nullifiers survive M traffic (0.14.2 regression) --------------
section "nullifier log isolation"
# Every M validation above pruned the log at M's epoch index (~1.8e8); D's
# epoch (~3e6) sits far below it. A shared log forgets D here and re-reads
# the same proof as valid — a double-signal on the delivery registry would
# go undetected while mix traffic flows.
V=$(verdict "$D" "$RELAY_ID" "$SIG_D" "$TS_D" "$PROOF_D" D2)
[ "$V" = duplicate ] || die "re-validating D's proof after M traffic read '$V', not duplicate: M's pruning emptied D's nullifier log"
say "D's proof re-validated after M traffic: duplicate (D's log survived M's pruning)"

# ---------- a later start() naming only D (0.14.2 regression) -----------------
section "start merge"
# What a delivery node managing the backend sends: its registry, the
# instance default, nothing about M.
ONLY_D=$(rln start "{\"epoch_size_sec\":$D_EPOCH,\"registries\":[\"$D\"]}") || ONLY_D=""
case "$ONLY_D" in *'"started":true'*) ;; *) die "second start failed: ${ONLY_D:-<empty>}" ;; esac
[ "$(printf '%s' "$ONLY_D" | jpath overrides "$M" epoch_size_sec)" = "$M_EPOCH" ] \
    || die "a start naming only D dropped M's epoch: $ONLY_D"
PARAMS_M=$(rln get_registry_parameters "$M" "$(argfile p_m2 "$MIX_ID")") || PARAMS_M=""
[ "$(printf '%s' "$PARAMS_M" | jfield epoch_size_sec)" = "$M_EPOCH" ] \
    || die "after a start naming only D, M reports epoch $(printf '%s' "$PARAMS_M" | jfield epoch_size_sec): $PARAMS_M"
TS_M2=$(date +%s)
SIG_M2=$(printf 'mix after delivery restart' | to_hex)
PROOF_M2=$(prove "$M" "$MIX_ID" "$SIG_M2" "$TS_M2" M2) || exit 1
V=$(verdict "$M" "$MIX_ID" "$SIG_M2" "$TS_M2" "$PROOF_M2" M2)
[ "$V" = valid ] || die "an M proof after a start naming only D read $V"
say "a start naming only D leaves M at ${M_EPOCH}s; M still proves and validates"

# ---------- tampered ----------------------------------------------------------
section "tampered"
TAMPER=$(printf 'tampered signal' | to_hex)
V=$(verdict "$D" "$RELAY_ID" "$TAMPER" "$TS_D" "$PROOF_D" TD)
[ "$V" = invalid ] || die "tampered signal on D read $V"
V=$(verdict "$M" "$MIX_ID" "$TAMPER" "$TS_M2" "$PROOF_M2" TM)
[ "$V" = invalid ] || die "tampered signal on M read $V"
say "tampered signal invalid on both"

echo
echo "e2e: PASS — two registries on one module (target $E2E_TARGET)"
echo "e2e:   D $D leaf $(gv LEAF d) (${D_EPOCH}s)"
echo "e2e:   M $M leaf $(gv LEAF m) (${M_EPOCH}s / gap $M_GAP)"
echo "e2e:   paid by $PAYER"
