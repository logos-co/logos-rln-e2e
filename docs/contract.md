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
| `DELIVERY_LGX` | delivery bundle — resolved only when the scenario's `NEEDS_MODULES` includes `delivery_module`; `DELIVERY_MODULE_CHECKOUT` / `LOGOS_DELIVERY_CHECKOUT` build it from working trees (see `harness/artifacts.sh`) |
| `CONSUMER_LGX` | nim_rln_consumer bundle — resolved only when `NEEDS_MODULES` includes `nim_rln_consumer`; built from the in-repo `nim-rln-consumer/` path subflake (the working tree is the pin — no checkout knob) |
| `LIBP2P_LGX` / `GIFTER_LGX` | libp2p_module / rln_gifter_module bundles (consumer-gifter) — env override, else built from `LIBP2P_MODULE_CHECKOUT` / `GIFTER_CHECKOUT` (`nix build <checkout>#lgx`). Not pinned in this flake yet: the gifter needs its register-target fix branch (post-rename `register_member` lives on liblogos_lez_rln_module) |
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
| `E2E_FUNDING` | `faucet` \| `wallet-key` |
| `E2E_CONFIRM_TIMEOUT_S` / `E2E_POLL_INTERVAL_S` | on-chain confirmation budget (local 120/5, testnet 600/10) |
| `E2E_EPOCH_SIZE_SEC` | RLN epoch size passed to `start` (local 60, testnet 600) |
| `E2E_ROOT_WINDOW_TIMEOUT_S` | `validate_proof` root-window retry budget (local 60, testnet 120) |

## Target inputs (caller → target)

| var | meaning |
|---|---|
| `E2E_DEVNET` | local only: `host` (default — run lez-rln's `dev.sh`) \| `external` (attach to a running sequencer) |
| `E2E_LOCAL_PROFILE` | local only: provision-input profile under `profiles/` (default `local-default` — pinned tree + adopted wallet, so the deployment repeats across runs) \| `fresh` (random tree, fresh wallet) |
| `E2E_PROVISION_FUNDING`, `E2E_CLAIM_CAP`, `E2E_REGISTRAR`, `E2E_FREE_QUOTA` | local only: provision policy passed to lez-rln `provision.sh` (`--funding`/`--claim-cap`/`--registrar`/`--quota`); defaults: faucet, tool defaults |
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

## Harness primitives

Sourced from `harness/lib/`: `node_call <node> <module> <method> [args…]` is
the topology seam — identical whether the node is a host process or a
container. Event-driven modules (delivery) get `node_watch_start <node>
<module>` (attach a `logoscore watch` stream before the triggering call) and
`node_wait_event <node> <module> <event> [timeout] [substring]`. `node_logs`,
wallet/chain helpers, JSON plumbing: see each lib file's header.
