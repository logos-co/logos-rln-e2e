# logos-rln-mix-sim

A reproducible, end-to-end simulation of **gifted RLN membership allocation over a
Sphinx mix network**, running real `logoscore` daemons against the hosted Logos
Execution Zone (LEZ) testnet.

Five nodes come up as a docker-compose stack. One node — the **gifter** — holds the
only funded wallet; it registers its own RLN membership and then serves a libp2p
membership-allocation protocol (`/logos/rln/membership/1.0.0`, [LIP-158]). The other
four nodes **authenticate with an EIP-191 signature and receive a distinct on-chain
RLN membership without ever funding or signing a transaction themselves.** Those
memberships are then exercised by sending an RLN-protected message through a 3-hop
Sphinx mix with a SURB reply, where spam protection is enforced **per hop on both
legs** ([LIP-144]) — which is exactly why every mix node has to be a member, and why
cheap, authenticated membership allocation matters.

[LIP-158]: https://lip.logos.co/anoncomms/raw/rln-membership-service.html
[LIP-144]: https://lip.logos.co/anoncomms/raw/mix-spam-protection-rln.html

## Quick start

Requires Docker running (~30 GB free in its VM), internet, and stock host tools
(`bash`, `git`, `python3`, `curl`, `rsync` — preinstalled on macOS and most Linux).
No toolchain, no manual keystores — the bootstrap fetches and builds everything.

```sh
git clone https://github.com/logos-co/logos-rln-mix-sim.git
cd logos-rln-mix-sim
bash docker/testnet/mix_e2e/bootstrap.sh   # clone 4 siblings + build .lgx + image (~30-45 min first run)
cd docker/testnet/mix_e2e
bash orchestrate.sh                        # gifted allocation + 3-hop RLN-over-mix delivery (~15 min)
docker compose down                        # tear down
```

The only runtime knob is the negative tests (both prove RLN gates delivery):

```sh
NEG=1 bash orchestrate.sh    # sender never asks the gifter -> rejected (0 replies)
NEG=2 bash orchestrate.sh    # sender's key not allowlisted -> gifter refuses auth
```

## What a pass looks like

- 5 distinct on-chain leaves (1 self-registered + 4 gifted), `leaf_opt == leaf_actual`,
  `confirmed=true`, `rlnIsReady=True` on every node.
- `relay1 gifter service mounted (/logos/rln/membership/1.0.0, allowlist=4 clients)`;
  relay1's log shows `RLN gifter registration succeeded` ×4; each client logs
  `RLN membership granted`.
- `sender->dest: 3/3` and `dest->sender: 3/3` replies received; ~36 per-hop RLN
  verifications; `VERDICT: PASS`.

## Trust model (LIP-158 trade-offs)

The gifter is a **membership provider / gatekeeper**, with the trade-offs that role
implies: it decides which commitments get registered and can refuse or stall any
request (`NEG=2` demonstrates the refusal path); sybil resistance is exactly the
auth policy and nothing more (here, the spec's demo mode — a static EIP-191
allowlist, one membership per address); and it fronts the funds and learns a
durable auth-identity↔commitment mapping — but never the RLN secret, so it cannot
forge client proofs. Client-IP↔identity correlation is deferred by the spec to RLN
Stealth Commitments. Spam enforcement itself is not provider-mediated: exceeding
`userMessageLimit` per epoch reuses a nullifier, letting any relay reconstruct the
offender's key and remove it from the group.

## What it builds on

`bootstrap.sh` clones four sibling repos next to this one over HTTPS (the mix stack
sits on adklempner forks pending upstreaming) and links them into one loadable
libp2p `.lgx`:

| repo | branch | role |
|---|---|---|
| [`logos-rln-gifter`](https://github.com/logos-co/logos-rln-gifter) | `master` | RLN membership gifter protocol (LIP-158) |
| [`logos-libp2p-module`](https://github.com/adklempner/logos-libp2p-module) | `rebase/enable-mix` | universal libp2p module (mix + RLN + gifter glue) |
| [`mix-rln-spam-protection-plugin`](https://github.com/adklempner/mix-rln-spam-protection-plugin) | `feat/cbind-rln` | RLN SpamProtection (LIP-144) |
| [`nim-libp2p-mix`](https://github.com/adklempner/nim-libp2p-mix) | `rebase/mix-cbind` | Sphinx mix (LIP-99) |

The image build additionally clones `logos-co/logos-lez-rln` (`main` pinned @
`4b403c1`) — which fetches the execution zone (lssa) at `v0.2.0-rc6` via its
flake — and bakes a **deployment profile** (RLN tree + wallet) into `/testnet`.

## Layout

```
docker/
  Dockerfile.testnet-e2e     # the runtime image (logoscore + wallet/rln modules + baked deployment)
  Dockerfile.lgx-linux       # builds the Linux libp2p .lgx from the 4 siblings
  build_lgx_linux.sh         # driver for the .lgx build
  testnet/
    stage.sh                 # bakes a deployment profile into /testnet at image build time
    provision.sh, verify.sh  # deployment-profile tooling (thin shims into logos-lez-rln)
    deployments/             # deployment profiles (default: shared-5ade)
    mix_e2e/                 # THE SIM
      bootstrap.sh           #   one-shot: clone siblings + build .lgx + build image
      orchestrate.sh         #   drives the 5 daemons (gifter + clients, mix exchange, verdict)
      docker-compose.yml     #   5 logoscore services on a shared bridge network
      entrypoint.sh, keys.py #   per-container setup + host-side key derivation
      fixtures/gifter_auth/  #   demo EIP-191 keys + allowlist (NOT for production)
```

## Docs

- [`docker/testnet/deployments/README.md`](docker/testnet/deployments/README.md) — deployment
  profiles (run-against-existing / redeploy-fresh, `provision.sh`/`verify.sh`).
