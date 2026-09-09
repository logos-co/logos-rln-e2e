# shellcheck shell=bash
# harness/targets/none.sh — the chainless target: no sequencer, no
# deployment, no wallet fixture. For scenarios that exercise the module
# runtime only (daemon boot, module co-residency, off-chain transports like
# delivery's relay mesh). A scenario that touches the chain contract env
# (E2E_SEQUENCER etc.) fails its own preflight — this target exports none
# of it, deliberately.

target_up() {
    section "target: none (no chain)"
    say "chainless run: no sequencer/deployment provisioned"
}

target_down() { :; }
