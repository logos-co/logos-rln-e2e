# mix scenario — revival in progress

Being rebuilt on the **logos-delivery mix stack** (`PINS.env`:
logos-messaging/logos-delivery @ `feat/logos-testnetv02-mix`), replacing the
retired libp2p-module/gifter stack (deleted here; history has it at
`feat/e2e-repo`).

The shape: 5 host `wakunode2` processes with per-node mix keys, RLN
spam-protection per hop via mix-rln-spam-protection-plugin (zerokit v2.0.2
stateless, depth-20 tree). Membership is **pre-provisioned and static** —
the harness generates the identities host-side, writes the plugin's
keystores + tree, and registers the same commitments **on-chain** through
`liblogos_lez_rln_module.register_member`. The defining assertion: the
plugin tree's root appears in the registry's `get_valid_roots` — the mix
network's RLN group is the on-chain registry.

Quarantine lifts when `./run.sh mix --target local` is green (M-C of the
revival plan). Gifted allocation (LIP-158) returns only when the new gifter
wire (`rln_gifter_module`) has a contract to build against.
