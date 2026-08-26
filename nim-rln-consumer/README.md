# nim-rln-consumer — a Nim mock of logos-delivery for RLN acceptance tests

A logos-core module whose core is a Nim library (`RlnConsumer`), built to
stand in for logos-delivery in this harness's RLN scenarios until the real
integration lands. Every RLN operation crosses the exact layers delivery
will use in production:

```
harness (logoscore --json call)
  └─► nim_rln_consumer plugin (C++, interface "universal")
        └─► librlnconsumer (Nim, nim-ffi 0.3 C ABI)          ┐ the delivery
              └─► the RLN seam (rlnconsumer_rln.h:           │ sandwich
                  7 opaque-JSON op callbacks + req_id/response) 
                    └─► plugin's seam bridge (worker thread) ┘
                          └─► lp wire ─► liblogos_rln_module
```

## The mirrored seam

`nim-lib/include/rlnconsumer_rln.h` + `nim-lib/src/rln_seam.nim` are a
prefix-renamed copy of logos-delivery's RLN module seam (branch
`impl-plugable-rln-api-module`, 2026-08-25: `library/liblogosdelivery_rln.h`
+ `library/logos_delivery_api/rln_api.nim`). Same op set, same req_id /
response contract, same threading discipline. One deliberate divergence:
**`rlnInvoke` takes a per-op timeout** (config `opTimeoutSec`, default 30s)
instead of delivery's hard 10 seconds — see "Findings for the delivery
team".

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

The bridge absorbs the module wire's two reply dialects (tstr in-band error
/ result envelope, both possibly double-encoded) so the Nim side sees one:
`{"ok":true,"value":...}` | `{"ok":false,"error":{class,kind,message}}`.
Payloads are JSON objects of the module method's args; timestamps cross as
strings, `rate_limit` as a JSON integer.

## Async registration (the design center)

`registerMembership` returns as soon as the module's dispatch returns —
normally `state:"pending"` within a few seconds — and activation is
observed via `getMembershipState` polling, a Nim-side confirmation poller
(the shape a real node needs), and the re-emitted
`membership_state_changed` event. No single call ever blocks for the
chain's confirmation latency. This mirrors delivery-module's own
fire-then-event precedent (`start`/`stop` → `nodeStarted`/`nodeStopped`).

## Findings for the delivery team

1. **A hard 10s `rlnInvoke` timeout cannot survive registration.** The
   module's `register` dispatch alone can legitimately take up to ~70s (its
   registry read leg) before returning `pending`, and confirmation takes
   minutes. Registration must be modeled asynchronously (pending + event /
   polling), and the seam timeout must at least cover the module's
   synchronous legs. Reproduce delivery's behavior with
   `E2E_CONSUMER_OP_TIMEOUT_S=10 ./run.sh consumer-register --target local`
   and watch the register leg time out at the seam while the module
   proceeds regardless.
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
   from any other thread. Delivery's host module will face the same
   constraints when it implements the callbacks.
7. **A bare JSON-object argument into a string-typed module method wedges
   the logoscore CLI call** (no error, no coercion) — pass JSON-valued
   strings via `@argfile`.

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
