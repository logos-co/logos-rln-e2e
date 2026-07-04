# Deployment profiles

One **deployment** = one on-chain RLN instance, fully captured by two files:

```
deployments/<name>/
  deployment.json   # tree_id + sequencer + program_ids + derived config + payment/supply
  storage.json      # the wallet (holds payment/supply/token/treasury keypairs)
```

`tree_id` is the single source of truth: `config`/`tree_main`/`credit_*` are **derived**
from `(registration_program_id, tree_id)`; `payment`/`supply` are **pointers into the
wallet**. See the canonical docs at `logos-lez-rln/tools/deployments/README.md`.

## Tooling is shared, not duplicated

The deployment layer lives once, in **`logos-lez-rln/tools/deployments/`**
(`stage.sh` / `provision.sh` / `verify.sh` + the `derive_accounts` bin). This repo
does **not** submodule logos-lez-rln — the image clones it (`main`, pinned by
commit) at build time. The deployment tooling it consumes two ways:

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

`--build-arg DEPLOYMENT=` defaults to `shared-5ade`. The build runs `stage.sh`, which
asserts the wallet schema (rc6) and the wallet<->deployment binding (payment/supply
present) — a mismatched wallet fails the build, not a node at runtime.

## Provision / verify (needs a logos-lez-rln checkout)

```bash
(cd "$LEZ_RLN_DIR/lez-rln" && PYO3_PYTHON=$(command -v python3) \
   cargo build --release --bin run_setup --bin derive_accounts)

# fresh tree + fresh wallet, written into this repo's deployments/:
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh --name my-run

# reuse another sim's wallet (shared accounts across sims), specific tree:
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh \
  --name shared --tree <64hex> --adopt-wallet /path/to/other/storage.json

# guest-drift guard (re-derive from the actual guest binaries, diff the descriptor):
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/verify.sh docker/testnet/deployments/<name>
```
