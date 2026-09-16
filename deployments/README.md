# Committed deployments

Each `deployments/<name>/` is a **testnet** deployment profile: an RLN tree
already provisioned on a hosted sequencer, committed so a run spends against a
known tree instead of re-provisioning one.

```
deployments/<name>/
  deployment.json   descriptor: name, tree_id, sequencer, registration_program_id,
                    merkle_program_id, config_account, payer_account,
                    treasury_account
  storage.json      the wallet holding payer_account
```

**This directory is empty, and that is deliberate.**

Registration became native-asset-only, which changed the registry guest
program. The config account is a PDA of `(registration_program_id, tree_id)`
and the program id derives from the guest ELF, so a new guest re-derives every
PDA of every tree. The three profiles that used to live here — `shared-faucet`,
`testnet-faucet-260908`, `testnet-shrink-verify` — addressed a program that no
longer exists, and their descriptors name `payment_account`, `supply_holding`
and `funding`: fields of a 296-byte config layout nothing can decode any more.
`stage.sh` refuses them by name, `verify.sh` by guest hash.

They were deleted rather than kept as history, because a deployment profile
that cannot be staged is not a record of anything — it is a trap for whoever
tries it next. `git log -- deployments/` has them.

`--target testnet` therefore has nothing to run against until a native-only
testnet deployment exists. That needs a payer funded in the new chain's genesis
block, which is the same external dependency that parked testnet runs already.

`--target local` never read this directory — it provisions a fresh tree per run
into `$E2E_RUN_DIR/deployments/local-e2e`, and is unaffected.

## Adding one

Provision against the hosted sequencer from a logos-lez-rln checkout, then
commit the pair:

```sh
cd <logos-lez-rln>
bash tools/deployments/provision.sh --name <name> \
    --sequencer https://testnet.lez.logos.co/ --payer <account-id>
```

`--payer` must already hold native balance on that chain: no program can mint
native, so it arrives at genesis, over the L1 bridge, or by transfer.

**Treat any key in here as public.** A committed `storage.json` used to carry
keys to test tokens with no value. It would now carry keys to an account
holding **native** balance — the same asset that pays every fee on the chain.
Fund such an account with only what a run needs.
