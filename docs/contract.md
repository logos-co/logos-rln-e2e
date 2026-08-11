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
| `E2E_TARGET` | `local` \| `testnet` |
| `E2E_RUN_DIR` | per-run scratch dir (`runs/<ts>-<scenario>-<target>`) |
| `E2E_KEEP` | `1` = leave chain/daemons/state up for debugging |

## Set by harness/artifacts.sh

| var | meaning |
|---|---|
| `LOGOSCORE` | logoscore binary |
| `WALLET_LGX`, `LEZ_RLN_LGX`, `RLN_LGX` | module bundles (each overridable by pre-setting the env) |
| `E2E_MODULES_DIR` | flattened module dir daemons load from |

## Set by the target (harness/targets/<target>.sh)

| var | meaning |
|---|---|
| `E2E_SEQUENCER` | chain JSON-RPC endpoint |
| `E2E_DEPLOYMENT_DIR` | dir with `deployment.json` + `storage.json` |
| `E2E_WALLET_HOME` | staged wallet-home fixture (lez-rln `stage.sh` output) |
| `E2E_TREE_ID` | RLN tree id (64 hex) |
| `E2E_CONFIG_ACCOUNT` | registry config account (base58) |
| `E2E_FUNDING` | `faucet` \| `wallet-key` |
| `E2E_CONFIRM_TIMEOUT_S` / `E2E_POLL_INTERVAL_S` | on-chain confirmation budget (local 120/5, testnet 600/10) |
| `E2E_EPOCH_SIZE_SEC` | RLN epoch size passed to `start` (local 60, testnet 600) |
| `E2E_ROOT_WINDOW_TIMEOUT_S` | `verify_proof` root-window retry budget (local 60, testnet 120) |

## Target inputs (caller → target)

| var | meaning |
|---|---|
| `E2E_DEVNET` | local only: `host` (default — run lez-rln's `dev.sh`) \| `external` (attach to a running sequencer) |
| `E2E_DEVNET_TIMEOUT_S` | local/host: devnet readiness budget (default 900 — first boot cargo-builds the sequencer) |
| `LEZ_RLN_CHECKOUT` | lez-rln working tree for dev.sh + provisioning (default `../logos-lez-rln`; must have host bins + guest blobs built) |
| `E2E_DEPLOYMENT` | testnet only, required: name of a committed descriptor under `deployments/` |
| `E2E_DEPLOYMENT_DIR` | local/external only: reuse an existing provisioned deployment (refused under `E2E_DEVNET=host` — dev.sh wipes the chain) |

Scenario-specific knobs (e.g. `register`'s `E2E_RATE_LIMIT`) are documented in
the scenario's header, never invented in the harness.

## scenario.env

Each `scenarios/<id>/scenario.env` declares: `NODES` (daemon count),
`NEEDS_MODULES` (runtime lib names, space-separated), `TARGETS` (supported
targets), `RUNNER` (`bash`; `pytest`/`compose` arrive with the delivery and
mix phases), optional `STATUS=quarantined`.

## Harness primitives

Sourced from `harness/lib/`: `node_call <node> <module> <method> [args…]` is
the topology seam — identical whether the node is a host process or a
container. `node_logs`, wallet/chain helpers, JSON plumbing: see each lib
file's header.
