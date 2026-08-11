# shellcheck shell=bash
# harness/targets/testnet.sh — the hosted-testnet target (W1-B implements).
#
# target_up: no chain lifecycle — read a committed descriptor from
# deployments/<name> (default via E2E_DEPLOYMENT), assert the sequencer
# answers getLastBlockId, stage into $E2E_WALLET_HOME, export the contract
# env with testnet poll budgets (docs/contract.md).
#
# target_down: nothing to tear down.

target_up()   { die "targets/testnet.sh: not implemented yet (W1-B)"; }
target_down() { :; }