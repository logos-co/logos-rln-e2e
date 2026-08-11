#!/usr/bin/env bash
# Names that flipped meaning on 2026-08-10 (docs/naming.md) must not appear in
# active code; only the files that discuss the rename itself are excluded.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

excl=(':!docs/naming.md' ':!tools/check-naming.sh')
bad=0

# Pre-rename identifiers that no longer exist anywhere in the stack.
if git grep -nE 'logos[-_]rln[-_]membership[-_]module|lez_rln_membership' -- . "${excl[@]}"; then
    bad=1
fi

# The hosted-testnet URL belongs to the testnet target and its descriptors only.
if git grep -n 'testnet\.lez\.logos\.co' -- . "${excl[@]}" \
    ':!harness/targets/testnet.sh' ':!deployments'; then
    bad=1
fi

[ "$bad" = 0 ] || { echo "check-naming: stale names found (docs/naming.md)" >&2; exit 1; }
echo "check-naming: OK"
