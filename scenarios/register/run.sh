#!/usr/bin/env bash
# W1-C ports logos-rln-modules/logos-rln-module/tests/e2e_register_testnet.sh
# here, minus its harness stages (staging/daemon/wallet move to harness/lib),
# with poll budgets from the contract env instead of testnet constants and the
# registry id derived as logos:${E2E_TARGET}:<config-account-hex>.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/harness/lib/compat.sh"
die "scenarios/register: not implemented yet (W1-C)"
