# RLN module integration notes for logos-delivery

The contract obligations a consumer of `liblogos_rln_module` (wire 0.6.0)
takes on, written down from what this repo's acceptance scenarios actually
enforce. Every claim here is pinned by a runnable probe — file references
point at the scenario that proves it. Run them against your branch with:

```sh
RLN_MODULES_CHECKOUT=<logos-rln-modules> \
LOGOS_DELIVERY_CHECKOUT=<logos-delivery @ rln/integration-fixes> \
DELIVERY_MODULE_CHECKOUT=<logos-delivery-module @ rln/integration-fixes> \
E2E_EPOCH_SIZE_SEC=1800 ./run.sh delivery-rln --target local
RLN_MODULES_CHECKOUT=<...> E2E_EPOCH_SIZE_SEC=1800 ./run.sh keystore --target local
```

(`delivery-rln` drives your `impl-plugable-rln-api-module` branch — plus the
`rln/integration-fixes` patch stack on both delivery repos — end to end:
bring-up via the real config surface, registration to active, and a
proof-gated send validated on a second node. `keystore` pins the custody
and lifecycle behaviors below. `nim-rln-consumer/README.md` carries the
numbered findings list this doc consolidates.)

## 1. The keystore needs nothing from you

The module owns its keystore password by default. At init it resumes or
self-provisions its own random secret (`rln_autounlock.secret`, 0600, in
its host-stamped persistence dir), so **a headless integration makes zero
unlock calls, ever** — first start self-provisions, every restart resumes
(`scenarios/keystore/run.sh`, probe I). Notes:

- One store per module instance: the module holds an exclusive lock on its
  persistence dir for its lifetime. A second instance on the same dir gets
  a clean, attributable refusal on every keystore op and the module stays
  up (probe F). Give every node its own instance/persistence dir.
- `LOGOS_RLN_DISABLE_AUTO_UNLOCK=1` opts a deployment into user-password
  custody (`unlock_keystore`). Even then your register-on-every-start
  survives a locked store: a LIVE-scope re-register short-circuits to the
  existing membership without needing the password (probe D); only a
  fresh-scope registration and proof generation fail `locked`.
- Honest trade: the self-owned secret file reduces at-rest confidentiality
  to filesystem ACLs. The counter ledger's authentication — what actually
  protects against slot reuse — is unaffected.

## 2. Registration is async and durable — consume it that way

Your `start_node` currently logs the register reply and drops it. The
obligations (`scenarios/consumer-register/run.sh`, `scenarios/keystore/run.sh`
probes D/G):

- **`pending` is not success.** It can flip to `failed` (with a
  `retryable` flag) moments later. Activation arrives via
  `get_membership_state` polling or the `membership_state_changed` event —
  your own docs/rln.md's async model; the consuming half is what's missing.
- **The 10s `rlnInvoke` timeout is fine as-is** — `register` returns
  `pending` fast, and a dropped late response self-heals: registration
  continues module-side, and your next start's re-register returns the
  existing membership (idempotent per scope, `pending`/`active`/
  `grace_period` never double-mint; probe G proves it across a real
  restart).
- **`erased` can hit an active membership at any time.** Recovery from any
  terminal state (`failed`, `expired`, `erased`) is just calling
  `register` again.
- A membership the module has quarantined (local tamper) reads
  `state:"unknown"` from `get_membership_state` — same recovery: register
  fresh. The forensic verdict (`failed` + `metadata_tamper`) is on
  `get_memberships` (probe H).

## 3. The wire, post-0.6.0

- **`validate_proof` is the name** — the LIP and the module agree; your
  seam's `verify_proof` was the last outlier. The rename is carried by the
  `rln/integration-fixes` stack (callback typedef, struct field, nim
  wrapper, plus the delivery-module shim's initializer) — the shim's
  *event* names stay `rlnVerifyProofRequest`.
- **Verdict spelling is the module wire, lowercase snake_case** —
  `valid` / `invalid` / `duplicate` / `rate_limit_violation`, crossing
  verbatim inside `ok` (a responder passes the module reply through
  untouched). Your original parser matched `"VALID"` etc. — spelling that
  matches neither the wire nor the LIP's serialization of its `PROOF_*`
  constants — so every real validation fell through to "unknown verdict"
  → Reject. Fixed in the stack; the spelling is now also pinned in your
  delivery-module `docs/rln.md` and asserted live by the send leg.
- **Your `RegistryOptions` array is the module wire verbatim** — a
  responder passes `options_json` straight through, no adaptation. The
  LIP (#376) is the single schema authority.
- Verdicts are `ok` values, never `err`. The four error kinds map onto
  your `NOT_READY | TRANSIENT | BUDGET_EXHAUSTED | PERMANENT` (envelope
  kinds are UPPER_SNAKE; only they are); **`permanent` means never
  retry** (epoch below the persisted floor, epoch-size mismatch —
  re-register to recover).
- **The message wire carries ONE opaque proof field**: `generate_proof`
  replies include `proof_canonical` (wire 0.6.1) — the full 289-byte
  canonical zerokit serialization as hex. Ship exactly those bytes as
  `message.proof`; a validator hands them back whole as
  `{"proof": "<hex>"}` and the module recovers every public value from
  the blob. No consumer ever assembles or parses proof bytes. (The
  decomposed reply fields remain the LIP shape for consumers that carry
  fields instead.)

## 4. Rate limiting: timestamps, epochs, slots, quota

- **One timestamp rule**: pass the SAME Unix-seconds value to
  `generate_proof` and `validate_proof` for a given message. Your message
  timestamps are nanoseconds — divide by 1e9 consistently; decide once
  whether that value is send-time-now or the message's own stamp, and use
  it on both sides. The proof's epoch derives from the caller timestamp,
  never the module clock.
- **Epoch size is an application constant** all provers and validators
  share; it rides `start()` (per-registry overrides supported). Size it
  well above your worst-case queue/retry latency — a 1s epoch guarantees
  mismatches; your simulator's 120s is a sane floor.
- **Every `generate_proof` spends a slot, and slots are never reissued** —
  a regenerate-on-retry path pays again (two calls for one signal consume
  two slots; keystore probe B). Budget accordingly and retire any
  node-side nonce accounting: the module owns message-id allocation.
- **Quota conventions** (`get_epoch_quota`, probe C): `rate_limit:0` means
  "no usable membership on this registry" — an answer, not an error. An
  unknown `rln_identifier` on a registry that HAS a membership falls back
  to it and gets its own independent slot budget (one membership backs
  many applications).

## 5. Validator path

- **Errors are the absence of a verdict, never evidence of spam.** Your
  validator mapped every failure — module not started, 10s timeout,
  unparseable reply — to gossipsub `Reject`, scoring healthy peers down;
  and since the validator mounts at node create while the module starts
  in `startNode`, every boot had a guaranteed all-Reject window. The
  stack maps errors to `Ignore` (dropped, unscored); `Reject` stays
  reserved for real verdicts and sender violations (negative timestamp,
  missing proof).
- A **freshly-activated membership's proof can validate `invalid` — not
  `not_ready` — until its just-published root reaches the validator's
  window**. The module softens this: a warm-window root miss triggers a
  rate-limited on-demand window refresh in the background, so the race
  typically resolves on the next retry (~a provider round-trip) instead of
  a full refresh interval (~10s). You still own the one retry: for a
  just-activated registrant, treat a first `invalid` as retryable before
  scoring spam (`scenarios/register/run.sh` polls exactly this away).
- **A validator's module needs a live registry provider.** The root window
  is fed by registry reads (in our stack: lez_core with an OPEN wallet on
  that node); without one the window stays permanently cold and every
  `validate_proof` answers `not_ready` — which your validator now Ignores,
  so the symptom is "no RLN-gated message ever arrives", not peer damage.
  Whoever hosts the RLN module on a validator node owns bringing up its
  provider stack (the delivery-rln scenario's wallet section shows the
  shape).
- **Double-signal detection is the module's job now** (spec change):
  `validate_proof` owns the nullifier log and returns `duplicate` /
  `rate_limit_violation` — your gossipsub validator should stop keeping
  its own log. `rate_limit_violation` carries the offender's recovered
  secret: what the node does with that slashing evidence is a policy
  decision on your side.

## 6. Config ownership — decisions we need from you

Your branch surfaced these; our stopgaps are marked:

1. **Bring-up scope — ANSWERED at a48f8b8a**: `rln-relay-lez` /
   `rln-relay-registry-id` / `rln-relay-identifier` /
   `rln-relay-user-message-limit` in `createNode`'s flat conf; the env
   fork is retired and the acceptance drives these keys directly. Loose
   ends: options collapsed to just `rate_limit` (= userMessageLimit), and
   `epochSizeSec`/`creds` are carried into `WakuRlnLezConfig` but never
   read on the LEZ path — either wire `rln-relay-epoch-sec` into
   `start()` scope (see 2) or drop the fields.
2. **`start` carries no scope**, so every responder must know registry +
   epoch size out of band (two responders currently guess separately).
   Recommendation: the party that calls `logosdelivery_rln_set_callbacks`
   owns `start()` config, sourced from the same node-conf section, using
   the module's per-registry `epoch_size_sec`/`max_epoch_gap` overrides.
3. **No options key carries funding** — our responder injects
   `funding_holding_account_id` itself. Who pays for a registration is an
   open design question; the module passes the key through today.

## 7. Responder contract (for whoever answers the events)

Reply envelope: `{"ok": <module reply>}` or
`{"err":{"kind":…,"message":…}}` with the four kinds above — enforced by
`scenarios/delivery-rln/run.sh:196-200`, which also greps your library's
own log lines to prove the responses landed inside the 10s windows.
