# RLN module integration notes for logos-delivery

The contract obligations a consumer of `liblogos_rln_module` (wire 0.6.0)
takes on, written down from what this repo's acceptance scenarios actually
enforce. Every claim here is pinned by a runnable probe — file references
point at the scenario that proves it.

## Quickstart

Clone the three inputs (or substitute your own working trees — any
checkout path works, the branches below are the known-good stack):

```sh
git clone -b rln/integration-fixes --recurse-submodules \
    https://github.com/adklempner/logos-delivery.git
git clone -b rln/integration-fixes \
    https://github.com/adklempner/logos-delivery-module.git
git clone -b feat/lip-alignment \
    https://github.com/logos-co/logos-rln-modules.git
```

**Hosted testnet** — no chain to build, registration lands on the real
sequencer (fastest first run):

```sh
RLN_MODULES_CHECKOUT=$PWD/logos-rln-modules \
LOGOS_DELIVERY_CHECKOUT=$PWD/logos-delivery \
DELIVERY_MODULE_CHECKOUT=$PWD/logos-delivery-module \
E2E_DEPLOYMENT=testnet-shrink-verify ./run.sh delivery-rln --target testnet
```

**Local chain** — additionally needs a logos-lez-rln checkout able to run
`dev.sh` (sequencer + provisioning; first provision takes ~6 min):

```sh
RLN_MODULES_CHECKOUT=$PWD/logos-rln-modules \
LOGOS_DELIVERY_CHECKOUT=$PWD/logos-delivery \
DELIVERY_MODULE_CHECKOUT=$PWD/logos-delivery-module \
./run.sh delivery-rln --target local
RLN_MODULES_CHECKOUT=$PWD/logos-rln-modules ./run.sh keystore --target local
```

Missing knobs fail at second zero with the fix named (run.sh preflight),
not minutes into a chain bring-up. The first delivery build from source is
long (~10 min); later runs hit the nix cache.

(`delivery-rln` drives your `impl-plugable-rln-api-module` branch — plus the
`rln/integration-fixes` patch stack on both delivery repos — end to end:
bring-up via the real config surface, registration to active, a proof-gated
send validated on a second node, and a negative control proving a tampered
message is NOT delivered. `keystore` pins the custody and lifecycle
behaviors below. `nim-rln-consumer/README.md` carries the numbered findings
list this doc consolidates.)

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
- **Timeouts are now per-op** (your 95e7e3c7, matching the module's
  documented budgets): 95 s for the registry-read ops (`register`,
  `get_membership_state`, `generate_proof`), 10 s for the local rest.
  A dropped late response still self-heals: registration continues
  module-side, and your next start's re-register returns the existing
  membership (idempotent per scope, `pending`/`active`/`grace_period`
  never double-mint; probe G proves it across a real restart).
- **`erased` can hit an active membership at any time.** Recovery from any
  terminal state (`failed`, `expired`, `erased`) is just calling
  `register` again.
- A membership the module has quarantined (local tamper) reads
  `state:"unknown"` from `get_membership_state` — same recovery: register
  fresh. The forensic verdict (`failed` + `metadata_tamper`) is on
  `get_memberships` (probe H).

## 3. The wire, post-0.6.0

- **`validate_proof` is the name** — the LIP and the module agree, and
  your 95e7e3c7 carries the rename natively now (the stack's rename
  commit retired). The delivery-module shim follows — since its
  `bcdc8348` the *event* is `rlnValidateProofRequest` too, one name
  end to end.
- **Verdict spelling is the module wire, lowercase snake_case** —
  `valid` / `invalid` / `duplicate` / `rate_limit_violation`, crossing
  verbatim (your 95e7e3c7 parses the module's native replies; the
  UPPERCASE parser is history) and asserted live by the send leg.
  `rate_limit_violation` + `recovered_secret` need a dishonest prover and
  are deliberately out of e2e scope — the wire is pinned by the module's
  own unit test (`validate_proof` rate-limit-violation secret recovery).
- **The ok/err envelope is retired** — your library now parses the
  module's own wire dialects and the responder forwards replies VERBATIM:
  the LogosResult envelope for `start`/`stop`/`get_epoch_quota`/
  `generate_proof`/`validate_proof`, the compact tstr reply (in-band
  `{"error":{"class":…}}`) for `register`/`get_membership_state`. Error
  `class` is lowercase; **`permanent` means never retry** (epoch below
  the persisted floor, epoch-size mismatch — re-register to recover).
- **Your `RegistryOptions` array is the module wire verbatim** — with the
  stack's register retype (your 95e7e3c7's positional `rate_limit` +
  flat options object was the module's 0.5 wire): the module's 0.6
  `register()` takes the key/value-pair ARRAY with `rate_limit` as a
  key, the same shape as your own `RlnInterface`. The LIP (#376) is the
  single schema authority.
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
   `rln-relay-user-message-limit` / `rln-relay-registry-options` in
   `createNode`'s flat conf; the env fork is retired and the acceptance
   drives these keys directly.
2. **RESOLVED (your 95e7e3c7): `start` carries the module's start
   config** — `{"epoch_size_sec", "registries"}` built from the node's
   own conf, so responders no longer need the scope out of band. The
   acceptance asserts the event's config carries the configured epoch and
   registry.
3. **RESOLVED: funding rides the conf** — `rln-relay-registry-options`
   (flat JSON object) feeds registry-specific pairs into the register
   options array; the acceptance passes `funding_holding_account_id`
   this way and asserts it crosses — the responder injects nothing.

## 7. Answering the seam: in-process bridge, or an external responder

The simplest production shape needs no responder at all: delivery-module's
`rlnBridgeAttach` (or the `rln-in-process` config key — same bridge) serves
the seam in-process — every op invokes the co-resident RLN module over lp
and the reply crosses back verbatim (two internal lanes keep a ~70s
register from blocking validate on the relay hot path). The acceptance
runs n1 this way.

For an external responder (n2's topology): forward the module's reply
VERBATIM — a responder is a router, not a translator.
`scenarios/delivery-rln/run.sh` is the reference: it routes each
`rln*Request` to `liblogos_rln_module` and hands the raw reply to
`rlnRespond`, and it greps your library's own log lines to prove the
responses landed inside the per-op budgets.
