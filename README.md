# logos-rln-mix-sim

A reproducible, end-to-end simulation of **gifted RLN membership allocation over a
Sphinx mix network**, running real `logoscore` daemons against the hosted Logos
Execution Zone (LEZ) testnet.

Five nodes come up as a docker-compose stack. One node — the **gifter** — is the
only spender: it mints the run's RLNTOK budget into a fresh per-run payment
account (the deployment wallet carries the test token's mint authority, so every
run funds itself — no fixed pool to drain), registers its own RLN membership, and
then serves a libp2p membership-allocation protocol
(`/logos/rln/membership/1.0.0`, [LIP-158]). The other
four nodes **authenticate and receive a distinct on-chain RLN membership without
ever funding or signing a transaction themselves** — three with an EIP-191
signature against a static allowlist, and one (`dest`) by proving it holds a
**genuine Keycard**: an IDENTIFY_CARD attestation bound to its identity
commitment, one gifted membership per physical card (synthetic cards by
default; a real Status Keycard with `KEYCARD=real`). Those
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

Runtime knobs:

```sh
NEG=1 bash orchestrate.sh    # sender never asks the gifter -> rejected (0 replies)
NEG=2 bash orchestrate.sh    # sender's key not allowlisted -> gifter refuses auth
NEG=3 bash orchestrate.sh    # valid attestation, keycard auth NOT mounted -> refused
KEYCARD=0 bash orchestrate.sh      # legacy all-EIP-191 run (no keycard auth)
KEYCARD=real bash orchestrate.sh   # dest onboards with a PHYSICAL Status Keycard (below)
KEYCARD_CLAMP=1 bash orchestrate.sh    # extra: a rate-600 keycard grant is clamped to 100
KEYCARD_PERSIST=1 bash orchestrate.sh  # extra: consumed cards survive a gifter restart
```

The default run already exercises keycard auth end to end: the gifter mounts
**both** auth methods, `dest` (dropped from the allowlist — the card alone must
suffice) onboards via a synthetic attestation minted with a throwaway CA
(`fixtures/gifter_auth/keycard.env` +
`logos-rln-gifter/tools/mint_attest.py`), and four auth-refusal probes run
inline: card reuse, untrusted CA, wrong commitment binding, garbage TLV.

## What a pass looks like

- 5 distinct on-chain leaves (1 self-registered + 4 gifted), `leaf_opt == leaf_actual`,
  `confirmed=true`, `rlnIsReady=True` on every node.
- `relay1 gifter service mounted (/logos/rln/membership/1.0.0, allowlist=3 clients + keycard CA)`;
  relay1's log shows `RLN gifter keycard attestation auth enabled` and
  `RLN gifter registration succeeded` ×4 (3 eth + 1 keycard); each client logs
  `RLN membership granted`; `dest onboarding via keycard attestation`.
- All four keycard probes report `OK (refused: ...)`, and dest's card nullifier
  lands in the gifter's `consumed_nullifiers.txt`.
- `sender->dest: 3/3` and `dest->sender: 3/3` replies received; ~36 per-hop RLN
  verifications; `VERDICT: PASS`.

## Trust model (LIP-158 trade-offs)

The gifter is a **membership provider / gatekeeper**, with the trade-offs that role
implies: it decides which commitments get registered and can refuse or stall any
request (`NEG=2`/`NEG=3` demonstrate the refusal paths); sybil resistance is
exactly the auth policy and nothing more (here, two coexisting policies: the
spec's demo mode — a static EIP-191 allowlist, one membership per address — and
keycard attestation — one membership per genuine card, keyed by the card's
burned-in identity key, so even a factory reset cannot re-claim); and it fronts
the funds and learns a
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
| [`logos-rln-gifter`](https://github.com/logos-co/logos-rln-gifter) | `feat/keycard` | RLN membership gifter protocol (LIP-158) + keycard attestation auth |
| [`logos-libp2p-module`](https://github.com/adklempner/logos-libp2p-module) | `feat/on-demand-roots` | universal libp2p module (mix + RLN + gifter glue) |
| [`mix-rln-spam-protection-plugin`](https://github.com/adklempner/mix-rln-spam-protection-plugin) | `feat/on-demand-roots` | RLN SpamProtection (LIP-144) |
| [`nim-libp2p-mix`](https://github.com/adklempner/nim-libp2p-mix) | `feat/on-demand-roots` | Sphinx mix (LIP-99) |

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
    deployments/             # deployment profiles (default: shared-faucet)
    mix_e2e/                 # THE SIM
      bootstrap.sh           #   one-shot: clone siblings + build .lgx + build image
      orchestrate.sh         #   drives the 5 daemons (gifter + clients, mix exchange, verdict)
      docker-compose.yml     #   5 logoscore services on a shared bridge network
      entrypoint.sh, keys.py #   per-container setup + host-side key derivation
      fixtures/gifter_auth/  #   demo EIP-191 keys + allowlist + synthetic keycard keys (NOT for production)
```

## Real-card demo (`KEYCARD=real`)

`dest` onboards with a **physical Status Keycard**: the run derives dest's
identity commitment, prints the bound challenge
(`SHA256("logos/rln/keycard-attest/1" || id_commitment)`), captures an
IDENTIFY_CARD attestation over PC/SC, and the gifter verifies it against the
pinned **Status production CA**
(`029ab99ee1e7a71bdf45b3f9c58c99866ff1294d2c1e304e228a86e10c3343501c`).

Prerequisites: a PC/SC smart-card reader with the card present, and the
`kc-capture` tool from the rln-zone experiment
(`rln-zone/logos-rln-stealth/keycard/capture`, `build.sh`; path overridable via
`KC_CAPTURE`). **No pairing, PIN or password is involved** — IDENTIFY_CARD is a
public applet command (that is what makes genuineness publicly checkable);
holding the card is the credential.

```sh
KEYCARD=real bash orchestrate.sh   # captures automatically; without a built
                                   # kc-capture it prints the exact command
                                   # and prompts you to paste the TLV
```

If the rln-zone `keycard-rln` binary is built, the TLV is pre-verified offline
(wrong card/pairing fails fast, and the exact nullifier is asserted in the
observe step). Notes: each run recreates the gifter, so the same card can
re-claim across runs — the one-shot guard is per gifter instance
(`KEYCARD_PERSIST=1` demonstrates it surviving a restart *within* one stack);
the inline reuse/wrong-binding probes replay dest's own TLV, so no second tap
is needed; the rate-clamp extra stays synthetic-only (it needs a second card
signed by the mounted CA).

## Docs

- [`docker/testnet/deployments/README.md`](docker/testnet/deployments/README.md) — deployment
  profiles (run-against-existing / redeploy-fresh, `provision.sh`/`verify.sh`).
