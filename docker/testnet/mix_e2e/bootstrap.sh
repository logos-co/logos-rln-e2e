#!/usr/bin/env bash
# One-shot bootstrap for the RLN-over-mix sim, runnable by any dev with only
# Docker + git installed. Run it from a clone of logos-rln-mix-sim:
#
#   git clone https://github.com/logos-co/logos-rln-mix-sim.git
#   cd logos-rln-mix-sim
#   bash docker/testnet/mix_e2e/bootstrap.sh
#   cd docker/testnet/mix_e2e && bash orchestrate.sh
#
# It clones the four sibling repos (next to this one), builds the Linux libp2p
# .lgx, and builds the base image tagged `lp2p-mix-e2e` (logoscore + wallet/rln
# modules + the baked deployment profile — all fetched by the image build).
#
# All repos are public and clone anonymously over HTTPS — no keys or env vars
# needed. Contributors who prefer SSH can override the clone bases:
#   REPO_BASE=git@github.com:adklempner LOGOS_REPO_BASE=git@github.com:logos-co ...
set -euo pipefail

# The mix stack lives on adklempner forks pending upstreaming; the gifter is a
# logos-co repo.
FORK_BASE="${REPO_BASE:-https://github.com/adklempner}"
LOGOS_BASE="${LOGOS_REPO_BASE:-https://github.com/logos-co}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"          # logos-rln-mix-sim
SIBLINGS="$(cd "$REPO_ROOT/.." && pwd)"            # parent dir = sibling root

command -v docker >/dev/null || { echo "docker is required"; exit 1; }
command -v git    >/dev/null || { echo "git is required"; exit 1; }

clone(){ # repo branch base
  if [ -d "$SIBLINGS/$1/.git" ]; then
    echo "  $1 already present"
  else
    echo "  cloning $1 ($2)"
    git clone --depth 1 -b "$2" "$3/$1.git" "$SIBLINGS/$1"
  fi
}

echo "=== 1/3 clone sibling repos into $SIBLINGS ==="
clone logos-libp2p-module             rebase/enable-mix  "$FORK_BASE"
clone mix-rln-spam-protection-plugin  feat/cbind-rln     "$FORK_BASE"
clone nim-libp2p-mix                  rebase/mix-cbind   "$FORK_BASE"
clone logos-rln-gifter                master             "$LOGOS_BASE"

echo "=== 2/3 build the Linux libp2p .lgx (~6-15 min) ==="
LOGOS_ROOT="$SIBLINGS" bash "$REPO_ROOT/docker/build_lgx_linux.sh"

echo "=== 3/3 build the base image lp2p-mix-e2e (~30 min first time) ==="
docker build -f "$REPO_ROOT/docker/Dockerfile.testnet-e2e" -t lp2p-mix-e2e "$REPO_ROOT"

cat <<EOF

DONE. Run the sim:
  cd $REPO_ROOT/docker/testnet/mix_e2e
  bash orchestrate.sh          # the full gifted-RLN-over-mix E2E
  NEG=1 bash orchestrate.sh    # negative: unregistered sender rejected
  NEG=2 bash orchestrate.sh    # negative: non-allowlisted sender refused by the gifter
  docker compose down          # tear down
EOF
