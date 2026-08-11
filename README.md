# logos-rln-e2e

End-to-end composition testing for RLN-on-LEZ. This repo pins the producer
repos — [logos-lez-rln] (chain: guest programs, sequencer + deployment
tooling) and [logos-rln-modules] (the module stack) — and runs cross-repo
scenarios against a real chain: a **local sequencer by default** (zero
external infra), the hosted testnet on request. Unit and hermetic tests stay
in the producer repos; what lives here is anything that needs two repos plus
a running chain.

Formerly `logos-rln-mix-sim`: the 5-node RLN-over-mix simulation is now one
scenario of several (currently quarantined — `scenarios/mix/STATUS.md`).

## Scenarios

| id | status | proves |
|---|---|---|
| `register` | in progress | full single-node membership lifecycle: faucet claim → register → merkle proof + registry cross-check → generate/verify proof (valid + tampered) |
| `live-registry` | planned | the registry-provider module's live-chain cargo tests against a provisioned deployment |
| `delivery` | planned | logos-delivery-module propagation; RLN-gated delivery once logos-core wires RLN-on-LEZ into it |
| `mix` | quarantined | gifted membership allocation ([LIP-158]) + per-hop RLN over a 3-hop Sphinx mix ([LIP-144]) — `docs/journeys/mix.md` |

```sh
./run.sh --list
./run.sh register --target local     # boots a local sequencer, provisions a fresh RLN tree
./run.sh register --target testnet   # runs against a committed testnet deployment
```

A scenario is `scenarios/<id>/{scenario.env,run.sh}` driven through the
harness contract (`docs/contract.md`); a target
(`harness/targets/{local,testnet}.sh`) stands up and provisions the chain.
The target is always a flag, never part of a scenario's name.

## Prerequisites

- **nix (flakes)** — logoscore and the module bundles build from the flake
  pins.
- Stock host tools: `bash`, `jq`, `python3`, `curl`, `openssl`, `rsync`,
  `tar` (preinstalled on macOS and most Linux; `nix develop` provides them
  too).
- **`--target local`**: a [logos-lez-rln] checkout (default
  `../logos-lez-rln`, override with `LEZ_RLN_CHECKOUT`) with the host
  binaries and risc0 guest blobs built — the target prints the exact build
  recipe when they are missing.
- **docker** — only for compose-topology scenarios (mix, later delivery).

Platforms: darwin-arm64 and linux (x86_64/aarch64).

## Pinning

`flake.lock` is the compatibility matrix: the exact revisions of
logos-lez-rln, logos-rln-modules and logoscore this repo's scenarios are
known to compose. Bumping the lock is the act of declaring a new known-good
set. Artifact resolution (env override → nix build → staged-source build) is
`harness/artifacts.sh`.

## Naming

The module stack was renamed on 2026-08-10 and two names **swapped meaning**
— read `docs/naming.md` before touching anything that mentions
`liblogos_rln_module`. `tools/check-naming.sh` guards the active tree.

## Layout

```
run.sh                  entrypoint: ./run.sh <scenario> --target <t>
flake.nix flake.lock    the pins (lez-rln, rln-modules, logoscore)
harness/
  artifacts.sh          binary/bundle resolution
  lib/                  shared primitives (json, lgx, daemon, wallet, chain)
  targets/              local (sequencer lifecycle + provisioning) / testnet
  container/            compose topology pieces (quarantined with mix)
scenarios/
  register/  live-registry/  delivery/  mix/
deployments/            committed testnet descriptors (local is per-run)
docs/                   contract.md, naming.md, journeys/<scenario>.md
tools/                  check-naming.sh
```

[logos-lez-rln]: https://github.com/logos-co/logos-lez-rln
[logos-rln-modules]: https://github.com/logos-co/logos-rln-modules
[LIP-158]: https://lip.logos.co/anoncomms/raw/rln-membership-service.html
[LIP-144]: https://lip.logos.co/anoncomms/raw/mix-spam-protection-rln.html

## License

Dual-licensed under [MIT](./LICENSE-MIT) or
[Apache 2.0](./LICENSE-APACHE-v2), at your option.
