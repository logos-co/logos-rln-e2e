# Module naming — the 2026-08-10 rename

On 2026-08-10 the RLN module stack was extracted from logos-lez-rln into
[logos-rln-modules] and two names **swapped meaning**:

| module | before | after |
|---|---|---|
| registry provider (chain reads, Register tx, faucet) | repo dir `logos-rln-module`, lib `liblogos_rln_module` | repo dir `logos-lez-rln-module`, lib `liblogos_lez_rln_module` |
| membership management (credentials, keystore, proofs) | repo dir `logos-rln-membership-module`, lib `liblogos_rln_membership_module` | repo dir `logos-rln-module`, lib `liblogos_rln_module` |

So `liblogos_rln_module` in anything written **before** 2026-08-10 means the
registry provider; in anything written after, the membership module.

Rules for this repo:

- Scripts and docs always use the **runtime library names**
  (`liblogos_lez_rln_module`, `liblogos_rln_module`), never repo-dir
  shorthands.
- `tools/check-naming.sh` fails the tree on pre-rename identifiers outside
  the quarantined mix scenario.

[logos-rln-modules]: https://github.com/logos-co/logos-rln-modules
