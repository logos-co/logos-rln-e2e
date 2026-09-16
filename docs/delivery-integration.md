# RLN module integration notes for logos-delivery

logos-delivery implements no RLN itself: it outsources every RLN operation to
`liblogos_rln_module` across delivery-module's bridge, so the module owns the
credentials, epochs, slots and proofs while delivery owns the messages and the
gossipsub validator. This is what the delivery side of that split takes on
(module wire 0.8.x), written down from what this repo's acceptance scenarios
enforce; the references point at the scenario that proves each claim.

Each fact lives in one document only: **logos-lips #376** is the schema
authority, **`logos-rln-module/docs/wire-binding.md`** is how that schema
crosses the logos-core wire, logos-delivery-module's **`docs/rln.md`** is the
bridge's own operator contract (event names and arguments, `rlnRespond`,
in-process mode), and this doc is what a delivery integration must do with
them.

## Running the acceptance, from a fresh clone

`delivery-rln` drives the delivery stack end to end against the real RLN
module; `keystore` pins the custody and lifecycle behaviors in §1 and §2.

Host tools: **nix with flakes**, `bash jq python3 curl openssl rsync tar`,
and **cargo** (`--target local` builds logos-lez-rln's provisioning binaries).
`docker` only for `delivery-relay-rln`. darwin-arm64 and linux
(x86_64/aarch64).

### 1. The repos

```sh
git clone https://github.com/logos-co/logos-rln-e2e
git clone https://github.com/logos-co/logos-delivery-module
git clone --recurse-submodules https://github.com/logos-messaging/logos-delivery
git clone https://github.com/logos-co/logos-lez-rln     # --target local only
```

`flake.lock` pins logos-rln-modules and logos-lez-rln at their current mains,
so **the RLN module stack needs no checkout** — it builds from the pin. It
pins logos-delivery-module at a rev that predates the RLN bridge, which is
why the two delivery repos are cloned: upstream `master` on both, no fork.
Note the org — `logos-delivery` lives under **logos-messaging**, the shim under
logos-co.
`logos-delivery` must have its submodules, since a path override carries only
what is on disk.

### 2. Build logos-lez-rln's provisioning binaries (`--target local` only)

Order matters — the host build strips the deploy blobs:

```sh
cd logos-lez-rln/lez-rln
cargo risczero build --manifest-path methods/guest/Cargo.toml
PYO3_PYTHON=$(command -v python3) cargo build --release \
    --bin run_setup --bin derive_accounts --bin mint_payer --bin fund_account
```

`fund_account` is the one a node cannot do without: it derives its own payer and
nothing on-chain can mint native into it.

### 3. Run it

```sh
cd logos-rln-e2e
export DELIVERY_MODULE_CHECKOUT=../logos-delivery-module \
       LOGOS_DELIVERY_CHECKOUT=../logos-delivery \
       LEZ_RLN_CHECKOUT=../logos-lez-rln

./run.sh delivery --target none      # fastest smoke: co-residency, no chain
./run.sh delivery-rln --target local # the acceptance
./run.sh keystore --target local     # custody modes
```

`--target local` boots a sequencer on `127.0.0.1:3040` through logos-lez-rln's
`dev.sh`, mints a fee payer and funds it **at genesis** — v0.2.5 charges a fee
on every public transaction and runs its faucet only in the genesis block, so
an account created later can never hold native balance — then provisions a
fresh tree and stages it into the run's wallet home. Nothing to configure.

The first run builds `liblogosdelivery` from source: only pinned revs are
prebuilt in the logos cache, and the delivery checkouts are newer than the
pin. Expect a long first build, and keep tens of GB free in `/nix`.

### The relay topology

`delivery-relay-rln` puts a third node between the peers, as a container, so
the hop is a real one. Build the image first; everything in it is a published
artifact, nothing compiles:

```sh
bash tools/build-e2e-image.sh
./run.sh delivery-relay-rln --target local                  # relay validates
E2E_RELAY_RLN=0 ./run.sh delivery-relay-rln --target local  # topology only
```

### The hosted testnet

`--target testnet` needs `E2E_DEPLOYMENT=<name>` from `deployments/` — there is
no default. Both committed deployments were provisioned before v0.2.5 and a
v0.2.5 redeploy needs a payer funded in the new chain's genesis block, so a
testnet run is currently a local-target run until that redeploy lands.

### Reading the output

Each assertion prints as it passes, so the transcript is the assertion list —
custody, config surface, registration to `active`, the `valid` verdict
reaching `messageReceived` on the second node, and the responder-hijack
control, in the order the scenario header enumerates them. `$E2E_RUN_DIR`
keeps the logs, `responder-n2.log` the witness's verdict trail.

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

### The consumer does not have to ask for one

`start`'s config already names the registries this node intends to prove
against, and a node that names one intends to have a membership on it. So
`start` spawns a provisioning task that gets one, and **a headless integration
never calls `register_membership` at all**. `delivery-rln` is the proof: it
funds two nodes, starts them, and asserts each reaches `active` on its own —
the word "register" does not appear in the scenario.

- **`start` still returns immediately.** Provisioning rides the same one-shot
  background pass as the root warm-up. It can wait minutes for the wallet to
  open and longer for funding to land; `start` waits for neither.
- **Sends gate on state, not on `start`.** The membership may not exist yet
  when `start` returns. `get_membership_state` and the
  `membership_state_changed` event are the signals, exactly as for a
  registration the consumer asked for.
- **It registers registry-wide.** The scope is the empty `rln_identifier`,
  which backs every application on that registry (`scope_matches`), so nothing
  in `configureRln` has to name an application for provisioning to be useful.
- **It stands down for a membership that already exists** — under *any* scope,
  not only the registry-wide one it would create itself. A second membership
  is a second slice of the registry's rate-limit budget and no new capability,
  and the extra tree insert invalidates proofs already in flight.
- **Progress is readable.** While there is no membership yet,
  `get_membership_state` answers `state:"unknown"` with
  `provisioning:{step,detail}`; `step` is one of `waiting_for_wallet`,
  `awaiting_funding`, `registering`, `done`, `refused`. `refused` means
  nothing retries without a new `start()`.
- **Two knobs, both in `start`'s config.** `{"provision": false}` opts out
  entirely; `{"rate_limit": N}` sets the rate a provisioned membership asks
  for. Nothing is spent when the config names no registry.

**What the deployment still owes it: native balance.** No program can mint
native, so the wallet the module derives at bring-up starts empty and must be
funded from outside — at genesis, over the L1 bridge, or by a transfer.
`wallet_status` publishes the account to fund as `payer`, and
`get_native_balance` reads any account's balance. Budget
`rate_limit x price_per_unit` **plus the fee reserve**, which at the declared
gas limit is ~6.5e8 against a price near 1e6: an amount sized only for the
price leaves an account that cannot transact at all. Until the balance covers
both, provisioning sits in `awaiting_funding` rather than burning attempts.

### Once it exists

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
  absent) and registry-specific keys ride the same array. As of 0.8.0 nothing
  in the options names who pays: the registry charges the module's own payer,
  in native, and `funding_holding_account_id` is accepted and ignored with one
  deprecation line so consumers that still send it keep registering.
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
  window — here `liblogos_lez_rln_module`, whose own in-process wallet must
  have reached `ready` on that node (it reports this via `wallet_status`;
  since 3.0.0 nothing else may open it). Without one the
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
object whose pairs feed the register options array. `rlnStartRequest` carries the
module's start config as `configJson` (`{"epoch_size_sec","registries"}`)
built from that same conf, so a responder needs no out-of-band knowledge of
the scope and injects nothing.

## 7. The seam: the in-process bridge (not optional for lez)

`createNode` auto-enables delivery-module's in-process bridge whenever the
node conf carries `rln-relay-lez`: the bridge invokes the co-resident RLN
module and feeds each reply back verbatim, two internal lanes keep a slow
registry operation off the validate hot path, and a bridge that cannot come
up fails `createNode`. The `rlnBridgeEnable` wire method enables the same
bridge directly — a test hook, since without the conf key the library never
issues RLN requests. There is no opt-out and no external-responder topology
for lez.

The `rln*Request` events keep emitting for observability, and `rlnRespond`
still exists on the module surface — but only ONE answer lands per reqId,
and the guard is **first-wins, not bridge-wins**: on the validate hot path
the bridge always answers first, while on the registry-read ops an eager
external answer can beat the bridge's own slow call (the module's in-flight
short-circuit answers the second caller instantly). So treat the events as
strictly read-only — anything that answers them can end up authoritative
for a slow op on a bridged node. `scenarios/delivery-rln/run.sh` pins this:
its witness responder answers every event the old external-responder way,
asserts every hot-path answer is rejected while the messages keep flowing,
and logs the register race when it wins one.

The per-op budgets belong to the delivery library: 95 s for the ops that may
perform a registry read (`register_membership`, `get_membership_state`,
`generate_proof`), 10 s for the local rest. Nothing on this side has a
deadline to manage, a late `rlnRespond` fails with an
unknown-or-already-completed reqId, and the module never sends "timeout".
