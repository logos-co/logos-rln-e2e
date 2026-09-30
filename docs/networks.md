# Hosted networks: funding, provisioning, presets

`--target devnet` and `--target testnet` run the scenarios against a hosted
LEZ zone whose RLN programs are already provisioned. Nobody on it has genesis
powers, so native balance takes the one road there is: a bedrock faucet drip,
bridged into the zone by a channel deposit from a bedrock node you run.

All of it is one command per network:

```sh
bash tools/network/provision.sh networks/devnet.env          # all steps
bash tools/network/provision.sh networks/devnet.env status   # where it stands
```

## On a new machine

The registry is already provisioned — `deployments/devnet-z2/deployment.json`
is committed — so a new machine only needs a funded payer of its own:

1. Build the logos-lez-rln host binaries once:
   `cd ../logos-lez-rln/lez-rln && cargo build --release --bin mint_payer --bin fund_account`.
2. `bash tools/network/provision.sh networks/devnet.env` — starts a bedrock
   node, mints your payer, claims from the faucet, deposits into the zone and
   waits for it to land (~1 h; re-run to resume if interrupted), then
   **adopts** the committed deployment: it writes a local copy of the
   descriptor naming your payer beside your wallet, and leaves the committed
   one alone.
3. `./run.sh register --target devnet` (or `keystore`, `live-registry`,
   `delivery-rln`, `delivery-rln-soak`, `delivery-cli`).

Your wallet holds real devnet funds; it never leaves
`~/.local/share/logos-rln-e2e/devnet/`.

## A network is a config file

`networks/<network>.env` holds the public values and nothing else — see
[`networks/devnet.env`](../networks/devnet.env):

| key | |
|---|---|
| `NETWORK` | state dir name, e2e target name, and the CAIP-2 reference in registry ids (`logos:<NETWORK>:<config hex>`) |
| `DEPLOYMENT` | descriptor name under `deployments/`; the target's default `E2E_DEPLOYMENT` |
| `LEZ_SEQUENCER`, `LEZ_INDEXER`, `LEZ_CHANNEL` | the zone |
| `BEDROCK_RELEASE`, `BEDROCK_PEERS` | the logos-blockchain node release and its bootstrap peers (from the release notes) |
| `FAUCET_URL` | `POST <url>/<zk key hex>` pays 1e12 to that key, 5 min cooldown |
| `DEPOSIT_AMOUNT`, `PAYER_MIN` | deposit this much whenever the payer holds less than that |
| `RLN_EPOCH_SIZE_SEC` | epoch the deployment is used with (600 — logos-delivery's EVM-era `twn` value) |

For testnet: copy `devnet.env` to `networks/testnet.env`, set `NETWORK=testnet`,
a `DEPLOYMENT` name and the testnet endpoints, peers, faucet and release, then
run the same command.

## What the steps do

Each step checks before it acts, so a re-run resumes rather than repeats.

1. **node** — downloads the bedrock node release for this platform,
   `init-config` with the peers (HTTP on `127.0.0.1:8080`), starts it and waits
   for `Online`. The faucet key is the node wallet's first key.
2. **payer** — mints the LEZ payer offline (`mint_payer` from logos-lez-rln)
   into a wallet pointed at the zone.
3. **fund** — if the payer holds less than `PAYER_MIN`: claims from the faucet
   when the node's wallet is short, splits a note of exactly `DEPOSIT_AMOUNT`
   (a deposit spends whole notes), and `POST /channel/deposit` with the
   payer's 32-byte account id as metadata (`borsh(DepositMetadata)`). The zone
   credits it once the deposit is final on bedrock — about an hour — and does
   so even while the zone is not inscribing. An interrupted wait resumes on
   re-run; it never deposits twice.
4. **deploy** — if `deployments/<DEPLOYMENT>/deployment.json` is committed,
   adopts it with this machine's payer. Otherwise, once per network:
   `provision.sh` from logos-lez-rln on a fresh tree (deploys both programs,
   the treasury and the registry config — needs the guest binaries and
   `run_setup`/`derive_accounts` too), then copies the public `deployment.json`
   into this repo's `deployments/`. Commit that file. Never re-run
   provisioning on a tree: `run_setup` fails on an initialized one.
5. **presets** — prints the values a node needs to join this network's RLN:
   registry id, epoch size, sequencer, config account, tree id, and the entry
   a `LOGOS_DELIVERY_RLN_PRESETS` file (or a delivery preset) would carry.

## Where things live

Secrets stay out of the repo, under `~/.local/share/logos-rln-e2e/<network>/`
(`NETWORK_STATE`):

| path | |
|---|---|
| `bedrock/` | node binary, `user_config.yaml`, keystore, chain state, logs |
| `payer-wallet/` | the payer's wallet as minted |
| `deployments/<DEPLOYMENT>/storage.json` | the wallet `--target <network>` stages (`E2E_PAYER_WALLET` overrides) |
| `state.json` | faucet key, payer id, a pending deposit |

`bash tools/network/provision.sh networks/<network>.env stop` stops the node;
it is only needed again for the next top-up.

## Running

```sh
./run.sh register --target devnet
```

The target stages `deployments/<DEPLOYMENT>/deployment.json` with the payer
wallet and funds each node 1e9 (`E2E_FUND_AMOUNT`); a registration reserves
~6.5e8, so one 5e11 deposit covers several hundred node-runs.

## Where the values go (testnet checklist)

A network's values become the node defaults in two places. Devnet is only in
the first; testnet goes in both, and `logos.test` is the only delivery preset
with RLN on.

1. `bash tools/network/provision.sh networks/testnet.env` — funds the payer,
   provisions, writes `deployments/<DEPLOYMENT>/deployment.json`. Commit it.
2. **logos-rln-modules** — the lez module's built-in network table, so a node
   needs no `LEZ_RLN_SEQUENCER`:
   `logos-lez-rln-module/tools/add-network.sh testnet <e2e>/deployments/<DEPLOYMENT>/deployment.json "<description>"`,
   then release the lez module.
3. **logos-delivery-module** — `src/rln_presets.cpp` `builtinPresets()`:
   `logos.test` gets `enabled = true` and the `presets` step's
   `registry_id` / `epoch_size_sec` (the registry id is
   `logos:testnet:<config account hex>`; the rln identifier stays the
   application default).
4. `./run.sh <scenario> --target testnet` with `E2E_WALLET_SOURCE=table` proves
   a node reaches the chain from the table alone.

## Needs

curl, jq, python3, and a logos-lez-rln checkout (`LEZ_RLN_CHECKOUT`, default
`../logos-lez-rln`) with release builds of `mint_payer`, `run_setup` and
`derive_accounts` plus the guest binaries — the same build `--target local`
uses.
