#!/usr/bin/env bash
# scenarios/keystore — the keystore-lifecycle acceptance for the delivery
# integration. logos-delivery's seam has NO unlock op, fires register on
# EVERY node start under a hard call budget, and treats failures as
# best-effort — so the behaviors a foreign caller silently depends on are
# exactly the ones no other scenario exercises. After one faucet-paid
# registration this pins, in order:
#
#   A  fresh-scope proof spends message_id 0
#   B  a second generate_proof for the SAME signal+timestamp spends a NEW
#      slot (message_id 1) — regeneration is never free; quota drops by 2
#   C  get_epoch_quota for an absent membership answers rate_limit:0 —
#      delivery's "no usable membership" convention, not an error
#   D  locked-store surface: generate_proof and a FRESH-scope register fail
#      "locked"; a LIVE-scope re-register short-circuits and returns the
#      existing membership (delivery's register-on-every-start survives a
#      locked store); reads keep working; a wrong password is bad_password
#      (the store has a credential, so TOFU adoption is over)
#   E  the exclusive keystore lock is genuinely HELD while the daemon runs
#      and released on exit (probed with flock against rln_keystore.lock)
#   F  a foreign lock holder at open time yields a clean, attributable
#      refusal on every keystore op (store fails closed, module stays up)
#   G  restart persistence: after daemon_restart the census sees the
#      credential locked, the real (non-TOFU) verifier accepts only the
#      right password, re-register is idempotent (same membership_hash, no
#      second mint), and message_id CONTINUES from the persisted counters —
#      persist-before-issue across restarts, same epoch
#   H  quarantine surfaces on the wire: a tampered allocations section MAC
#      reads state:"failed" + failed_reason:"metadata_tamper" with retryable
#      suppressed, and the membership is unselectable for proofs
#
# All proofs use ONE captured timestamp (T0) so every slot lands in one
# epoch — message_id continuity is per (rln_identifier, epoch). Pick an
# E2E_EPOCH_SIZE_SEC comfortably larger than the run's restart phases.
#
# Env beyond docs/contract.md:
#   E2E_RATE_LIMIT=100   registration rate limit
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for _lib in compat json lgx daemon wallet chain; do
    # shellcheck source=/dev/null
    . "$ROOT/harness/lib/$_lib.sh"
done

RATE_LIMIT="${E2E_RATE_LIMIT:-100}"
NODE=n1
PASSWORD=e2e-test-password

for _v in LOGOSCORE E2E_MODULES_DIR E2E_SEQUENCER E2E_WALLET_HOME E2E_CONFIG_ACCOUNT \
          E2E_TREE_ID E2E_FUNDING E2E_CONFIRM_TIMEOUT_S E2E_POLL_INTERVAL_S \
          E2E_EPOCH_SIZE_SEC E2E_ROOT_WINDOW_TIMEOUT_S; do
    eval "[ -n \"\${$_v:-}\" ]" || die "contract env missing: $_v (see docs/contract.md)"
done
[ "$E2E_FUNDING" = "faucet" ] \
    || die "target provides funding=$E2E_FUNDING — this scenario needs the faucet-paid path"

polls() {
    local n=$(( $1 / $2 ))
    [ "$n" -ge 1 ] || n=1
    printf '%s' "$n"
}

NODE_UP=0
HOLDER_PID=""
cleanup() {
    [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "E2E_KEEP=1: leaving node $NODE up, state in $E2E_RUN_DIR"
        return
    fi
    [ "$NODE_UP" = 1 ] && daemon_stop "$NODE"
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
say "registry: $REGISTRY_ID"

# 0 = the lock file is held by another process; 1 = acquirable. Rust's
# File::try_lock is flock on darwin/linux, so this probes the same lock.
lock_busy() {
    python3 - "$1" <<'EOF'
import fcntl, sys
f = open(sys.argv[1], "r+")
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
sys.exit(1)
EOF
}

# start() + one warmed root window; the session config dies with the daemon,
# so every restart re-runs this.
module_start() {
    local out
    out=$(node_call "$NODE" liblogos_rln_module start \
        "{\"epoch_size_sec\":$E2E_EPOCH_SIZE_SEC,\"registries\":[\"$REGISTRY_ID\"]}" | jres | jval) || out=""
    case "$out" in
        *'"started":true'*) ;;
        *) die "start failed: ${out:-<empty>}" ;;
    esac
}

# generate_proof at the FIXED T0; prints the reply JSON (empty on failure).
gen_proof() { # <argtag>
    node_call "$NODE" liblogos_rln_module generate_proof \
        "$REGISTRY_ID" "$(argfile "rid$1" "$RLN_ID")" "$(argfile "sig$1" "$SIGNAL_HEX")" \
        "str:$T0" | jres | jval
}

# ---------- bring-up + the one paid registration ------------------------------
section "setup: node, wallet, funding"
daemon_start "$NODE" || die "daemon_start failed"
NODE_UP=1
daemon_load_modules "$NODE" lez_core liblogos_lez_rln_module liblogos_rln_module \
    || die "load-module failed"
wallet_open "$NODE" || die "wallet open failed"
chain_head >/dev/null || die "cannot probe chain head at $E2E_SEQUENCER"
wallet_sync "$NODE" >/dev/null || die "wallet sync failed"
HOLDING=$(wallet_fresh_holding "$NODE") || HOLDING=""
[ -n "$HOLDING" ] || die "no unused holding account"
BOUNDS=$(node_call "$NODE" liblogos_lez_rln_module get_registry_bounds \
    "$(argfile cfg "$E2E_CONFIG_ACCOUNT")" | jres) || BOUNDS=""
PRICE=$(printf '%s' "$BOUNDS" | jfield price_per_unit)
[ -n "$PRICE" ] || die "no price_per_unit in bounds: ${BOUNDS:-<empty>}"
CLAIM=$(( RATE_LIMIT * PRICE * 2 ))
say "claiming $CLAIM RLNTOK"
node_call "$NODE" liblogos_lez_rln_module claim_tokens \
    "$(argfile cfg2 "$E2E_CONFIG_ACCOUNT")" "$(argfile hold "$HOLDING")" "$CLAIM" | jres >/dev/null \
    || die "claim_tokens failed"
wait_balance "$NODE" "$HOLDING" "$CLAIM" >/dev/null || die "faucet credit never landed"

RLN_ID=$(openssl rand -hex 32)
section "setup: register + activate"
UNLOCK=$(node_call "$NODE" liblogos_rln_module unlock_keystore "$PASSWORD" | jres) || UNLOCK=""
case "$UNLOCK" in *'"unlocked":true'*) ;; *) die "unlock failed: ${UNLOCK:-<empty>}" ;; esac
OPTIONS_JSON="[{\"key\":\"rate_limit\",\"value\":\"$RATE_LIMIT\"},{\"key\":\"funding_holding_account_id\",\"value\":\"$HOLDING\"}]"
REG=$(node_call "$NODE" liblogos_rln_module register \
    "$REGISTRY_ID" "$(argfile rlnid "$RLN_ID")" "$OPTIONS_JSON" | jres) || REG=""
case "$REG" in *'"state":"pending"'*) ;; *) die "register failed: ${REG:-<empty>}" ;; esac
MEMBERSHIP_HASH=$(printf '%s' "$REG" | jfield membership_hash)
say "pending membership: $MEMBERSHIP_HASH"
STATE=""
for _t in $(seq 1 "$(polls "$E2E_CONFIRM_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    STATE=$(node_call "$NODE" liblogos_rln_module get_membership_state \
        "$REGISTRY_ID" "$(argfile rlnid1 "$RLN_ID")" | jres | jfield state)
    case "$STATE" in active|grace_period) break ;; failed) die "registration FAILED" ;; esac
    sleep "$E2E_POLL_INTERVAL_S"
done
case "$STATE" in active|grace_period) say "ACTIVE" ;; *) die "never became active (last: ${STATE:-<none>})" ;; esac
module_start

# One epoch for the whole scenario: T0 is captured once and reused, so slot
# continuity across restarts is observable (allocation is per
# (rln_identifier, epoch)). max_epoch_gap defaults to 1 epoch, so T0 stays
# in-window for ~E2E_EPOCH_SIZE_SEC — size it generously.
T0=$(date +%s)
SIGNAL_HEX=$(printf 'keystore probe signal' | to_hex)

# ---------- A: fresh scope spends message_id 0 --------------------------------
section "A: first proof = slot 0"
P1=$(gen_proof a) || P1=""
case "$P1" in *'"proof"'*) ;; *) die "generate_proof #1 failed: ${P1:-<empty>}" ;; esac
M1=$(printf '%s' "$P1" | jfield message_id)
E1=$(printf '%s' "$P1" | jfield epoch_index)
[ "$M1" = "0" ] || die "first proof spent message_id $M1, want 0"
say "message_id 0 in epoch $E1"

# ---------- B: regeneration costs a slot --------------------------------------
section "B: same signal+timestamp again = slot 1 (never free, never reissued)"
P2=$(gen_proof b) || P2=""
case "$P2" in *'"proof"'*) ;; *) die "generate_proof #2 failed: ${P2:-<empty>}" ;; esac
M2=$(printf '%s' "$P2" | jfield message_id)
[ "$M2" = "1" ] || die "second proof spent message_id $M2, want 1 — identical inputs must NEVER share a slot"
QUOTA=$(node_call "$NODE" liblogos_rln_module get_epoch_quota \
    "$REGISTRY_ID" "$(argfile ridq "$RLN_ID")" "str:$T0" | jres | jval) || QUOTA=""
REMAINING=$(printf '%s' "$QUOTA" | jfield remaining)
[ "$REMAINING" = "$((RATE_LIMIT - 2))" ] \
    || die "quota remaining $REMAINING != $((RATE_LIMIT - 2)) after two proofs (quota: ${QUOTA:-<empty>})"
say "two proofs, two slots: remaining $REMAINING/$RATE_LIMIT"

# ---------- C: quota scoping — fallback vs truly absent -----------------------
# Two deliberate semantics a foreign caller must know apart:
#   C1 an UNKNOWN rln_identifier on a registry that HAS a membership falls
#      back to it (one membership backs many applications; each identifier
#      keys its own slot budget) — full quota, untouched by other scopes'
#      spends;
#   C2 a registry with NO membership answers rate_limit:0 — delivery's
#      "no usable membership" convention, an answer, not an error.
section "C: quota scoping (fallback vs rate_limit:0)"
GHOST_ID=$(openssl rand -hex 32)
GQ=$(node_call "$NODE" liblogos_rln_module get_epoch_quota \
    "$REGISTRY_ID" "$(argfile ghost "$GHOST_ID")" "str:$T0" | jres | jval) || GQ=""
case "$GQ" in
    *'"rate_limit":'$RATE_LIMIT*'"remaining":'$RATE_LIMIT*|*'"remaining":'$RATE_LIMIT*'"rate_limit":'$RATE_LIMIT*)
        say "unknown identifier falls back to the registry's membership with its OWN untouched budget ($RATE_LIMIT/$RATE_LIMIT)" ;;
    *) die "fallback-scope quota should be the full $RATE_LIMIT/$RATE_LIMIT, got: ${GQ:-<empty>}" ;;
esac
GHOST_REGISTRY="logos:${E2E_TARGET}:$(openssl rand -hex 32)"
GQ2=$(node_call "$NODE" liblogos_rln_module get_epoch_quota \
    "$GHOST_REGISTRY" "$(argfile ghost2 "$GHOST_ID")" "str:$T0" | jres | jval) || GQ2=""
case "$GQ2" in
    *'"rate_limit":0'*) say "membership-less registry answers rate_limit:0 — delivery's no-usable-membership convention" ;;
    *) die "membership-less registry quota should be rate_limit:0, got: ${GQ2:-<empty>}" ;;
esac

# ---------- D: locked-store surfaces ------------------------------------------
section "D: locked store"
LOCKED=$(node_call "$NODE" liblogos_rln_module lock_keystore | jres) || LOCKED=""
case "$LOCKED" in *'"locked":true'*) ;; *) die "lock_keystore failed: ${LOCKED:-<empty>}" ;; esac
DP=$(gen_proof d) || DP=""
case "$DP" in
    *locked*) say "generate_proof while locked: clean 'locked'" ;;
    *) die "generate_proof on a locked store must fail 'locked', got: ${DP:-<empty>}" ;;
esac
FRESH_ID=$(openssl rand -hex 32)
FREG=$(node_call "$NODE" liblogos_rln_module register \
    "$REGISTRY_ID" "$(argfile fresh "$FRESH_ID")" "[{\"key\":\"rate_limit\",\"value\":\"$RATE_LIMIT\"}]" | jres) || FREG=""
case "$FREG" in
    *locked*) say "fresh-scope register while locked: clean 'locked' (no mint)" ;;
    *) die "fresh-scope register on a locked store must fail 'locked', got: ${FREG:-<empty>}" ;;
esac
RREG=$(node_call "$NODE" liblogos_rln_module register \
    "$REGISTRY_ID" "$(argfile rereg "$RLN_ID")" "$OPTIONS_JSON" | jres) || RREG=""
case "$RREG" in
    *"$MEMBERSHIP_HASH"*) say "LIVE-scope re-register while locked short-circuits to the existing membership — delivery's register-on-every-start survives a locked store" ;;
    *) die "locked re-register should return the existing membership, got: ${RREG:-<empty>}" ;;
esac
LIST=$(node_call "$NODE" liblogos_rln_module get_memberships "$REGISTRY_ID" | jres) || LIST=""
case "$LIST" in *"$MEMBERSHIP_HASH"*) say "reads keep working locked" ;; *) die "get_memberships broke while locked: ${LIST:-<empty>}" ;; esac
WRONG=$(node_call "$NODE" liblogos_rln_module unlock_keystore not-the-password | jres) || WRONG=""
case "$WRONG" in
    *bad_password*) say "wrong password: bad_password (TOFU is over — the verifier is live)" ;;
    *) die "wrong password on a non-empty store must be bad_password, got: ${WRONG:-<empty>}" ;;
esac
UNLOCK=$(node_call "$NODE" liblogos_rln_module unlock_keystore "$PASSWORD" | jres) || UNLOCK=""
case "$UNLOCK" in *'"unlocked":true'*) ;; *) die "re-unlock failed: ${UNLOCK:-<empty>}" ;; esac

# ---------- E: the directory lock is real -------------------------------------
section "E: keystore lock held while up, released on exit"
LOCK_FILE=$(ls "$E2E_RUN_DIR"/nodes/$NODE/config/*/liblogos_rln_module/*/rln_keystore.lock \
    "$E2E_RUN_DIR"/nodes/$NODE/config/*/*/liblogos_rln_module/*/rln_keystore.lock 2>/dev/null | head -1)
[ -n "$LOCK_FILE" ] || die "rln_keystore.lock not found under nodes/$NODE/config"
say "lock file: ${LOCK_FILE#"$E2E_RUN_DIR"/}"
lock_busy "$LOCK_FILE" || die "the keystore lock is NOT held while the daemon runs"
say "held while the daemon runs"
daemon_stop_wait "$NODE"
NODE_UP=0
lock_busy "$LOCK_FILE" && die "the keystore lock is still held after daemon exit"
say "released on exit"

# ---------- F: a foreign holder at open time ----------------------------------
section "F: contended open fails closed, module stays up"
python3 - "$LOCK_FILE" <<'EOF' &
import fcntl, sys, time
f = open(sys.argv[1], "r+")
fcntl.flock(f, fcntl.LOCK_EX)
time.sleep(600)
EOF
HOLDER_PID=$!
sleep 1
daemon_start "$NODE" || die "daemon_start under contention failed"
NODE_UP=1
daemon_load_modules "$NODE" lez_core liblogos_lez_rln_module liblogos_rln_module \
    || die "load-module under contention failed"
CU=$(node_call "$NODE" liblogos_rln_module unlock_keystore "$PASSWORD" | jres) || CU=""
case "$CU" in
    *'keystore lock'*|*'another process'*|*'not initialized'*)
        say "keystore op refused cleanly while the lock is foreign-held: $(printf '%s' "$CU" | head -c 160)" ;;
    *'"unlocked":true'*) die "unlock SUCCEEDED under a foreign lock holder — the exclusive lock is not exclusive" ;;
    *) die "expected a clean lock refusal, got: ${CU:-<empty>}" ;;
esac
LIST=$(node_call "$NODE" liblogos_rln_module get_memberships "$REGISTRY_ID" | jres) || LIST=""
case "$LIST" in
    *error*) say "reads also refuse (store never opened) — fail-closed, module alive" ;;
    *"$MEMBERSHIP_HASH"*) say "reads served without the store lock (cache path) — module alive" ;;
    *) die "module went dark under lock contention: ${LIST:-<empty>}" ;;
esac
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""

# ---------- G: restart persistence --------------------------------------------
section "G: restart — verifier, idempotent re-register, slot continuity"
daemon_restart "$NODE" || die "daemon_restart failed"
daemon_load_modules "$NODE" lez_core liblogos_lez_rln_module liblogos_rln_module \
    || die "load-module after restart failed"
# The wallet is per-process state: the registry overlay (get_membership_state)
# and proof generation both need it re-opened and re-synced after a restart.
wallet_open "$NODE" || die "wallet re-open after restart failed"
wallet_sync "$NODE" >/dev/null || die "wallet re-sync after restart failed"
LIST=$(node_call "$NODE" liblogos_rln_module get_memberships "$REGISTRY_ID" | jres) || LIST=""
case "$LIST" in *"$MEMBERSHIP_HASH"*) say "census sees the credential (locked, no password)" ;; \
    *) die "membership lost across restart: ${LIST:-<empty>}" ;; esac
WRONG=$(node_call "$NODE" liblogos_rln_module unlock_keystore not-the-password | jres) || WRONG=""
case "$WRONG" in *bad_password*) say "restart unlock is the REAL verifier: wrong password refused" ;; \
    *) die "wrong password after restart must be bad_password, got: ${WRONG:-<empty>}" ;; esac
UNLOCK=$(node_call "$NODE" liblogos_rln_module unlock_keystore "$PASSWORD" | jres) || UNLOCK=""
case "$UNLOCK" in *'"unlocked":true'*) say "correct password unlocks" ;; \
    *) die "unlock after restart failed: ${UNLOCK:-<empty>}" ;; esac
SJSON=$(node_call "$NODE" liblogos_rln_module get_membership_state \
    "$REGISTRY_ID" "$(argfile rlnid2 "$RLN_ID")" | jres) || SJSON=""
STATE=$(printf '%s' "$SJSON" | jfield state)
case "$STATE" in active|grace_period) ;; \
    *) die "membership state after restart: ${STATE:-<none>} (reply: ${SJSON:-<empty>})" ;; esac
RREG=$(node_call "$NODE" liblogos_rln_module register \
    "$REGISTRY_ID" "$(argfile rereg2 "$RLN_ID")" "$OPTIONS_JSON" | jres) || RREG=""
case "$RREG" in
    *"$MEMBERSHIP_HASH"*) say "re-register after restart is idempotent (same membership, no second mint)" ;;
    *) die "post-restart re-register was not idempotent: ${RREG:-<empty>}" ;;
esac
module_start
P3=$(gen_proof g) || P3=""
case "$P3" in *'"proof"'*) ;; *) die "generate_proof after restart failed: ${P3:-<empty>}" ;; esac
M3=$(printf '%s' "$P3" | jfield message_id)
E3=$(printf '%s' "$P3" | jfield epoch_index)
[ "$E3" = "$E1" ] || die "epoch rolled during the run (proof epochs $E1 -> $E3) — raise E2E_EPOCH_SIZE_SEC for this target"
[ "$M3" = "2" ] || die "post-restart proof spent message_id $M3, want 2 — the persisted counters did not survive the restart"
say "message_id continues at 2: persist-before-issue holds across restarts"
say "validating the post-restart proof (polling the root window warm)…"
VALID=""
for _t in $(seq 1 "$(polls "$E2E_ROOT_WINDOW_TIMEOUT_S" "$E2E_POLL_INTERVAL_S")"); do
    V=$(node_call "$NODE" liblogos_rln_module validate_proof \
        "$REGISTRY_ID" "$(argfile rlnid3 "$RLN_ID")" "$(argfile sigv "$SIGNAL_HEX")" \
        "str:$T0" "$(argfile proofv "$P3")" | jres | jval) || V=""
    case "$V" in
        *'"verdict":"valid"'*) VALID=yes; break ;;
        *not_ready*) sleep "$E2E_POLL_INTERVAL_S" ;;
        *) die "validate_proof after restart: ${V:-<empty>}" ;;
    esac
done
[ "$VALID" = "yes" ] || die "validate_proof never left not_ready after restart"
say "post-restart proof validates"

# ---------- H: quarantine surfaces on the wire --------------------------------
section "H: tampered section MAC -> failed/metadata_tamper, unselectable"
daemon_stop_wait "$NODE"
NODE_UP=0
ALLOC_FILE="${LOCK_FILE%rln_keystore.lock}rln_allocations.json"
[ -f "$ALLOC_FILE" ] || die "rln_allocations.json not found beside the lock file"
python3 - "$ALLOC_FILE" <<'EOF' || die "could not tamper the allocations section MAC"
import json, sys
p = sys.argv[1]
d = json.load(open(p))
secs = d.get("sections") or {}
if not secs:
    sys.exit("no sections to tamper")
sec = next(iter(secs.values()))
mac = sec["mac"]
sec["mac"] = ("0" if mac[0] != "0" else "1") + mac[1:]
json.dump(d, open(p, "w"))
EOF
daemon_start "$NODE" || die "daemon_start for the tamper probe failed"
NODE_UP=1
daemon_load_modules "$NODE" lez_core liblogos_lez_rln_module liblogos_rln_module \
    || die "load-module for the tamper probe failed"
wallet_open "$NODE" || die "wallet re-open for the tamper probe failed"
wallet_sync "$NODE" >/dev/null || die "wallet re-sync for the tamper probe failed"
UNLOCK=$(node_call "$NODE" liblogos_rln_module unlock_keystore "$PASSWORD" | jres) || UNLOCK=""
case "$UNLOCK" in *'"unlocked":true'*) say "unlock proceeds — the tampered entry is quarantined, not the store" ;; \
    *) die "unlock over a tampered section failed outright: ${UNLOCK:-<empty>}" ;; esac
module_start
# Two complementary wire surfaces, both deliberate:
#  - get_membership_state EXCLUDES quarantined records from candidacy, so the
#    scope reads "unknown" — the signal a caller acts on ("no live
#    membership; a fresh registration is the recovery path");
#  - get_memberships lists every record ANY-state, and there the quarantined
#    entry carries the forensic verdict: failed + metadata_tamper, with
#    retryable suppressed (a tamper verdict is never retriable).
QSTATE=$(node_call "$NODE" liblogos_rln_module get_membership_state \
    "$REGISTRY_ID" "$(argfile rlnid4 "$RLN_ID")" | jres) || QSTATE=""
case "$QSTATE" in
    *'"state":"unknown"'*)
        say "get_membership_state: unknown — quarantined records are no candidates (fresh registration is the recovery path)" ;;
    *) die "quarantined scope should read state unknown, got: ${QSTATE:-<empty>}" ;;
esac
QLIST=$(node_call "$NODE" liblogos_rln_module get_memberships "$REGISTRY_ID" | jres) || QLIST=""
case "$QLIST" in
    *'"state":"failed"'*metadata_tamper*|*metadata_tamper*'"state":"failed"'*)
        say "get_memberships carries the verdict: failed + metadata_tamper" ;;
    *) die "quarantined entry should list failed/metadata_tamper, got: ${QLIST:-<empty>}" ;;
esac
case "$QLIST" in
    *'"retryable"'*) die "a tamper verdict must never carry retryable: $QLIST" ;;
    *) say "retryable suppressed — a tamper verdict is never retriable" ;;
esac
QP=$(gen_proof h) || QP=""
case "$QP" in
    *no_usable_membership*) say "quarantined membership is unselectable for proofs" ;;
    *'"proof"'*) die "a proof was issued from QUARANTINED counters — slot reissue risk" ;;
    *) die "expected no_usable_membership for the quarantined scope, got: ${QP:-<empty>}" ;;
esac

echo
echo "e2e: PASS — keystore lifecycle acceptance"
echo "e2e:   membership   $MEMBERSHIP_HASH (quarantined at the end by design)"
echo "e2e:   slots spent  0,1 pre-restart; 2 post-restart (epoch $E1)"
echo "e2e:   lock file    ${LOCK_FILE#"$E2E_RUN_DIR"/}"
