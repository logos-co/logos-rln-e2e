# The harness contract

`run.sh` resolves artifacts, sources the target, and hands the scenario's
`run.sh` a fully provisioned environment. Scenarios consume **only** this
contract (plus `harness/lib/*.sh`); targets produce it. If a scenario needs
something the contract doesn't carry, fix the contract — don't grow a side
channel.

## Set by run.sh

| var | meaning |
|---|---|
| `E2E_SCENARIO` | scenario id |
| `E2E_TARGET` | `local` \| `testnet` \| `none` |
| `E2E_RUN_DIR` | per-run scratch dir (`runs/<ts>-<scenario>-<target>`) |
| `E2E_KEEP` | `1` = leave chain/daemons/state up for debugging |

## Set by harness/artifacts.sh

| var | meaning |
|---|---|
| `LOGOSCORE` | logoscore binary |
| `WALLET_LGX`, `LEZ_RLN_LGX`, `RLN_LGX` | module bundles (each overridable by pre-setting the env) |
| `DELIVERY_LGX` | delivery bundle — resolved only when the scenario's `NEEDS_MODULES` includes `delivery_module`. Env override, else `DELIVERY_MODULE_CHECKOUT` / `LOGOS_DELIVERY_CHECKOUT` build it from working trees, else **the flake pin** (`delivery-module` v0.3.0-rc.2, prebuilt in the logos cache) — so no checkout is needed for a released rev |
| `CHAT_LGX` | chat_module bundle (the chat-basecamp scenarios) — env override, else built from `CHAT_MODULE_CHECKOUT`. **Not pinned in this flake yet**, so one of the two is required |
| `LIBP2P_LGX` / `GIFTER_LGX` | libp2p_module / rln_gifter_module bundles (the gifter path) — env override, else built from `LIBP2P_MODULE_CHECKOUT` / `GIFTER_CHECKOUT` (`nix build <checkout>#lgx`). Not pinned in this flake yet: the gifter needs its register-target fix branch (post-rename `register_member` lives on liblogos_lez_rln_module) |
| `BASECAMP_APP` | the Basecamp binary a `NEEDS_APPS=basecamp` scenario launches — env override, else `nix build .#app` from `BASECAMP_CHECKOUT`, else `$E2E_BASECAMP_PIN#app`. It must be the **non-portable dev `#app`** build: the QML inspector is compiled in and only that build appends the `-dev` variant liblogos needs to load harness-built bundles |
| `E2E_BASECAMP_PIN` | logos-basecamp flake ref `BASECAMP_APP` falls back to (default: the 0.3.0 rev). Deliberately not a flake input — basecamp's own lock is ~10k nodes, which would about double this repo's and slow every evaluation, including scenarios that never launch the app |
| `E2E_MODULES_DIR` | flattened module dir daemons load from |

The `none` target exports nothing below — it stands up no chain. Scenarios
that preflight chain vars fail fast under it by design.

## Set by the target (harness/targets/<target>.sh)

| var | meaning |
|---|---|
| `E2E_SEQUENCER` | chain JSON-RPC endpoint |
| `E2E_DEPLOYMENT_DIR` | dir with `deployment.json` + `storage.json` |
| `E2E_WALLET_HOME` | staged wallet-home fixture (lez-rln `stage.sh` output) |
| `E2E_TREE_ID` | RLN tree id (64 hex) |
| `E2E_CONFIG_ACCOUNT` | registry config account (base58) |
| `E2E_PAYER` | the account that signs a registration, pays its price in NATIVE balance and pays its fee — one account does all three. Local mints it before genesis; testnet reads `payer_account` from the descriptor |
| `E2E_CONFIRM_TIMEOUT_S` / `E2E_POLL_INTERVAL_S` | on-chain confirmation budget (local 120/5, testnet 600/10) |
| `E2E_EPOCH_SIZE_SEC` | RLN epoch size passed to `start` (local 60, testnet 600) |
| `E2E_ROOT_WINDOW_TIMEOUT_S` | `validate_proof` root-window retry budget (local 60, testnet 120) |

## Target inputs (caller → target)

| var | meaning |
|---|---|
| `E2E_DEVNET` | local only: `host` (default — run lez-rln's `dev.sh`) \| `external` (attach to a running sequencer) |
| `E2E_LOCAL_PROFILE` | local only: provision-input profile under `profiles/` (default `local-default` — pinned tree + adopted wallet, so the deployment repeats across runs) \| `fresh` (random tree, fresh wallet) |
| `E2E_FUND_AMOUNT` | native balance `wallet_fund` sends a node's own payer (default 5e9). The fee RESERVE (~6.5e8 per transaction) dominates the registry price (~1e6), so size this from the reserve or the account cannot transact |
| `E2E_DEVNET_TIMEOUT_S` | local/host: devnet readiness budget (default 900 — first boot cargo-builds the sequencer) |
| `LEZ_RLN_CHECKOUT` | lez-rln working tree for dev.sh + provisioning (default `../logos-lez-rln`; must have host bins + guest blobs built) |
| `E2E_DEPLOYMENT` | testnet only, required: name of a committed descriptor under `deployments/` |
| `E2E_DEPLOYMENT_DIR` | local/external only: reuse an existing provisioned deployment (refused under `E2E_DEVNET=host` — dev.sh wipes the chain) |

Scenario-specific knobs (e.g. `register`'s `E2E_RATE_LIMIT`) are documented in
the scenario's header, never invented in the harness.

### Known local-vs-testnet gaps

The local target is a standalone (mock) sequencer; two behavioral gaps mean
testnet stays a first-class target rather than a fallback:

- **Chain time**: the standalone sequencer leaves the `CLOCK_50` account at
  zero, so anything clocked by chain time (membership pending windows,
  expiry/renewal) is not faithfully exercised locally. The live-registry
  clock test runs only against testnet.
- **Block size**: local debug config caps blocks at 1 MiB; the real testnet
  cap is under ~459 KB, and oversized program deploys vanish silently there.

## scenario.env

Each `scenarios/<id>/scenario.env` declares: `NODES` (daemon count),
`NEEDS_MODULES` (runtime lib names, space-separated), `TARGETS` (supported
targets), `RUNNER` (`bash`; `pytest`/`compose` arrive with the delivery and
mix phases), optional `STATUS=quarantined`.

## Scenario conventions

`rln_identifier` scopes the **application**, not the member. It feeds the
external nullifier the sender and every validator derive independently, so
every node in a scenario must be configured with the *same* one — derive it
once at the top of `run.sh` and interpolate that variable everywhere. A
per-node identifier does not fail loudly: the proof verifies against the wrong
external nullifier and the message is simply rejected
(`validatorRes=Reject`), which is indistinguishable from a real RLN fault.
`delivery-rln` additionally asserts the module echoes the configured value back
in `rlnGetMembershipStateRequest`.

## Harness primitives

Sourced from `harness/lib/`: `node_call <node> <module> <method> [args…]` is
the topology seam — identical whether the node is a host process or a
container. Event-driven modules (delivery) get `node_watch_start <node>
<module>` (attach a `logoscore watch` stream before the triggering call),
`node_wait_event <node> <module> <event> [timeout] [substring]` and
`node_watch_stop <node> <module>`.

`daemon_self_paying <node> <dir>` gives a node a wallet of its **own**: the
staged `wallet_config.json` and nothing else, so the registry module creates a
fresh wallet there, derives a payer only that node holds, and publishes it
through `wallet_status` for `wallet_fund` to send to. It withholds
`storage.json` deliberately — derivation is deterministic from the seed, so
nodes sharing a staged wallet derive the SAME account and "its own payer" is a
fiction. It also withholds `LEZ_RLN_PAYER`, since a node handed the
deployment's shared payer would spend one balance and race one nonce.

`daemon_wallet_home <node> <dir>` is the lower-level form — any home, no
implications — and both **must be called before `daemon_start`** — the registry module reads the home from
the daemon's environment at load, and nothing re-reads it afterwards. Every
node past the first needs one: since `liblogos_lez_rln_module` 3.0.0 the
module owns its wallet in-process, so two nodes on one `storage.json` are two
writers of one file. Copy the whole staged home, including `storage.json`;
dropping it does not reseed from `storage.json.seed`, it yields a wallet with
no payer.

A `node_wait_event` match **consumes** it: the read cursor for that (node,
module, event) advances past the line returned, so waiting twice for the same
event waits for the *next* occurrence rather than re-matching the first. An
event that arrived before the wait started still matches — that race is
deliberate — and cursors are per event name, so waiting for one event never
skips another's backlog. Watchers are reaped by `node_watch_stop`,
`daemon_stop` and `daemon_stop_all` (including under `E2E_KEEP=1`, which keeps
daemons up but not watch processes); once reaped, a further `node_wait_event`
on that watcher dies rather than polling a file nobody writes. `node_logs`,
wallet/chain helpers, JSON plumbing: see each lib file's header.

`harness/lib/fault.sh` degrades **one node's** chain RPC on purpose, for
scenarios that ask how a node behaves against a hosted testnet's bad days.
`fault_up` starts `harness/tools/faultproxy.py` between that node's wallet and
the sequencer; `fault_point_node <node>` rewrites `sequencer_addr` and every
`sequencers[].sequencer_addr` in its `wallet_config.json` (the only thing that
re-points the wallet — the module will not honour `LEZ_RLN_SEQUENCER` over an
existing config, and this must run after `daemon_self_paying` and before
`daemon_start`); `fault_mode <mode> [method-glob]` switches the fault mid-run
between `pass`, `refuse`, `blackhole`, `delay:<ms>` and `error5xx`, scoped to
matching JSON-RPC methods when a glob is given. Only the named node is
degraded — `chain_head` and the wallet/funding helpers keep dialling
`$E2E_SEQUENCER` directly, so a scenario can still observe and fund during an
outage it induced. `fault_trace_count [method]` and `fault_trace_path` read the
request trace the proxy writes in every mode, which is also how a run reports
what it cost in chain RPC.
