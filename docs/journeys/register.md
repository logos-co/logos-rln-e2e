# register — what a pass looks like

`./run.sh register --target local` on a darwin-arm64 laptop, nothing else
running, 2026-08-10. One command: boots a local sequencer, provisions a fresh
RLN tree, and drives a paid membership through the full module stack.

## The run, narrated

**Artifacts** (seconds, all from the flake pins):

```
== artifacts ==
e2e: pins consistent: lez-rln ff02e202cedb (rln-layouts + flake.lock)
e2e: bundles: logos-logos_execution_zone-module-lib.lgx, logos-liblogos_lez_rln_module-module-lib.lgx, logos-liblogos_rln_module-module-lib.lgx
```

The pin gate matters: if the rln-modules tree pinned `rln-layouts` at a
different lez-rln rev than the one deployed, chain-state decode skew would
present as phantom chain bugs. It fails loudly instead.

**Target** — a fresh chain and a fresh tree, every run:

```
e2e: timing: devnet-up 15s        # dev.sh, sequencer build cached
e2e: timing: provision 350s      # run_setup: programs + config + faucet PDA
e2e: timing: stage 0s
e2e: deployment: sequencer http://127.0.0.1:3040/, funding faucet
```

Provisioning dominates a cold run (~6 min); `E2E_DEVNET=external` plus
`E2E_DEPLOYMENT_DIR` skips both for the inner loop.

**The scenario** — registration is paid from a faucet claim (no gifter, no
pre-funded pool), and the price comes from the live bounds, not a constant:

```
== wallet ==
e2e: holding: 3d6d39a789a9866173c49a6b7b084cc487397a5402f8c5d7fd92b122f66026a6
e2e: claiming 2000000 RLNTOK from the faucet (rate 100 x price 10000 x2)

== registration ==
e2e: keystore unlocked
e2e: register(logos:local:98cee59d…, rate 100) via membership module
e2e: pending membership: 7a8217ad… (commitment 317ce6db326b77f0…)
e2e:   state poll 3: active
e2e: ACTIVE at leaf 0
e2e: get_merkle_proof returned a rooted proof
e2e: cross-check: rln module sees the membership (active)

== rate-limit proofs ==
e2e: proof issued (message_id 0, epoch 29773555)
e2e: epoch quota: remaining 99/100 in epoch 29773555
e2e: verify_proof: valid
e2e: tampered signal correctly invalid

e2e: PASS — registered on logos:local:98cee59d028f02cf72606efcf1008aa5c032df6930114b5284a59b926cf0b5a9
```

The registry id is `logos:${E2E_TARGET}:<config-account-hex>` — the target is
a flag; the same file, unchanged, runs `--target testnet` with the testnet
poll budgets from the contract.

## What it proves

- The three-module stack (`logos_execution_zone` →
  `liblogos_lez_rln_module` → `liblogos_rln_module`) loads and speaks the
  lidl wire in a logoscore daemon.
- The paid Register path end-to-end on chain: claim → register → active
  leaf → merkle proof, cross-checked between the two RLN modules.
- Proof crypto against live chain state: generate → quota decrement →
  verify valid → tampered-signal invalid.
- R2 (lp calls into a Rust module) and R4 (host-stamped persistence path)
  hold — their failure modes have dedicated diagnostics in the scenario.

## Knobs

`E2E_KEEP=1` leaves the devnet + daemon up for inspection. `E2E_RATE_LIMIT`
changes the registered rate (claim scales with it). `E2E_DEVNET=external`
attaches to your own sequencer. Budgets: `docs/contract.md`.
