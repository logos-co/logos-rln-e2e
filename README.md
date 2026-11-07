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
| `delivery` | scaffold | 3-daemon co-residency (RLN module stack + delivery_module in one process) and 3-node static-peer relay propagation, chainless (`--target none`); grows RLN-gated delivery once logos-core wires RLN-on-LEZ into it |
| `delivery-rln` | **active** | the real logos-delivery RLN integration end to end: bring-up via delivery's config surface, real registration on chain, proof-gated relay n1→n2, negative control (tampered message NOT delivered). **Delivery devs start at [docs/delivery-integration.md]** |
| `delivery-cli` | **active** | the operator's own path: a released `logosctl` as daemon and installer, the RLN modules installed by name from the published catalog, delivery from the pin built portable. Funds the account the node names, lets it register itself, and asserts the send carried a proof. The peer runs the flake pins, so it is also a published-stack→main-stack interop check |
| `delivery-rln-reuse` | **active** | delivery-rln's proof path on a membership already on chain: n1 restores it from the membership vault (`E2E_REUSE_VAULT`) and sends, n2 holds none and validates; the witness negative control as in delivery-rln. No funding, no registration, no transaction. |
| `delivery-rln-soak` | **active** | the same two nodes under sustained load: both send across several RLN epochs, each deliberately past its per-epoch budget. Asserts exact slot accounting and lossless delivery; reports send→peer-validated and send→propagated latency, proof-attempt amplification, and what becomes of an over-quota message |
| `keystore` | active | the RLN module's keystore custody modes (module-owned default, opt-out) |
| `delivery-two-registries` | **active** | the delivery module over one backend serving both trees: Relay RLN on the delivery tree from the preset (`manage-backend: false`), native Mix on the mix tree from the host's `start()` at 10 s; memberships provisioned on both, a proof-gated relay send n1→n2, and a control node whose backend has the mix tree at 600 s fails its Mix start |
| `two-registries` | **active** | each registry's config carries its own rate-limit range (delivery 100..=600, mix 20..=100: `profiles/local-default/registry-*.env`), out-of-range rates are refused per registry; one `liblogos_rln_module` holding memberships in two registries on one chain at different epochs — the delivery tree (600 s) and the mix tree (10 s): one `start()` for both, a membership on each, proofs valid on their own registry and invalid across, M's quota resets while D's holds, D's nullifier log survives M's pruning, a later `start()` naming only D leaves M at 10 s |
| `delivery-relay-rln` | **active** | the shipping topology: two RLN-gated peers that never dial each other, meeting at a containerised relay that holds its own membership and validates what it forwards |
| `delivery-rln-gifter` | **active** | RLN membership by allocation (delegated registration) without chat or Basecamp: a never-funded delivery node gets its membership from a node running `rln_gifter_module` (an open gifter that pays from its own payer), the gifter's balance drops by the price plus fee while the node's stays 0, and the gifted membership proves a delivery message to a third node. Needs `LIBP2P_LGX`/`LIBP2P_MODULE_CHECKOUT` and `GIFTER_LGX`/`GIFTER_CHECKOUT` |
| `rln-allocator` | **active** | a third-party membership allocator on chain: a gifter with a persisted libp2p key and an eth-allowlist verifier registers signed requests (`rln_gifter_module.request`), refuses a non-allowlisted key at no cost, keeps its PeerId and its spent credentials across a daemon restart, and pays for exactly what it grants; plus a client asking for a registry the gifter does not serve (pending -> failed after the 300 s window). Needs `LIBP2P_LGX`, `GIFTER_LGX` (>= 0.3.0), `ETH_AUTH_LGX` and foundry's `cast` |
| `membership-ui-gifter` | **active** | the RLN membership UI (`rln_membership_ui`) mounts in headless Basecamp with its six declared deps; the delegated registration its eth options drive (rate 100, eth-allowlist via `eth_sign_module`) is paid by an allocator, and a different allowlist refuses the module's key. Tier 2 reaches the UI's `flowController` through the inspector object tree (non-blocking). |
| `chat-basecamp-rln` / `chat-basecamp-gifter` / `delivery-basecamp-rln` | active | the stack inside Basecamp's embedded core, where it actually ships: proof-gated chat, gifted membership through the allocation protocol, and the delivery plugin loaded with no consumer app |
| `delivery-basecamp-pair` | **active** | two Basecamp instances and no daemon at all: both halves of the RLN path inside an embedded core, each app provisioning its own membership and paying from its own derived account. `--keep` leaves both up for hands-on work |
| `mix` | quarantined | gifted membership allocation ([LIP-158]) + per-hop RLN over a 3-hop Sphinx mix ([LIP-144]) |

```sh
./run.sh --list
./run.sh register --target local     # boots a local sequencer, provisions a fresh RLN tree
./run.sh register --target testnet   # runs against a committed testnet deployment
./run.sh register --target devnet    # LEZ devnet zone 2 — fund a payer first (below)
./run.sh delivery --target none      # chainless: 3 daemons, module co-residency, relay mesh
./run.sh delivery-rln --target local # the logos-delivery RLN acceptance
```

**Working on logos-delivery's RLN integration?** Start at
[docs/delivery-integration.md] — the consumer contract plus the copy-paste
local and testnet one-liners for the `delivery-rln` acceptance scenario.

A scenario is `scenarios/<id>/{scenario.env,run.sh}` driven through the
harness contract (`docs/contract.md`); a target
(`harness/targets/{local,testnet,devnet,none}.sh`) stands up and provisions the
chain (`none` stands up nothing — for module-runtime-only scenarios).
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
- **`delivery-rln` / `delivery-rln-soak` / `delivery-relay-rln`**: nothing
  beyond the pins — the flake pins [logos-delivery-module] at an upstream
  `master` that carries its RLN bridge (and, through it, [logos-delivery]).
  Copy-paste quickstart: [docs/delivery-integration.md].
- **`--target devnet` / `testnet`**: a payer of your own funded on that
  network, once per machine — `bash tools/network/provision.sh
  networks/devnet.env` runs a bedrock node, claims from the faucet and bridges
  the drip into the zone (about an hour of waiting), then adopts the committed
  deployment with that payer. Needs the logos-lez-rln host binaries
  (`cd ../logos-lez-rln/lez-rln && cargo build --release --bin mint_payer
  --bin fund_account`). Details: [docs/networks.md].
- **docker** — the containerised relay (`delivery-relay-rln`,
  `tools/build-e2e-image.sh`) and the compose-topology scenarios (mix).

Platforms: darwin-arm64 and linux (x86_64/aarch64).

## Pinning

`flake.lock` is the compatibility matrix: the exact revisions of
logos-lez-rln, logos-rln-modules, logos-delivery-module and logoscore this
repo's scenarios are known to compose. Bumping the lock is the act of
declaring a new known-good set. Artifact resolution (env override → nix
build → staged-source build) is `harness/artifacts.sh`.

The dev loop is env-var checkout overrides — run any scenario against a
working tree without touching the lock:

```sh
RLN_MODULES_CHECKOUT=../logos-rln-modules        ./run.sh register --target local
DELIVERY_MODULE_CHECKOUT=../logos-delivery-module ./run.sh delivery --target none
LOGOS_DELIVERY_CHECKOUT=../logos-delivery         ./run.sh delivery --target none  # Nim lib: source build
```

The delivery overrides compose (set both to test a shim change against a
lib change). A `LOGOS_DELIVERY_CHECKOUT` tree must have its git submodules
checked out, and only pinned revs are prebuilt in the logos cache — a
changed Nim tree builds liblogosdelivery from source.

## Naming

The module stack was renamed on 2026-08-10 and two names **swapped meaning**
— read `docs/naming.md` before touching anything that mentions
`liblogos_rln_module`. `tools/check-naming.sh` guards the active tree.

## Layout

```
run.sh                  entrypoint: ./run.sh <scenario> --target <t>
flake.nix flake.lock    the pins (lez-rln, rln-modules, delivery-module, logoscore)
harness/
  artifacts.sh          binary/bundle resolution
  lib/                  shared primitives (json, lgx, daemon, wallet, chain,
                        delivery: the RLN-enabled delivery bring-up)
  targets/              local (sequencer lifecycle + provisioning) / testnet +
                        devnet (hosted networks)
  container/            Dockerfile.relay (the bootstrap relay image)
  lib/relay.sh          the relay container's lifecycle
scenarios/
  register/ keystore/ delivery/ delivery-rln/ delivery-rln-soak/
  delivery-relay-rln/
  *-basecamp-*/ live-registry/ mix/
deployments/            committed hosted-network descriptors (public ids only)
networks/               per-network public values (tools/network/provision.sh)
profiles/               committed local provision inputs (pinned tree + wallet)
docs/                   contract.md, naming.md, networks.md
tools/                  check-naming.sh, build-e2e-image.sh, network/provision.sh
```

[logos-lez-rln]: https://github.com/logos-co/logos-lez-rln
[logos-rln-modules]: https://github.com/logos-co/logos-rln-modules
[logos-delivery-module]: https://github.com/logos-co/logos-delivery-module
[logos-delivery]: https://github.com/logos-messaging/logos-delivery
[LIP-158]: https://lip.logos.co/anoncomms/raw/rln-membership-service.html
[LIP-144]: https://lip.logos.co/anoncomms/raw/mix-spam-protection-rln.html

## License

Dual-licensed under [MIT](./LICENSE-MIT) or
[Apache 2.0](./LICENSE-APACHE-v2), at your option.
[docs/delivery-integration.md]: docs/delivery-integration.md
[docs/networks.md]: docs/networks.md
