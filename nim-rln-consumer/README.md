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
Scalar args (`registry_id`, `rln_identifier`, `signal_hex`, `timestamp`
u64) cross directly; complex args and results are JSON. Register options
are the LIP's `RegistryOptions` key/value array — `rate_limit` is an option
key, not an argument. One deliberate divergence: **every outbound proc
takes a timeout** (config `opTimeoutSec`, default 10s = delivery's hard
`rlnInvoke` limit) so scenarios can probe other budgets.

Op ↔ RLN-module method mapping (the bridge owns it):

| seam op (delivery's name) | module method (0.6.1) | dialect |
|---|---|---|
| `start` | `start` | result |
| `stop` | `stop` | result |
| `register_membership` | `register` | tstr |
| `get_membership_state` | `get_membership_state` | tstr |
| `get_epoch_quota` | `get_epoch_quota` | result |
| `generate_proof` | `generate_proof` | result |
| `validate_proof` | `validate_proof` | result |

Results use the reply envelope documented in delivery-module `docs/rln.md`:
`{"ok": <module reply>}` | `{"err": {"kind","message"}}` with the LIP's
kinds (`NOT_READY | TRANSIENT | BUDGET_EXHAUSTED | PERMANENT`). The bridge
absorbs the module wire's two reply dialects (tstr in-band error / result
envelope, both possibly double-encoded) and maps module error kinds onto
the LIP vocabulary; verdicts (incl. `invalid`/`duplicate`) are `ok` values,
never `err`. At the module wire, timestamps cross as strings; register
options pass through VERBATIM — the module (wire 0.6.1) speaks the same
LIP RegistryOptions array the seam carries.

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
   event / polling) — the model the module already implements, and the one
   delivery-module's `docs/rln.md` now leans on (the library synthesizes a
   `TRANSIENT` failure at 10s rather than waiting). This module now runs at
   the 10s default itself; raise `E2E_CONSUMER_OP_TIMEOUT_S` for slow
   targets and watch which legs stop fitting.
2. **The op was named `verify_proof` in the seam but `validate_proof` on
   the module.** RESOLVED: the `rln/integration-fixes` stack renames the
   seam's callback typedef, struct field and nim wrapper to
   `validate_proof` (delivery-module's shim follows; its *event* names stay
   `rlnVerifyProofRequest`), and this module's mirror follows — one name
   end to end.
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
8. **The seam's `start` op carries no scope** — the typed callback is
   `(req_id)` only, so whoever answers must already know the registry and
   epoch size out of band (this module's bridge takes them from
   `createConsumer`; the `delivery-rln` scenario's responder takes them
   from the harness). PARTLY RESOLVED at a48f8b8a: the scope now lives in
   `createNode`'s conf (`rln-relay-lez` / `-registry-id` / `-identifier` /
   `-user-message-limit`) — but `start` itself still crosses scope-less,
   and the conf's `rln-relay-epoch-sec` is carried yet never read, so the
   responder still guesses the epoch size. Wire it through `start()`.
9. **No `RegistryOptions` key carries funding from the library.** The LIP
   defines `funding_holding_account_id` as the LEZ registry option, but
   delivery's bring-up sends only `rate_limit` — every responder today
   must inject the payer itself. Who funds a registration is an open seam
   design question.
10. **RESOLVED (module wire 0.6.0)**: the module's register now speaks the
    LIP shape — `register(registry_id, rln_identifier, options_json)` with
    the RegistryOptions key/value array carrying `rate_limit` (absent →
    the module's default). The bridge and the `delivery-rln` responder pass
    the seam's options through verbatim; the old array→(rate, object)
    adapters are gone.
11. **Proof transport is settled: ONE opaque blob.** `generate_proof`
    replies carry `proof_canonical` (wire 0.6.1); delivery ships those
    bytes as `message.proof` and the validator hands them back whole as
    `{"proof": "<hex>"}` — no consumer ever assembles or parses proof
    bytes, and delivery's bundled zerokit v2 never touches them.
12. **A validator node's module needs a live registry provider.** The root
    window is fed by registry reads (lez_core with an OPEN wallet in this
    stack); without one the window stays permanently cold and every
    `validate_proof` answers `not_ready`. Whoever hosts the RLN module on
    a validator node owns bringing up its provider stack.
13. **The reply envelope must actually be parsed.** Delivery's library
    originally returned any responder JSON as success, so an
    `{"err":...}` answer to `register` was logged as "RLN membership
    registered" and a failed best-effort registration was invisible. The
    `rln/integration-fixes` stack unwraps the envelope on every call —
    keep that property when the seam grows new ops.

## Method surface (what scenarios call)

`createConsumer(cfgJson)` — one consumer per context, bound to a scope:
`{"registryId","rlnIdentifierHex","epochSizeSec"?,"opTimeoutSec"?,
"pollIntervalSec"?,"confirmBudgetSec"?}` (string values).
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
