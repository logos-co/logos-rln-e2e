# nim-rln-consumer — a Nim mock of logos-delivery for RLN acceptance tests

A logos-core module whose core is a Nim library (`RlnConsumer`), built to
stand in for logos-delivery in this harness's RLN scenarios. It is the
harness's module-wire reference: a standalone consumer that exercises
liblogos_rln_module end to end without depending on a delivery build. Every
RLN operation crosses the exact layers delivery will use in production:

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
prefix-renamed copy of logos-delivery's RLN module seam
(`library/liblogosdelivery_rln.h` + `library/logos_delivery_api/rln_api.nim`).
Same op set, same typed signatures, same req_id / response contract, same
threading discipline. It also matches delivery's client-facing `RlnInterface`
concept (`waku/rln/rln_api.nim` + `waku/rln/types.nim`): the same 7 ops, scope
on every call with no module-held defaults, uint64-seconds timestamps, the 4
verdicts, the 4 error kinds, and the 9 membership statuses (which the RLN
module's lifecycle enum matches variant-for-variant, same order). Delivery
adopted the module's dialects and names wholesale, so the surfaces now agree;
**delivery's own docs are the authority** and this mirror follows them.

Scalar args (`registry_id`, `rln_identifier`, `signal_hex`, `timestamp` u64)
cross directly; complex args and results are JSON. Register options are the
LIP's `RegistryOptions` key/value array — `rate_limit` is an option key, not
an argument. One deliberate divergence: **every outbound proc takes a
timeout** — the defaults mirror delivery's per-op budgets (config
`opTimeoutSec`, default 10s, for local ops; `registryOpTimeoutSec`, default
95s, for register / get_membership_state / generate_proof) so scenarios can
probe other budgets.

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

Results are the module's replies forwarded VERBATIM: the LogosResult envelope
`{"success","value","error"}` for the result-dialect ops, the compact tstr
reply (in-band `{"error":{class,kind,message}}`) for `register_membership` /
`get_membership_state`. The bridge is a router — it synthesizes only transport
failures, in the op's own dialect shape — and the Nim side parses the dialects
exactly as delivery's `rln_api.nim` does (double-encoding tolerated; verdicts
incl. `invalid`/`duplicate` are successful values, never errors). At the module
wire, timestamps cross as strings; register options pass through VERBATIM — the
module speaks the same LIP RegistryOptions array the seam carries,
and `start` carries the module's start config built Nim-side from
`createConsumer`'s cfg.

Proof transport: `generate_proof` replies carry `proof_canonical` — the full
289-byte canonical zerokit serialization as hex. That is the
message-wire blob: delivery ships exactly those bytes as `message.proof`, and
`validate_proof` accepts them back as a lone `{"proof": "<hex>"}` (every public
value is recovered from the blob). No consumer ever assembles or parses proof
bytes. The decomposed reply fields remain the LIP shape (`proof[128]` + six
32-byte fields) — the form delivery's typed `RlnInterface` models, with the
blob ↔ typed-object adapter at delivery's message boundary.
`consumer-register` pins both forms.

## Async registration (the design center)

`registerMembership` returns as soon as the module's dispatch returns —
normally `state:"pending"` within a few seconds — and activation is observed
via `getMembershipState` polling, a Nim-side confirmation poller (the shape a
real node needs), and the re-emitted `membership_state_changed` event. No
single call ever blocks for the chain's confirmation latency: the register
dispatch alone can legitimately take ~70s (its registry read leg) before
returning `pending`, and confirmation takes minutes, so no hard 10s budget can
wrap it. This mirrors delivery-module's own fire-then-event precedent
(`start`/`stop` → `nodeStarted`/`nodeStopped`).

## Traps that still bite

- **The host must keep the module's main thread pumping.** Two hangs proved
  the contract: an lp client owned by a non-pumping worker thread never
  receives replies, and a single-concurrency dispatch that blocks the main
  thread starves its own lp completions. The working shape — identical to the
  Rust modules' — is: lp client created on the main thread (before its loop
  runs), blocking work on `concurrency:"multi"` dispatch workers,
  `lp_invoke_async` + semaphore from any other thread. Binding on any host
  that bridges to the module in-process over lp, as this one deliberately
  does — and as delivery-module's own bridge now does too (its slow lane
  rides lp under the same discipline); only a host that answers from a
  fully external responder never blocks on lp.
- **Nim `{.exportc.}` alone gives hidden visibility on macOS.** Hand-written
  C ABI additions (the seam's two functions) need
  `{.exportc, cdecl, dynlib.}` or the host can't resolve them.
- **nim-ffi's generated `<lib>_ctx_*` scalar wrappers free their callback box
  on the FIRST callback** — including the non-terminal `RET_STALE_WARN`
  progress tick — a use-after-free for any no-arg method slower than ~5s.
  This module drives the raw exports with its own STALE_WARN-aware
  trampolines (`src/api_call_handler.h`, copied from delivery-module).
- **Use `node{"key"}`, never `node["key"]`, and wrap every `parseJson` in
  `try`.** The bracket accessor raises `KeyError`, which breaks the effect
  tracking of the `{.async: (raises: []).}` procs (the confirmation poller is
  one) and turns a missing field into a crash instead of a default.
- **A bare JSON-object argument into a string-typed module method wedges the
  logoscore CLI call** — no error, no coercion. Pass JSON-valued strings via
  `@argfile` (the scenarios' `argfile` helper).
- **Two timeout layers, and the seam's is usually binding.** The bridge's lp
  timeouts mirror the module's internal legs (membership `provider.rs`: reads
  70s, register submit 190s); the seam's per-op budget (95s registry read /
  10s local) normally fires first, and a late completion is then dropped by
  `rlnconsumer_rln_response` (rc 1).
- **`subscribeEvents` is explicit, and must run before `registerMembership`.**
  Acquiring the event source blocks the dispatch thread for the transport's
  full timeout when liblogos_rln_module is not loaded, so only a scenario that
  loads the RLN stack calls it; a late subscribe can miss the transition.
- **A proof from a freshly-activated membership can validate `invalid` — not
  `not_ready` — until its root reaches the validator's window.** The module
  softens this (0.6.1): a root miss triggers a rate-limited background window
  refresh and the prover adopts the fresh root at generate time, so the race
  usually resolves on the next retry (~a provider round-trip). The consumer
  owns that one retry: treat a first `invalid` for a just-activated registrant
  as retryable before declaring spam/drop (the `delivery-rln` send leg models
  exactly this).
- **A validator node's module needs a live registry provider.** The root
  window is fed by registry reads (lez_core with an OPEN wallet in this
  stack); without one the window stays permanently cold and every
  `validate_proof` answers `not_ready`.

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
`getEpochQuota(timestampSec)`, `subscribeEvents`, plus selftest probes
`ping` / `slowPing`.
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
