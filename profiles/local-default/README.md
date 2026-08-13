# local-default — the deterministic local provision profile

Inputs `harness/targets/local.sh` feeds to lez-rln's `provision.sh` on every
host-mode local run (unless `E2E_LOCAL_PROFILE` says otherwise):

- `tree.txt` — the pinned RLN tree id (`--tree`). Everything on-chain
  derives from it: config account, payment account, supply holding are PDAs
  of tree id + guest blobs, so a fixed tree on a fresh devnet lands the
  same deployment every run. Registry id in scenarios becomes stable too
  (`logos:local:<config-hex>`).
- `wallet.storage.json` — the wallet seed adopted into provisioning
  (`--adopt-wallet`): same key chain, hence the same account ids and
  holdings across runs. Pure key material (no synced state, no labels) —
  captured from a passing register run's `wallet-home/storage.json.seed`.
  DEV FIXTURE: these keys are public in this repo; local chains only.

Determinism holds per lez-rln pin: rebuilt guest blobs re-derive a
different config account for the same tree (`verify.sh` guards that skew).
A provision-policy change (`E2E_PROVISION_FUNDING`, `E2E_CLAIM_CAP`,
`E2E_REGISTRAR`, `E2E_FREE_QUOTA`) redeploys the same tree under the new
policy — policy is immutable per deployment, mutable across devnet wipes.

Regenerate (new tree or new keys): run any local scenario with
`E2E_LOCAL_PROFILE=fresh E2E_KEEP=1`, then copy the run's
`wallet-home/storage.json.seed` here as `wallet.storage.json` and the
`LEZ_RLN_TREE_ID_HEX` value from `wallet-home/env.sh` into `tree.txt`.
