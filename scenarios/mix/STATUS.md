# mix scenario — QUARANTINED

The sim last ran green against the hosted testnet before 2026-08-10; nothing
here has been adapted to the harness yet, and its build is dead:

1. **Dead module pin.** `harness/container/Dockerfile.node` (the old
   `Dockerfile.testnet-e2e`) clones `logos-co/logos-lez-rln` at
   `feat/deploy-policies@7e6e9ab` — an orphaned pre-split commit — and builds
   the flake attr `.#logos-rln-module`, which the module-stack extraction
   (logos-lez-rln `96621e4`, 2026-08-10) deleted. That module now lives in
   `logos-co/logos-rln-modules` as `logos-lez-rln-module`, and the name
   `logos-rln-module` means the membership-management module instead — see
   `docs/naming.md`. Every module reference under `scenarios/mix/` uses the
   **pre-rename** meanings.
2. **Testnet-only.** `orchestrate.sh` hardcodes the hosted RPC; the committed
   deployment descriptors it relied on predate the 2026-08-05 chain reset and
   were removed with the vendored deployment tooling.
3. **Personal-fork siblings.** `bootstrap.sh` clones three
   `adklempner/*@feat/on-demand-roots` forks plus `logos-rln-gifter`; a
   revival must either upstream them or pin them as explicit flake inputs.

Revival is phase P4 of the rework plan: module bundles come from
`harness/artifacts.sh`, the RPC from `$E2E_SEQUENCER`, the generic primitives
(`jcall`/`sync_wallet`/`wait_balance`/`confirm_and_ready`/`diagnose_reg`)
from `harness/lib/` — leaving the gifter/keycard/NEG logic here as the
scenario's `run.sh`. First local-target run will be the sim's first run with
zero external infra.

The old narrated runbook (`JOURNEY.md`) stays an untracked local doc beside
this file.
