# shellcheck shell=bash
# harness/artifacts.sh — resolve every binary/bundle a scenario loads.
#
# Resolution order per artifact (W1-A implements):
#   1. explicit env override: LOGOSCORE, WALLET_LGX, LEZ_RLN_LGX, RLN_LGX
#   2. nix build from the flake pins: .#logoscore, .#wallet-lgx,
#      .#lez-rln-module-lgx, .#rln-module-lgx. Verified 2026-08-10: the module
#      bundles build from a clean rln-modules fetch — the module-builder
#      stages the sdk and regenerates the scaffold in-derivation. (The
#      checkout-side staging scripts are only for bare-cargo dev loops.)
#
# Also W1-A: the pin-consistency check — the rln-modules tree pins rln-layouts
# to a logos-lez-rln rev in logos-lez-rln-module/rust-lib/Cargo.toml; if that
# rev differs from the lez-rln source in use, chain-state decode skew shows up
# as phantom chain bugs. Assert equality, fail loudly with both revs.

resolve_artifacts() { die "artifacts.sh: not implemented yet (W1-A)"; }