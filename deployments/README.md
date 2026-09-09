# Committed deployments

Each `deployments/<name>/` is a **testnet** deployment profile: an RLN tree
already provisioned on a hosted sequencer, committed so a run spends against a
known tree instead of re-provisioning one.

```
deployments/<name>/
  deployment.json   descriptor: name, tree_id, sequencer, registration_program_id,
                    merkle_program_id, config_account, payment_account,
                    supply_holding, funding (faucet|wallet-key)
  storage.json      the wallet holding payment_account (and, on wallet-key
                    deployments, supply_holding)
```

`--target testnet` requires `E2E_DEPLOYMENT=<name>` — there is no default: a
testnet run always names the tree it spends against. The target reads
`.sequencer` from the descriptor, asserts it answers `getLastBlockId`, and
stages the pair through logos-lez-rln's `tools/deployments/stage.sh` into the
run's wallet home; every other contract value (tree id, config account,
funding) comes out of that staged fixture.

The descriptor and its wallet are one unit: `stage.sh` fails when the wallet
does not hold the descriptor's accounts. Copy both files or neither.

`--target local` never reads this directory — it provisions a fresh tree per
run into `$E2E_RUN_DIR/deployments/local-e2e`.

## Committed

| name | state |
|---|---|
| `testnet-faucet-260908` | **live** — provisioned 2026-09-08 from logos-lez-rln main's guest, faucet-funded; `verify.sh` passes; `register --target testnet` PASS 2026-09-08 (ACTIVE at leaf 0, proof valid, tampered signal invalid) |
| `testnet-shrink-verify` | dead — the 2026-09 testnet reset (`getLastBlockId` back to ~600 on 2026-09-08) wiped every account it names; kept for history |
| `shared-faucet` | dead — same reset; kept for history |

A hosted-testnet reset empties every committed account at once, so a
`stage.sh` that passes against a dead descriptor still ends in a wallet that
never sees its `payment_account` funded. When `--target testnet` fails that
way on a descriptor that used to work, check the chain head before the
module: a head far below the descriptor's provisioning block means
re-provision (below), not a harness or module bug.

## Adding one

Provision against the hosted sequencer from a logos-lez-rln checkout, then
commit the pair:

```sh
cd <logos-lez-rln>
bash tools/deployments/provision.sh --name <name> \
    --sequencer https://testnet.lez.logos.co/ --funding faucet \
    --outdir <this-repo>/deployments
```

`funding=faucet` deployments are the paid `Register` path (anyone claims
tokens up to the deployment's cap). `wallet-key` deployments carry a
pre-minted supply in the committed wallet — a scenario that needs the faucet
must assert `E2E_FUNDING=faucet`.

Guest drift invalidates a descriptor: rebuilt guest binaries change the
program id, so the same `tree_id` derives a different `config_account`. Run
`bash <logos-lez-rln>/tools/deployments/verify.sh deployments/<name>` after a
guest bump; a failure means re-provision, not a chain bug.

The committed wallet is a test wallet on a test chain — treat any key in here
as public.
