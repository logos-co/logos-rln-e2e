# mix scenario

Revived 2026-08-11 on the **logos-delivery mix stack** (`PINS.env`), replacing
the retired libp2p-module/gifter stack (history has it at `feat/e2e-repo`).

The shape: 5 host `wakunode2` processes (the stack's own sim fixture
identities), per-hop RLN spam protection via mix-rln-spam-protection-plugin
(zerokit v2.0.2 stateless, depth-20 tree), cover traffic as the workload.
Membership is **pre-provisioned and static**: `tools/setup_chain_credentials.nim`
generates the identities host-side, writes the plugin's keystores + tree, and
the harness registers the same commitments in the same order on-chain through
`liblogos_lez_rln_module.register_member`. The defining assertion holds: the
plugin tree's root is a valid root of the on-chain registry — the mix
network's RLN group *is* the registry.

Operational notes (learned the hard way, encoded in `lib/nodes.sh`):
- Bootstrap starts strictly first; relays dialing an unready bootstrap back
  off for minutes and stall their setup.
- Relay setup takes ~60–70s even against a ready bootstrap; readiness is the
  `MixRlnSpamProtection started` log line, never an HTTP probe.
- Cover-traffic proof generation (~100–350ms each) saturates the nodes'
  single-threaded event loops: metrics endpoints answer unreliably under
  load, so the verdict scrapes once, at the end, and aggregates over the
  nodes that answer (`forwarded{type="Intermediate"}` = a hop whose proof
  verified).
- `mix_cover_error_total{error="BUILD_FAILED"}` counts cover slots missed
  under proof-time pressure — backpressure noise, reported but not failing.

Not yet here: chat2mix payload exchange (cover traffic carries the verdict),
a negative unregistered-node probe, the testnet target (a live tree grows, so
the static root ages out of the window — needs the plugin to consume on-chain
roots first), and gifted allocation (returns when `rln_gifter_module` has a
contract to build against).
