# Deployment profiles

One **deployment** = one on-chain RLN instance, fully captured by two files:

```
deployments/<name>/
  deployment.json   # tree_id + sequencer + program_ids + derived config + payment/supply + funding
  storage.json      # the wallet (holds payment/supply/token/treasury keypairs)
```

`tree_id` is the single source of truth: `config`/`tree_main`/`credit_*` are **derived**
from `(registration_program_id, tree_id)`; `payment`/`supply` are **pointers into the
wallet**. See the canonical docs at `logos-lez-rln/tools/deployments/README.md`.

The `funding` field is the deployment's immutable token-funding policy, and
orchestrate's fund step branches on it (staged as `/testnet/funding.txt`):

- **`faucet`** (`shared-faucet`, the default profile): the payment token is a
  program-owned PDA; the run budget is claimed via `claim_tokens` (capped
  per call) — no human mint key exists anywhere.
- **`wallet-key`** (`shared-5ade`, legacy): fixed wallet-owned definition; the
  budget is minted via `mint_tokens` with the definition key in the wallet.

## Tooling is shared, not duplicated

The deployment layer lives once, in **`logos-lez-rln/tools/deployments/`**
(`stage.sh` / `provision.sh` / `verify.sh` + the `derive_accounts` bin). This repo
does **not** submodule logos-lez-rln — the image clones it (pinned by commit in
`Dockerfile.testnet-e2e`) at build time. The deployment tooling it consumes two ways:

- `docker/testnet/stage.sh` — a **vendored copy** of the canonical `stage.sh` (bash+jq).
  It sits in the build context so `docker build` stays self-contained (the image has
  `jq`). Keep it in sync with the canonical copy.
- `docker/testnet/{provision,verify}.sh` — **thin shims** that `exec` the canonical
  scripts via `LEZ_RLN_DIR` (host-only; they need the Rust `run_setup`/`derive_accounts`).

## Run the sim against a deployment

```bash
docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=<name> -t lp2p-mix-e2e .
cd docker/testnet/mix_e2e && bash orchestrate.sh
```

`--build-arg DEPLOYMENT=` defaults to `shared-faucet`. The build runs `stage.sh`, which
asserts the wallet schema (rc6) and the wallet<->deployment binding (payment always,
supply only for wallet-key deployments — a faucet deployment's supply holder is a
program PDA no wallet holds) — a mismatched wallet fails the build, not a node at
runtime.

## Provision / verify (needs a logos-lez-rln checkout)

```bash
(cd "$LEZ_RLN_DIR/lez-rln" && PYO3_PYTHON=$(command -v python3) \
   cargo build --release --bin run_setup --bin derive_accounts)

# fresh tree + fresh wallet, written into this repo's deployments/ (faucet
# funding by default; --funding wallet-key / --claim-cap / --registrar / --quota
# select the deployment policy):
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh --name my-run

# reuse another sim's wallet (shared accounts across sims), specific tree:
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh \
  --name shared --tree <64hex> --adopt-wallet /path/to/other/storage.json

# guest-drift guard (re-derive from the actual guest binaries, diff the descriptor):
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/verify.sh docker/testnet/deployments/<name>
```
