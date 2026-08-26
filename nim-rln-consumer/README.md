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
`impl-plugable-rln-api-module`, refreshed 2026-08-26:
`library/liblogosdelivery_rln.h` + `library/logos_delivery_api/rln_api.nim`
— the typed one-callback-per-function surface). Same op set, same typed
signatures, same req_id / response contract, same threading discipline.
Scalar args (`registry_id`, `rln_identifier`, `signal_hex`, `timestamp`
u64) cross directly; complex args and results are JSON. Register options
are the LIP's `RegistryOptions` key/value array — `rate_limit` is an option
key, not an argument. One deliberate divergence: **every outbound proc
takes a timeout** (config `opTimeoutSec`, default 10s = delivery's hard
`rlnInvoke` limit) so scenarios can probe other budgets.

Op ↔ RLN-module method mapping (the bridge owns it):

| seam op (delivery's name) | module method (0.5.0) | dialect |
|---|---|---|
| `start` | `start` | result |
| `stop` | `stop` | result |
| `register_membership` | `register` | tstr |
| `get_membership_state` | `get_membership_state` | tstr |
| `get_epoch_quota` | `get_epoch_quota` | result |
| `generate_proof` | `generate_proof` | result |
| **`verify_proof`** | **`validate_proof`** | result |

Results use the reply envelope documented in delivery-module `docs/rln.md`:
`{"ok": <module reply>}` | `{"err": {"kind","message"}}` with the LIP's
kinds (`NOT_READY | TRANSIENT | BUDGET_EXHAUSTED | PERMANENT`). The bridge
absorbs the module wire's two reply dialects (tstr in-band error / result
envelope, both possibly double-encoded) and maps module error kinds onto
the LIP vocabulary; verdicts (incl. `invalid`/`duplicate`) are `ok` values,
never `err`. At the module wire, timestamps cross as strings and
`rate_limit` as a JSON integer — the bridge adapts the LIP options array
onto the module's `register(rate_limit, options_object)` shape.

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
2. **The op is named `verify_proof` in the seam but `validate_proof` on the
   module (and `validateProof` in the RlnInterface concept).** One name
   should win before call sites multiply.
3. **nim-ffi's generated `<lib>_ctx_*` scalar wrappers free their callback
   box on the FIRST callback — including the non-terminal `RET_STALE_WARN`
   progress tick** — a use-after-free for any no-arg method slower than
   ~5s. This module drives the raw exports with its own STALE_WARN-aware
   trampolines (`src/api_call_handler.h`, copied from delivery-module).
   Worth an upstream nim-ffi issue.
4. **Nim `{.exportc.}` alone gives hidden visibility on macOS** — hand-
   written C ABI additions (like the seam's two functions) need
   `{.exportc, cdecl, dynlib.}` or the host can't resolve them.
5. **A proof from a freshly-activated membership can validate `invalid` for
   ~one root-refresh (~10s).** The validator's root window is warm but does
   not yet contain the post-registration root, and a warm-but-stale window
   answers `invalid`, not `not_ready`. A consumer that starts its RLN stack
   before registering (the natural delivery order) hits this on its own
   first message; validators hit it for any fresh registrant. Treat an
   `invalid` on a just-activated membership as retryable for one refresh
   interval before declaring spam/drop.
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
   from the harness). Worth deciding where that config authoritatively
   lives before two responders guess differently.
9. **No `RegistryOptions` key carries funding from the library.** The LIP
   defines `funding_holding_account_id` as the LEZ registry option, but
   delivery's bring-up sends only `rate_limit` — every responder today
   must inject the payer itself. Who funds a registration is an open seam
   design question.
10. **The module's register wire predates the LIP's shape**: the LIP says
    `register(scope, RegistryOptions)` with `rate_limit` as an option key;
    the module's 0.5.0 wire is `register(registry_id, rln_identifier,
    rate_limit i64, options OBJECT)`. The array→(rate, object) adapter
    lives in this bridge (`rln_seam_bridge.cpp`) and in the `delivery-rln`
    responder — one of the two wires should eventually move.

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
