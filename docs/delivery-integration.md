# RLN module integration notes for logos-delivery

logos-delivery implements no RLN itself: it outsources every RLN operation to
`liblogos_rln_module` across delivery-module's bridge, so the module owns the
credentials, epochs, slots and proofs while delivery owns the messages and the
gossipsub validator. This is what the delivery side of that split takes on
(module wire 0.7.x), written down from what this repo's acceptance scenarios
enforce; the references point at the scenario that proves each claim.

Each fact lives in one document only: **logos-lips #376** is the schema
authority, **`logos-rln-module/docs/wire-binding.md`** is how that schema
crosses the logos-core wire, logos-delivery-module's **`docs/rln.md`** is the
bridge's own operator contract (event names and arguments, `rlnRespond`,
in-process mode), and this doc is what a delivery integration must do with
them.

## Running the acceptance

`delivery-rln` drives the delivery stack end to end against the real RLN
module; `keystore` pins the custody and lifecycle behaviors in §1 and §2.
Point the checkout knobs at working trees — any path works, and
`scenarios/delivery-rln/run.sh`'s header names the branches it is pinned
against.

```sh
export RLN_MODULES_CHECKOUT=$PWD/logos-rln-modules \
       LOGOS_DELIVERY_CHECKOUT=$PWD/logos-delivery \
       DELIVERY_MODULE_CHECKOUT=$PWD/logos-delivery-module

# hosted testnet: nothing to build, registration lands on the real sequencer
E2E_DEPLOYMENT=testnet-shrink-verify ./run.sh delivery-rln --target testnet

# local chain: also needs a logos-lez-rln checkout that can run dev.sh
./run.sh delivery-rln --target local
./run.sh keystore --target local
```

Each assertion prints as it passes, so the transcript is the assertion list —
custody, config surface, registration to `active`, the `valid` verdict
reaching `messageReceived` on the second node, and the tampered-message
control, in the order the scenario header enumerates them. `$E2E_RUN_DIR`
keeps the logs, `responder-n2.log` the verdict trail.

## 1. The keystore needs nothing from the consumer

The module owns its keystore password: at init it resumes or self-provisions
its own random secret (`rln_autounlock.secret`, 0600, in its host-stamped
persistence dir), so **a headless integration makes zero unlock calls, ever**
(`scenarios/keystore/run.sh`, probe I). The deliberate trade is that at-rest
confidentiality falls back to filesystem ACLs; the counter ledger's
authentication, which protects against slot reuse, is untouched.

Give every node its own instance and persistence dir — the module locks that
dir exclusively, and a second instance on it is cleanly refused on every
keystore op while staying up (probe F). A deployment that wants user-password
custody sets `LOGOS_RLN_DISABLE_AUTO_UNLOCK=1` and calls `unlock_keystore`;
even then register-on-every-start survives a locked store, because a
live-scope re-register short-circuits to the existing membership without the
password (probe D).

## 2. Registration is async and durable

- **`pending` is not success.** It can flip to `failed` (with a `retryable`
  flag) moments later; activation arrives via `get_membership_state` polling
  or the `membership_state_changed` event.
- **A dropped late response self-heals.** Registration continues module-side
  and the next start's re-register returns the existing membership —
  idempotent per scope, never double-minting from `pending`, `active` or
  `grace_period` (probe G, across a real restart).
- **Recovery from any terminal state is one call.** `failed`, `expired` and
  `erased` — which can hit an active membership at any time — are answered by
  calling `register_membership` again, as is a membership quarantined for
  local tamper (`state:"unknown"`, with the forensic `metadata_tamper` verdict
  on `get_memberships`, probe H).

## 3. The wire

- **Registration takes an options array, never a positional rate.**
  `register_membership(registry_id, rln_identifier_hex, options_json)` takes
  the spec's `RegistryOptions`: a JSON array of `{"key","value"}` string
  pairs. `rate_limit` is the common key (decimal string, module-defaulted when
  absent); registry-specific keys ride the same array, and
  `funding_holding_account_id` names the holding that pays `rate_limit ×
  price_per_unit`.
- **`validate_proof` is the name end to end** — the LIP, the module method and
  the bridge event (`rlnValidateProofRequest`) agree.
- **Verdicts are lowercase snake_case and cross verbatim**: `valid`,
  `invalid`, `duplicate`, `rate_limit_violation`. The last one and its
  `recovered_secret` need a dishonest prover, so they sit outside e2e scope,
  pinned by the module's own unit test.
- **There is no extra envelope on the seam**, only the module's two native
  dialects: the LogosResult envelope for `start` / `stop` / `get_epoch_quota`
  / `generate_proof` / `validate_proof`, and the compact reply with an in-band
  `{"error":{"class":…}}` for `register_membership` / `get_membership_state`.
  Error `class` is lowercase, and **`permanent` means never retry** (epoch
  below the persisted floor, epoch-size mismatch — re-register to recover).
- **The message wire carries ONE opaque proof field.** `generate_proof`
  replies include `proof_canonical`, the 289-byte canonical zerokit
  serialization as hex: ship exactly those bytes as `message.proof`, and a
  validator hands them back whole as `{"proof":"<hex>"}` for the module to
  recover every public value from. No consumer assembles or parses proof
  bytes; the decomposed fields stay in the reply for consumers that carry
  fields instead.

## 4. Rate limiting: timestamps, epochs, slots, quota

- **One timestamp rule**: the SAME Unix-seconds value goes to
  `generate_proof` and `validate_proof` for a given message. Delivery's
  timestamps are nanoseconds — divide by 1e9, and decide once whether the
  value is send-time-now or the message's own stamp. The epoch derives from
  the caller timestamp, never the module clock.
- **Epoch size is an application constant** all provers and validators share;
  it rides `start()`, with per-registry overrides. Size it well above
  worst-case queue and retry latency — a 1 s epoch guarantees mismatches.
- **Every `generate_proof` spends a slot, and slots are never reissued** — a
  regenerate-on-retry path pays twice for one signal (probe B). Keep no
  node-side nonce accounting: the module owns message-id allocation.
- **`rate_limit:0` from `get_epoch_quota` is an answer, not an error** — no
  usable membership on this registry (probe C). An unknown `rln_identifier` on
  a registry that HAS a membership falls back to it with its own independent
  budget: one membership backs many applications.

## 5. Validator path

- **Errors are the absence of a verdict, never evidence of spam.** Module not
  started, a timeout, an unparseable reply — all map to gossipsub `Ignore`
  (dropped, unscored); `Reject` stays reserved for real verdicts and sender
  violations (negative timestamp, missing proof). The validator mounts at node
  create while the module starts in `startNode`, so every boot has a
  verdictless window that `Reject` would turn into peer damage.
- **A freshly-activated membership's proof can validate `invalid`, not
  `not_ready`,** until its just-published root reaches the validator's window.
  The module softens the race with a rate-limited on-demand refresh, but the
  retry is the consumer's: treat such a registrant's first `invalid` as
  retryable before scoring spam (`scenarios/register/run.sh` polls this away).
- **A validator's module needs a live registry provider** to feed its root
  window (here: lez_core with an OPEN wallet on that node). Without one the
  window stays cold, every `validate_proof` answers `not_ready`, and the
  symptom is "no RLN-gated message ever arrives".
- **Double-signal detection is the module's job.** `validate_proof` owns the
  nullifier log and returns `duplicate` / `rate_limit_violation`; the
  validator keeps no log of its own. The recovered secret is slashing
  evidence, and using it is consumer policy.

## 6. Config ownership

Bring-up rides `createNode`'s flat conf: `rln-relay-lez`,
`rln-relay-registry-id`, `rln-relay-identifier`,
`rln-relay-user-message-limit`, and `rln-relay-registry-options` — a flat JSON
object whose pairs feed the register options array, and how
`funding_holding_account_id` reaches the module. `rlnStartRequest` carries the
module's start config as `configJson` (`{"epoch_size_sec","registries"}`)
built from that same conf, so a responder needs no out-of-band knowledge of
the scope and injects nothing.

## 7. The seam: in-process bridge, or an external responder

The production shape needs no responder: delivery-module's in-process bridge
invokes the co-resident RLN module and feeds each reply back verbatim. The
node config's `rln-in-process` key and the `rlnBridgeAttach` wire method both
enable the same bridge, and two internal lanes keep a slow registry operation
off the validate hot path. The acceptance runs n1 this way.

An external responder is a router, not a translator: forward the module's
reply **verbatim**, and never also answer a node that is already bridged.
Verbatim is what makes the seam testable — the consumer already parses the
module's own dialects (§3), so any re-encoding in the middle invents a third
wire that neither side's tests cover.
`scenarios/delivery-rln/run.sh` is the reference — it routes each
`rln*Request` to `liblogos_rln_module` and hands the raw reply to
`rlnRespond`. The acceptance runs n2 this way, so both topologies stay proven.

The per-op budgets belong to the delivery library, not the responder: 95 s for
the ops that may perform a registry read (`register_membership`,
`get_membership_state`, `generate_proof`), 10 s for the local rest. Nothing on
this side has a deadline to manage, a late `rlnRespond` fails with an
unknown-or-already-completed reqId, and the module never sends "timeout".
