# local-default — the deterministic local provision profile

Inputs `harness/targets/local.sh` feeds to lez-rln's `provision.sh` on every
host-mode local run (unless `E2E_LOCAL_PROFILE` says otherwise):

- `tree.txt` — the pinned RLN tree id (`--tree`). On LEZ v0.3.0 the
  registry's accounts are PDAs of the tree id and the registration
  program's header account, and provisioning takes the header accounts from
  the adopted wallet's key chain — so with this tree and the wallet below a
  fresh devnet lands the same deployment every run, and the registry id
  (`logos:local:<config-hex>`) is stable too.
- `wallet.storage.json` — the wallet seed adopted into provisioning
  (`--adopt-wallet`): same key chain, hence the same account ids and
  holdings across runs. Captured from a passing run's
  `wallet-home/storage.json.seed`.
  DEV FIXTURE: these keys are public in this repo; local chains only.

  It also carries the `rln-fee-payer` label. Every public transaction
  costs a fee and the faucet runs only in the genesis block, so
  the account that pays for provisioning has to be funded at genesis —
  before any of this exists. `mint_payer` returns the labelled account
  rather than minting a second one, so the payer is as stable as the rest
  of the key chain and `dev.sh` funds the same address every run.

  A wallet written before v0.2.5 cannot be adopted at all: it has no
  `authorization_secret_key` and the wallet refuses to parse it.

The registry is depth 9, so it holds 512 members. That is a cost ceiling,
not a design preference: LEZ meters a transaction by its gas limit at one
gas per cycle and refuses anything over ten million, and an on-chain merkle
insert costs about 902,000 cycles per level. A depth-10 tree misses the
ceiling by roughly eleven thousand cycles.

Regenerate (new tree or new keys): run any local scenario with
`E2E_LOCAL_PROFILE=fresh E2E_KEEP=1`, then copy the run's
`wallet-home/storage.json.seed` here as `wallet.storage.json` and the
`LEZ_RLN_TREE_ID_HEX` value from `wallet-home/env.sh` into `tree.txt`.
The seed is what `stage.sh` writes, so it already has the synced state
zeroed and the payer label kept.
