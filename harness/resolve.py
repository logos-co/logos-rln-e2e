"""Derive the RLN matrix from one pin, and say where every value came from.

logos-rln-modules is the pin that decides the set. Two things follow from it
and must not be maintained by hand beside it:

  * the logos-lez-rln revision — the module stack decodes chain state with
    `rln-layouts`, which logos-lez-rln-module/rust-lib/Cargo.toml pins to a
    logos-lez-rln rev. Deployed programs and the code that reads their state
    have to be the same revision, so flake.lock's `lez-rln` entry is not an
    independent choice: it is that rev, and disagreeing is the skew this
    refuses.
  * the module versions — metadata.json in each module dir. The relay image
    pulls PUBLISHED bundles by version, so the number it fetches has to be the
    number this pin builds, or the container quietly runs a different module
    than the host peers.

Each component is reported with its source:

  pin       read from flake.lock (logos-rln-modules itself)
  derived   read out of the pinned tree (the two above)
  override  an environment variable displaced it (E2E_LEZ_RLN_REV,
            E2E_LEZ_RLN_MODULE_VERSION, E2E_RLN_MODULE_VERSION)

so what is chosen and what merely follows is visible before anything builds —
which is the whole point. An override is not cheating: a checkout-driven dev
loop needs one. It is only required to be VISIBLE.

Usage:
    resolve.py --modules-src <dir> [--flake-lock <path>] [--json]
    resolve.py --modules-src <dir> --check     # exit 1 on skew, quiet on pass

--modules-src is the pinned logos-rln-modules tree, which harness/artifacts.sh
already materialises as E2E_RLN_MODULES_SRC via `nix build .#pins`.
"""
import argparse
import json
import os
import re
import sys

LAYOUTS_RE = re.compile(r"^rln-layouts\s*=.*?([0-9a-f]{40})", re.MULTILINE)


def _fail(msg):
    print(f"resolve: {msg}", file=sys.stderr)
    raise SystemExit(2)


def _read(path, what):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError as exc:
        _fail(f"cannot read {what} at {path}: {exc}")


def derive(modules_src, flake_lock):
    """The matrix, as {component: {value, source, note}}."""
    out = {}

    lock = json.loads(_read(flake_lock, "flake.lock"))
    node = lock.get("nodes", {}).get("rln-modules", {})
    pinned_rev = node.get("locked", {}).get("rev")
    if not pinned_rev:
        _fail("flake.lock has no locked rev for the rln-modules input")
    out["rln_modules"] = {"value": pinned_rev, "source": "pin",
                          "note": "the one pin the rest follows"}

    # The lez-rln rev this pin REQUIRES, straight out of the tree.
    cargo = _read(
        os.path.join(modules_src, "logos-lez-rln-module/rust-lib/Cargo.toml"),
        "the lez module's Cargo.toml")
    match = LAYOUTS_RE.search(cargo)
    if not match:
        _fail("no 40-char rln-layouts rev in the lez module's Cargo.toml — a "
              "short rev reads as absent, so pin it by full object name")
    derived_lez = match.group(1)

    override = os.environ.get("E2E_LEZ_RLN_REV", "")
    out["lez_rln"] = {
        "value": override or derived_lez,
        "source": "override" if override else "derived",
        "note": "rln-layouts in the lez module's Cargo.toml",
        "derived": derived_lez,
        "locked": lock.get("nodes", {}).get("lez-rln", {}).get("locked", {}).get("rev"),
    }

    for component, subdir, env in (
        ("lez_rln_module", "logos-lez-rln-module", "E2E_LEZ_RLN_MODULE_VERSION"),
        ("rln_module", "logos-rln-module", "E2E_RLN_MODULE_VERSION"),
    ):
        meta = json.loads(_read(os.path.join(modules_src, subdir, "metadata.json"),
                                f"{subdir}/metadata.json"))
        version = meta.get("version")
        if not version:
            _fail(f"{subdir}/metadata.json declares no version")
        env_value = os.environ.get(env, "")
        out[component] = {
            "value": env_value or version,
            "source": "override" if env_value else "derived",
            "note": f"{subdir}/metadata.json",
            "derived": version,
        }

    return out


def skew(matrix):
    """The one disagreement that silently corrupts a run, or None."""
    lez = matrix["lez_rln"]
    if lez["source"] == "override":
        return None  # a deliberate displacement is not skew
    if lez["locked"] != lez["derived"]:
        return (f"the pinned rln-modules tree builds against rln-layouts from "
                f"lez-rln {lez['derived'][:12]}, but flake.lock pins lez-rln "
                f"{(lez['locked'] or '<none>')[:12]}.\n"
                "  The module stack would decode chain state with layouts from a "
                "different revision than the deployed programs.\n"
                "  Fix by relocking lez-rln to the derived rev, or by bumping "
                "rln-layouts in logos-rln-modules — not by editing both to a third value.")
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--modules-src", required=True)
    ap.add_argument("--flake-lock", default="flake.lock")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    matrix = derive(args.modules_src, args.flake_lock)
    problem = skew(matrix)

    if args.json:
        print(json.dumps(matrix, indent=2, sort_keys=True))
    elif not args.check:
        for name, entry in sorted(matrix.items()):
            print(f"{name:18} {entry['value'][:40]:42} {entry['source']:9} {entry['note']}")

    if problem:
        print(f"resolve: pin skew\n  {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
