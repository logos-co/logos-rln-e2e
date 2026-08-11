# shellcheck shell=bash
# harness/targets/local.sh — the local-sequencer target (W1-B implements).
#
# target_up:
#   E2E_DEVNET=host (default)  run logos-lez-rln's root dev.sh (from
#                              $LEZ_RLN_CHECKOUT, default ../logos-lez-rln) in
#                              the background; it clones + runs the standalone
#                              sequencer_service on port 3040 and wipes its
#                              rocksdb each start.
#   E2E_DEVNET=external        attach to an already-running sequencer
#                              (inner dev loop; skips re-provisioning).
#   Readiness = JSON-RPC getLastBlockId >= 1, not a port probe.
#   Then provision a fresh deployment (lez-rln tools/deployments/provision.sh
#   --funding faucet) into $E2E_RUN_DIR and stage it (stage.sh) into
#   $E2E_WALLET_HOME; export the contract env (docs/contract.md).
#   Provisioning needs prebuilt run_setup/derive_accounts + the risc0 guest
#   blobs in the checkout — when missing, print the exact build recipe and die.
#
# target_down: kill the sequencer we started unless E2E_KEEP=1.

target_up()   { die "targets/local.sh: not implemented yet (W1-B)"; }
target_down() { :; }