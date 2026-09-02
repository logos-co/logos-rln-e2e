# nim-rln-consumer — a Nim mock of logos-delivery for RLN acceptance tests

A logos-core module whose core is a Nim library (`RlnConsumer`), built to
stand in for logos-delivery in this harness's RLN scenarios until the real
integration lands. Every RLN operation crosses the exact layers delivery
will use in production:

```
harness (logoscore --json call)
  └─► nim_rln_consumer plugin (C++, interface "universal")
        └─► librlnconsumer (Nim, nim-ffi 0.3 C ABI)          ┐ the delivery
              └─► the RLN seam (rlnconsumer_rln.h: one typed │ sandwich
                  callback per RLN function + req_id/response) 
                    └─► plugin's seam bridge (worker thread) ┘
                          └─► lp wire ─► liblogos_rln_module
```

## The mirrored seam

`nim-lib/include/rlnconsumer_rln.h` + `nim-lib/src/rln_seam.nim` are a
prefix-renamed copy of logos-delivery's RLN module seam (branch
`impl-plugable-rln-api-module` + the `rln/integration-fixes` stack,
refreshed 2026-08-27: `library/liblogosdelivery_rln.h` +
`library/logos_delivery_api/rln_api.nim` — the typed
one-callback-per-function surface, now carrying the `verify_proof` →
`validate_proof` rename). Same op set, same typed
signatures, same req_id / response contract, same threading discipline.
The surface also matches delivery's client-facing `RlnInterface` concept
(branch `feat/rln-api-structure` @ `e5f8f327`, force-pushed again 2026-09-01:
`waku/rln/rln_api.nim` + `waku/rln/types.nim`) — same 7 ops with the verb
names (`getMembershipState`, `getEpochQuota`, `validateProof`), scope on
every call with no module-held defaults, uint64-seconds timestamps, the
4 verdicts, the 4 error kinds, and the 9 membership statuses (which the
RLN module's lifecycle enum matches variant-for-variant, same order).
That branch's restructure also moved `toRLNSignal` to
`waku/rln/rln_evm_backend/proof.nim` — byte-identical, so the signal
parity below is unaffected.
Scalar args (`registry_id`, `rln_identifier`, `signal_hex`, `timestamp`
u64) cross directly; complex args and results are JSON. Register options
are the LIP's `RegistryOptions` key/value array — `rate_limit` is an option
key, not an argument. One deliberate divergence: **every outbound proc
takes a timeout** — the defaults mirror delivery's per-op budgets (config
`opTimeoutSec`, default 10s, for local ops; `registryOpTimeoutSec`,
default 95s, for register / get_membership_state / generate_proof) so
scenarios can probe other budgets.

Op ↔ RLN-module method mapping (the bridge owns it):

| seam op (delivery's name) | module method (0.7.0) | dialect |
|---|---|---|
| `start` | `start` | result |
| `stop` | `stop` | result |
| `register_membership` | `register_membership` | tstr |
| `get_membership_state` | `get_membership_state` | tstr |
| `get_epoch_quota` | `get_epoch_quota` | result |
| `generate_proof` | `generate_proof` | result |
| `validate_proof` | `validate_proof` | result |

Results are the module's replies forwarded VERBATIM (delivery-module
`docs/rln.md` since the seam rework — the ok/err envelope is retired): the
LogosResult envelope `{"success","value","error"}` for the result-dialect
ops, the compact tstr reply (in-band `{"error":{class,kind,message}}`) for
`register` / `get_membership_state`. The bridge is a router — it
synthesizes only transport failures, in the op's own dialect shape — and
the Nim side parses the dialects exactly as delivery's `rln_api.nim` does
(double-encoding tolerated; verdicts incl. `invalid`/`duplicate` are
successful values, never errors). At the module wire, timestamps cross as
strings; register options pass through VERBATIM — the module (wire 0.6.1)
speaks the same LIP RegistryOptions array the seam carries, and `start`
carries the module's start config built Nim-side from `createConsumer`'s
cfg.

Proof transport: `generate_proof` replies carry `proof_canonical` (wire
0.6.1) — the full 289-byte canonical zerokit serialization as hex. That is
the message-wire blob: delivery ships exactly those bytes as
`message.proof`, and `validate_proof` accepts them back as a lone
`{"proof": "<hex>"}` (every public value is recovered from the blob). The
decomposed reply fields remain the LIP shape for consumers that carry
fields instead; `consumer-register` pins both forms.

## Async registration (the design center)

`registerMembership` returns as soon as the module's dispatch returns —
normally `state:"pending"` within a few seconds — and activation is
observed via `getMembershipState` polling, a Nim-side confirmation poller
(the shape a real node needs), and the re-emitted
`membership_state_changed` event. No single call ever blocks for the
chain's confirmation latency. This mirrors delivery-module's own
fire-then-event precedent (`start`/`stop` → `nodeStarted`/`nodeStopped`).

## Findings for the delivery team

1. **A hard 10s `rlnInvoke` timeout cannot survive a blocking registration.**
   The module's `register` dispatch alone can legitimately take up to ~70s
   (its registry read leg) before returning `pending`, and confirmation
   takes minutes. Registration must be modeled asynchronously (pending +
   event / polling) — the model the module already implements. RESOLVED at
   delivery's `95e7e3c7`: per-op budgets from the module's documented time
   budgets — 95s for registry-read ops (`register`,
   `get_membership_state`, `generate_proof`), 10s local for the rest; this
   module's defaults mirror them (`opTimeoutSec` / `registryOpTimeoutSec`).
2. **The op was named `verify_proof` in the seam but `validate_proof` on
   the module.** RESOLVED: the `rln/integration-fixes` stack renames the
   seam's callback typedef, struct field and nim wrapper to
   `validate_proof` (delivery-module's shim follows; since its `bcdc8348`
   the *event* is `rlnValidateProofRequest` too), and this module's mirror
   follows — one name end to end.
3. **nim-ffi's generated `<lib>_ctx_*` scalar wrappers free their callback
   box on the FIRST callback — including the non-terminal `RET_STALE_WARN`
   progress tick** — a use-after-free for any no-arg method slower than
   ~5s. This module drives the raw exports with its own STALE_WARN-aware
   trampolines (`src/api_call_handler.h`, copied from delivery-module).
   Worth an upstream nim-ffi issue.
4. **Nim `{.exportc.}` alone gives hidden visibility on macOS** — hand-
   written C ABI additions (like the seam's two functions) need
   `{.exportc, cdecl, dynlib.}` or the host can't resolve them.
5. **A proof from a freshly-activated membership can validate `invalid` —
   not `not_ready` — until its root reaches the validator's window.** The
   module softens this (0.6.1): a warm-window root miss triggers a
   rate-limited background window refresh, and the prover's own window
   adopts the fresh root at generate time, so the race typically resolves
   on the next retry (~a provider round-trip) instead of a full refresh
   interval (~10s). The consumer still owns that one retry: treat a first
   `invalid` for a just-activated registrant as retryable before declaring
   spam/drop (the `delivery-rln` send leg models exactly this).
6. **The host side of the seam must keep the module's main thread pumping.**
   Two hangs proved the contract: an lp client owned by a non-pumping
   worker thread never receives replies, and a single-concurrency dispatch
   that blocks the main thread starves its own lp completions. The working
   shape — identical to the Rust modules' — is: lp client created on the
   main thread (before its loop runs), blocking work on
   `concurrency:"multi"` dispatch workers, `lp_invoke_async` + semaphore
   from any other thread. NOTE: delivery-module's own impl branch avoids
   the whole contract by design — it re-emits the callbacks as
   `rln*Request` events and lets an EXTERNAL responder answer via
   `rlnRespond`, and its dispatches never block on lp. The contract above
   binds any host that bridges to the RLN module in-process over lp (as
   this module deliberately does, to keep both topologies covered).
7. **A bare JSON-object argument into a string-typed module method wedges
   the logoscore CLI call** (no error, no coercion) — pass JSON-valued
   strings via `@argfile`.
8. **The seam's `start` op carries no scope** — RESOLVED at delivery's
   `95e7e3c7`: `start` now crosses with `config_json`, the module's start
   config (`{"epoch_size_sec","registries"}`) built from the node's own
   conf, so no responder needs the scope out of band. The `delivery-rln`
   scenario asserts the event's config carries the configured epoch and
   registry. This module's mirror follows: `start` crosses with the
   config built from `createConsumer`'s cfg; the bridge-owned start scope
   is gone.
9. **No `RegistryOptions` key carries funding from the library.** RESOLVED:
   `rln-relay-registry-options` (delivery's `95e7e3c7`, a flat JSON object
   in the node conf) feeds registry-specific pairs — with the rebased
   stack's register retype they land in the RegistryOptions array, so
   `funding_holding_account_id` rides the conf and the responder injects
   nothing (asserted end-to-end by `delivery-rln`).
10. **RESOLVED (module wire 0.6.0; renamed register_membership at 0.7.0 —
    "register" is a C/C++ keyword generated clients could not carry, and the
    seam already used the escaped name)**: the module's register now speaks the
    LIP shape — `register(registry_id, rln_identifier, options_json)` with
    the RegistryOptions key/value array carrying `rate_limit` (absent →
    the module's default). The bridge and the `delivery-rln` responder pass
    the seam's options through verbatim; the old array→(rate, object)
    adapters are gone.
11. **Proof transport is settled: ONE opaque blob.** `generate_proof`
    replies carry `proof_canonical` (wire 0.6.1); delivery ships those
    bytes as `message.proof` and the validator hands them back whole as
    `{"proof": "<hex>"}` — no consumer ever assembles or parses proof
    bytes, and delivery's bundled zerokit v2 never touches them. Note:
    the typed `RlnInterface` (feat/rln-api-structure) models the proof
    as the DECOMPOSED LIP object (`proof[128]` + six 32-byte fields), so
    the blob is a gossip-wire detail — the blob ↔ typed-object adapter is
    delivery's, at its message boundary; consumers still never craft
    proof bytes.
12. **A validator node's module needs a live registry provider.** The root
    window is fed by registry reads (lez_core with an OPEN wallet in this
    stack); without one the window stays permanently cold and every
    `validate_proof` answers `not_ready`. Whoever hosts the RLN module on
    a validator node owns bringing up its provider stack.
13. **The reply envelope must actually be parsed.** Delivery's library
    originally returned any responder JSON as success, so an
    `{"err":...}` answer to `register` was logged as "RLN membership
    registered" and a failed best-effort registration was invisible.
    OVERTAKEN at delivery's `95e7e3c7`: the ok/err envelope is retired
    outright — the library parses the MODULE's own wire dialects
    (LogosResult envelope for result methods, compact tstr with in-band
    `{"error":{...}}` for register/get_membership_state) and the
    responder forwards module replies verbatim. This module's mirror
    follows: the bridge routes module replies verbatim and the Nim side
    parses the native dialects, mirroring delivery's `rln_api.nim`.
14. **`feat/rln-api-structure` was force-pushed 2026-08-28 (`1dda5d02` →
    `a0560b5d`) and the layout the impl branch imports no longer
    exists.** The `waku/rln/api/` folder is gone — the client-facing
    interface now lives at `waku/rln/rln.nim` (a typed `RlnInterface`
    concept) + `waku/rln/types.nim`; `group_manager` became
    `rln_evm_backend/`; the placeholder `waku/api/rln.nim` and the RLN
    functions in `kernel_api.nim` were removed; the get ops grew verbs
    (`getMembershipState`, `getEpochQuota`). `impl-plugable-rln-api-module`
    imports `waku/rln/api/types`, and the `rln/integration-fixes` stack's
    base cherry-pick carries the OLD api/ layout — both need a rebase onto
    the reworked structure before the branches can merge. DONE on the
    forks (2026-08-28; re-done 2026-09-01 after a second force-push,
    `a0560b5d` → `e5f8f327`): `adklempner/logos-delivery` and
    `adklempner/logos-delivery-module` `rln/integration-fixes` now carry
    the impl branch (all 13 commits through `fb41368c` — which absorbed
    errors→Ignore, the prover leg and the RegistryOptions register)
    rebased onto `e5f8f327`, plus the two still-ours fixes (legacy
    provider retype, RequestBroker `##` demotion); the `delivery-rln`
    scenario runs against them. The consumer mirror is caught up to the
    reworked seam (start config, verbatim dialects, per-op budgets).
    The interface home moved again in the review round: the concept now
    lives at `waku/rln/rln_api.nim` beside `waku/rln/types.nim`, the
    backend folder is `rln_evm/`, and the seeded `rln_lez_backend/` was
    deleted as duplicate types — the LEZ-backed `RlnInterface`
    implementation (the seam this mirror exists to exercise) has no
    committed slot right now; reviewers name LEZ as one of the 3
    intended backends.

## Method surface (what scenarios call)

`createConsumer(cfgJson)` — one consumer per context, bound to a scope:
`{"registryId","rlnIdentifierHex","epochSizeSec"?,"opTimeoutSec"?,
"registryOpTimeoutSec"?,"pollIntervalSec"?,"confirmBudgetSec"?}` (string
values).
`startRln` / `stopRln`, `registerMembership(rateLimit, optionsJson)`,
`getMembershipState`, `generateMessageProof(payloadHex, contentTopic,
timestampSec)` (builds the delivery-shaped signal `payload ++ contentTopic
++ timestamp bytes`, returns `{"signal_hex","proof"}`),
`validateMessageProof(signalHex, timestampSec, proofJson)`,
`getEpochQuota(timestampSec)`, plus selftest probes `ping` / `slowPing`.
Event: `membership_state_changed(registry_id, rln_identifier,
membership_hash, state, previous)` — the module's event re-emitted.

## Build

```sh
nix build ./nim-rln-consumer#lgx    # from the repo root; the harness does
                                    # this automatically (artifacts.sh
                                    # resolves CONSUMER_LGX when a scenario
                                    # lists nim_rln_consumer)
```

The subflake builds `librlnconsumer` (deps pinned in `nim-lib/nix/deps.nix`,
a subset of logos-delivery's lock) and wraps it with logos-module-builder.
The generated nim-ffi C header is produced in-derivation. This is a `path:`
subflake of the e2e repo: the working tree is the pin — edit and re-run.

## Scenarios

- `consumer-selftest` (`--target none`) — chainless gate: load, ping,
  stale-warn crossing, clean seam failure with no RLN module.
- `consumer-register` (`--target local|testnet`) — the register scenario's
  lifecycle through the consumer: fund (direct) → register (async) → active
  (poll + event) → proof valid / tampered invalid / duplicate.
- `consumer-gifter` (`--target local`) — delegated registration via an open
  gifter; the client node holds no funds.
