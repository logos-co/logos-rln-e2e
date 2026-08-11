# Journey: gifted RLN membership allocation over a 3-hop mixnet (LEZ testnet)

## 1. Overview

### What the user achieves

A five-node docker-compose mixnet is running against the hosted LEZ testnet in
which one funded node (the gifter) registered its own RLN membership on-chain and
then allocated distinct on-chain memberships to the four other nodes — none of
which ever held funds or signed a transaction — proven by bidirectional
request/reply traffic through a 3-hop Sphinx mix with RLN spam protection
verified at every hop.

### Why it matters

Self-service RLN registration is a barrier to entry — it needs funds, gas, and
chain access, and links a user's network identity to their RLN identity — and
LIP-158 removes it: a membership provider registers the client's identity
*commitment* on the client's behalf without ever learning the client's secret, so
it cannot forge the client's proofs. This journey proves that primitive end to end
on live infrastructure (real sequencer transactions, nothing mocked), in the
setting that needs it most: a mixnet where every relay must be a member before it
can forward a single packet (LIP-144).

### Key components

All five nodes run the same `logoscore` daemon image (wallet + RLN + libp2p/mix
modules); their roles differ only in how the orchestrator drives them.

- **`relay1` — the gifter** — the sim's only spender: at setup it mints the
  run's RLNTOK budget into a fresh per-run payment account (the deployment
  wallet carries the test token's mint authority), registers its own RLN
  membership on-chain, then mounts the LIP-158 allocation service
  (`/logos/rln/membership/1.0.0`, EIP-191 allowlist) and funds + signs the
  registrations for the other four nodes, while also serving as a mix relay.
- **`relay2`, `relay3` — mix relays** — gifted clients whose job is forwarding:
  together with relay1 they form the 3-hop Sphinx paths, and each hop verifies
  the incoming RLN proof and regenerates a fresh one for the next hop — which is
  why relays need memberships at all.
- **`sender`, `dest` — traffic endpoints** — gifted clients that originate the
  bidirectional request/reply round-trips through the mix (one RLN proof per
  originated message); the sender is also the subject of the negative runs
  (unregistered / refused → zero delivery).
- **The hosted LEZ testnet** (external service, `https://testnet.lez.logos.co/`)
  — where the RLN group actually lives: registrations are real sequencer
  transactions that spend RLNTOK and grow the on-chain Merkle tree that every
  node's wallet syncs and every proof commits to.
- **The orchestrator** (`orchestrate.sh`, host-side) — drives all five daemons
  over `logoscore call`: per-node setup, the serialized registration barriers,
  mix meshing, the exchange, and the final verdict scraped from daemon logs.

## 2. Scope

### Repository

https://github.com/logos-co/logos-rln-mix-sim — branch `master`.
(Sibling repos and their branches are cloned automatically by `bootstrap.sh`;
see the README's "What it builds on" table.)

Runtime target: LEZ testnet v0.2.

### Prerequisites

- Linux or macOS with **Docker running** (compose v2 plugin; ~30 GB free in its
  VM — the image is ~17 GB).
- Host tools: `bash`, `git`, `python3` (stdlib only), `curl`, `rsync` — all
  preinstalled on stock macOS and most Linux distros.
- Outbound network to GitHub, the Nix caches, and the LEZ testnet RPC
  (`https://testnet.lez.logos.co/`). No offline mode.
- No accounts, keys, or toolchain — everything builds inside Docker. The
  checked-in EIP-191 fixtures are demo keys, **NOT for production**.

## 3. Happy path

### Commands and expected outputs

```sh
# 1. Clone and bootstrap (clone 4 sibling repos + build the .lgx + the image;
#    ~30-45 min first run, fast on re-runs)
git clone https://github.com/logos-co/logos-rln-mix-sim.git
cd logos-rln-mix-sim
bash docker/testnet/mix_e2e/bootstrap.sh

# 2. Run the full E2E (~15 min; the 5 sequential on-chain registrations dominate)
cd docker/testnet/mix_e2e
bash orchestrate.sh

# 3. Tear down
docker compose down
```

Real output of a passing run (peer IDs, leaf indices, and block heights vary per
run; section headers, log strings, counts, and the verdict are stable):

```text
=== up: 5 daemons (force-recreate for FRESH daemons) ===
  config=Ds9aBzioxnDf6yfUnCHGS7evBnpMnknyJgiMEJcV7uVG funding=faucet holding(funder)=<funded per-run by relay1>
=== per-node setup (load chain -> wallet+rln -> start -> mixSetNodeInfo -> peerInfo -> register) ===
  relay1 wallet synced to 11830
  funding: fresh per-run payment account (faucet, 6000000 RLNTOK)
  fresh account after 1 derivation(s): caf7618c01d4b0a44e8d32d7d9c40a750941aa5b5ca6a6079024474c92335bf4
  funded: payment=caf7618c01d4b0a44e8d32d7d9c40a750941aa5b5ca6a6079024474c92335bf4 balance=6000000
  relay1 peerId=16Uiu2HAkuXk...  leaf_opt=0 leaf_actual=0 confirmed=true rlnIsReady=True
  relay1 gifter service mounted (/logos/rln/membership/1.0.0, allowlist=4 clients)
  relay2 peerId=16Uiu2HAmMSF...  leaf_opt=1 leaf_actual=1 confirmed=true rlnIsReady=True
  relay3 peerId=16Uiu2HAmRzD...  leaf_opt=2 leaf_actual=2 confirmed=true rlnIsReady=True
  dest   peerId=16Uiu2HAm7if...  leaf_opt=3 leaf_actual=3 confirmed=true rlnIsReady=True
  sender peerId=16Uiu2HAm8nk...  leaf_opt=4 leaf_actual=4 confirmed=true rlnIsReady=True
=== mesh: every node adds the other 4 ===
  meshed.
=== rlnIsReady status (each node was confirmed ready before the next registered) ===
   relay1=True relay2=True relay3=True dest=True sender=True
=== register dest-read-behavior on all nodes (the SURB exit is random) ===
  registered (/ipfs/ping/1.0.0, READ_EXACTLY, 32 bytes)
=== exchange: 3 request/reply round-trip(s) per initiator ===
  sender->dest: 3/3 replies received
  dest->sender: 3/3 replies received
=== observe: RLN proofs (forward request + SURB reply legs) ===
  relay1: generated=10 verified=10 root_misses=0 refresh_recovered=0
  relay2: generated=10 verified=10 root_misses=0 refresh_recovered=0
  relay3: generated=10 verified=10 root_misses=0 refresh_recovered=0
  dest: generated=3 verified=3 root_misses=0 refresh_recovered=0
  sender: generated=3 verified=3 root_misses=0 refresh_recovered=0
  replies: sender->dest=3 dest->sender=3 ; total verifications=36 ; sender proofs=3
  gifter(relay1): 'RLN gifter registration succeeded' x4 (expect 4 in the happy path)
=== VERDICT ===
  PASS: every round-trip got a reply (sender->dest=3 dest->sender=3).
DONE (NEG=0)
```

**How to read it — each output section is one orchestration stage:**

1. **`up` + `config=…`** — compose force-recreates 5 fresh daemons; the
   entrypoint installs the freshly-built `.lgx` and sets the libp2p listen
   address to the **container IP** (not `0.0.0.0`, which would also advertise
   loopback and break mix/SURB/gifter dials). Only the RLN config account and
   funding mode come from the baked deployment profile — the payment account
   is funded per run (next stage).
2. **`per-node setup`** (relay1 first, with the **fund step**) — per node: load
   wallet + RLN + libp2p modules, open and sync the wallet (`wallet synced to
   <block>`; clients open it **read-only** — only relay1 signs or spends),
   `rlnEnable`, `start`, `mixSetNodeInfo`. relay1 then funds this run's budget:
   it walks the wallet's deterministic key chain to the first account with no
   on-chain data (`fresh account after N derivation(s)`), puts `MINT_AMOUNT`
   RLNTOK into it per the deployment's funding mode (faucet: `claim_tokens`
   from the program's own payment PDA in `CLAIM_CHUNK` slices, no mint key
   anywhere; wallet-key: `mint_tokens` with the definition key in the
   deployment wallet), and waits for the credit (`funded: payment=…
   balance=…`). Then
   the allocation lines: `leaf_opt` (optimistic leaf) **must equal**
   `leaf_actual` (on-chain), `confirmed=true` is the on-chain membership check,
   `rlnIsReady=True` means the node holds its identity + Merkle proof. relay1
   self-registers and mounts the gifter; each client generates its identity
   locally, signs EIP-191 over the idCommitment with its fixture key, dials
   relay1, and adopts the returned leaf. Allocations are **serialized by the
   on-chain confirmation barrier**, keeping the gifter wallet's txs
   nonce-ordered and every membership on a distinct leaf.
3. **`mesh`** — every node `mixNodepoolAdd`s the other four (pubkeys derived
   host-side by `keys.py`).
4. **`register dest-read-behavior`** — the SURB exit is random, so every node is
   taught to echo `/ipfs/ping`.
5. **`exchange`** — 3 round-trips per direction (`mixDialWithReply` →
   `streamWrite` → `streamReadExactly`, reply over the SURB path); RLN is
   generated and verified at every hop on both legs. There is deliberately no
   root-convergence wait beforehand: every registration advanced the on-chain
   tree, and a hop whose valid-roots window still lags recovers **in-line** —
   its verifier requests an on-demand `get_valid_roots` refresh from the module
   and re-checks (bounded at 3 s) instead of dropping the packet.
6. **`observe`** — counts scraped from daemon logs: originators generate exactly
   3 proofs each; relays run higher, uneven counts (verify + regenerate per
   forwarded packet, paths re-randomized per message); ≈6 verifications per
   round-trip × 6 round-trips = **36**; `root_misses`/`refresh_recovered` count
   the on-demand root refreshes (legitimately `0/0` on runs where the module's
   periodic proof push won the race); the gifter line confirms exactly 4 gifted
   registrations.

The negative runs prove RLN gates delivery (`PASS (negative)`, 0 replies, 0
sender proofs): `NEG=1` — the sender never asks the gifter and stays unregistered;
`NEG=2` — the sender signs with a non-allowlisted key and the gifter refuses
authentication.

## 4. Verification

### Success command

After `orchestrate.sh` finishes (and before `docker compose down` — the check
reads the containers' logs):

```sh
cd docker/testnet/mix_e2e && \
docker compose logs relay1 | grep -c 'RLN gifter registration succeeded' && \
docker compose logs | grep -c 'Proof verified successfully'
```

### Expected result

```text
4
36
```

`4` = the gifter performed exactly one on-chain registration for each of the
four client nodes (the allocation worked). `36` (or more) = every hop on every
forward and reply leg of the 6 round-trips verified an RLN proof (the gifted
memberships actually carried traffic through the mix). Containers are
force-recreated per run, so the counts cover only the run just finished.
`orchestrate.sh` itself is the first-line signal: it prints `VERDICT: PASS` and
exits 0, and any missing reply fails the verdict with a nonzero exit.

## 5. Configuration

### Configuration details

Near-zero-config: `bash orchestrate.sh` runs the full E2E. Fixed in
`orchestrate.sh`: 3 round-trips each way, `/ipfs/ping` echo, RLN
`userMessageLimit=100`, `epochDurationSeconds=10.0`. Endpoints: LEZ testnet RPC
`https://testnet.lez.logos.co/`; each daemon listens for libp2p/mix on its
container IP, port `9000/tcp`, on the compose bridge network. The knobs:

| Knob | Purpose | Example |
|---|---|---|
| `NEG` (env) | Negative enforcement tests: `0` (default) full E2E; `1` sender never asks the gifter → rejected; `2` sender signs with a non-allowlisted key → gifter refuses auth | `NEG=2 bash orchestrate.sh` |
| `MINT_AMOUNT` (env) | RLNTOK put into the fresh per-run payment account at setup (default `6000000` = 5 registrations × 1M + slack); raise it for modified run shapes. Funded per the deployment's mode: faucet claims, wallet-key mints | `MINT_AMOUNT=12000000 bash orchestrate.sh` |
| `CLAIM_CHUNK` (env) | Faucet mode only: per-`claim_tokens` slice (default `10000000` = the provision default cap); must be ≤ the deployment's `faucet_claim_cap` | `CLAIM_CHUNK=5000000 bash orchestrate.sh` |
| `DEPLOYMENT` (build-arg) | Which on-chain deployment (RLN tree + wallet + funding mode) is baked into the image (`docker/testnet/deployments/<name>/`, default `shared-faucet`; `shared-5ade` = wallet-key legacy) | `docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=fresh-tree -t lp2p-mix-e2e .` |
| `REPO_BASE` / `LOGOS_REPO_BASE` (env, bootstrap only) | Clone bases for the sibling repos (mix-stack forks / logos-co repos); override for HTTPS | see Happy path |

See `docker/testnet/deployments/README.md` for provisioning new profiles.

## 6. Known issues and troubleshooting

### Failure modes and limits

`orchestrate.sh` auto-detects the on-chain failures by scanning relay1's log and
prints the fix. Tree provisioning (failure 2) needs the host tools built once
(`cd "$LEZ_RLN_DIR/lez-rln" && PYO3_PYTHON=$(command -v python3) cargo
build --release --bin run_setup --bin derive_accounts`; the checkout needs a
plain `lssa/` sibling clone at `v0.2.0-rc6` for host cargo builds).

1. **Fund step fails** — symptom: the run aborts at
   `funding: fresh per-run payment account` (claim/mint not accepted, or the
   balance never credits). The run funds its own budget into a fresh account —
   there is no pre-funded pool to drain — so this normally means the testnet
   is unreachable/slow, on a faucet deployment that `CLAIM_CHUNK` exceeds the
   deployment's `faucet_claim_cap`, or (after `Insufficient balance` mid-run)
   that `MINT_AMOUNT` is too small for a modified run shape: re-run with e.g.
   `MINT_AMOUNT=12000000 bash orchestrate.sh`. Nothing to re-provision or
   rebuild.
2. **Tree full** — symptom: relay1 logs `Would exceed max total rate limit`
   (~10k members at rate 100 is the practical cap). Fix: provision a brand-new
   tree (no source edits — `tree_id` is the single knob) and rebuild:
   ```sh
   LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh --name fresh-tree
   docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=fresh-tree -t lp2p-mix-e2e .
   ```
3. **Testnet unreachable** — symptom: setup stalls at the first wallet-sync or
   registration barrier. Cause: everything needs `https://testnet.lez.logos.co/`.
   Fix/workaround: none — there is no offline mode.

**Diagnostics that are not failures:** `rlnRegister attempt N failed … re-sync +
retry in 15s` (and the gifter equivalent) is the harness retrying a transient
sequencer error — only repeated failures with one of the log signatures above are
real. `Root miss - requesting on-demand valid-roots refresh` followed by
`On-demand root refresh recovered proof root` is the normal in-line recovery when
a verifier's window lags the newest root. Real problems: `!! LEAF MISMATCH` means
the registration serialization barrier was bypassed or timed out, and
`Proof rejected: invalid Merkle root after on-demand refresh` means a packet was
actually dropped — the reply counts then fail the verdict.

**Limits / out of scope:** each run allocates 5 fresh identities, so leaves
accumulate on the shared tree across runs. Client-IP↔identity correlation is out
of scope (deferred by LIP-158 to RLN Stealth Commitments). Use `logoscore call`
for lifecycle calls, not one-shot `-c "…"`/`--quit-on-finish` (the one-shot
client doesn't await async calls and reports a spurious timeout).

## 7. Contact

### GitHub handle

adklempner

### Discord handle

arseniy

## 8. Additional context

### Existing docs or specs

- RLN Membership Allocation spec (LIP-158): https://lip.logos.co/anoncomms/raw/rln-membership-service.html
- RLN DoS Protection for Mixnet spec (LIP-144): https://lip.logos.co/anoncomms/raw/mix-spam-protection-rln.html
- LIBP2P-MIX spec (LIP-99): https://lip.logos.co/anoncomms/raw/mix.html
- Repo README (overview + quick start): https://github.com/logos-co/logos-rln-mix-sim
- Deployment profiles (provision/verify): `docker/testnet/deployments/README.md`
- Gifter protocol README: https://github.com/logos-co/logos-rln-gifter

### Hardware requirements

~30 GB free disk in Docker's VM (the image is ~17 GB; a cold Nix build needs
headroom); no special CPU/RAM/bandwidth beyond a typical dev machine.

### Estimated time to complete

~30-45 min first bootstrap (image build dominates; re-runs fast), then ~15 min
per sim run (the 5 sequential on-chain registrations dominate).

### Security notes

Everything the sim touches is testnet-only and disposable, but be aware:

- **The repo contains real (demo) private keys — including a mint authority.**
  `fixtures/gifter_auth/` holds EIP-191 signing keys and
  `docker/testnet/deployments/<name>/storage.json` holds the testnet wallet,
  which includes the RLNTOK definition keypair: anyone with the repo can mint
  unlimited test tokens (that is the point — runs fund themselves instead of
  draining a fixed pool). Never reuse these keys, the wallet, or the
  bake-a-wallet-into-an-image pattern for anything holding real value.
- **Runs make irreversible on-chain writes.** Every run submits real sequencer
  transactions: it mints its own RLNTOK budget into a fresh per-run payment
  account (inflating the test token's on-chain supply counter — harmless) and
  permanently consumes 5 leaves on the shared Merkle tree (~10k-leaf practical
  cap; the troubleshooting section covers provisioning a fresh tree when leaves
  run out). The tree is shared with everyone using the same deployment profile,
  but runs no longer compete for a shared pot of tokens.
- **Deliberately exceeding the rate limit leaks that identity's secret by
  design** (LIP-144 slashing reconstructs it from two nullifier shares). The
  sim's identities are generated fresh per run and discarded, so this only
  matters if you reuse an identity outside the sim.
- **Nothing touches your personal keys, accounts, or funds.** All state lives in
  the containers and the repo checkout; `docker compose down` discards the
  containers, and that is the expected lifecycle.
