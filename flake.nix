{
  description = "Logos RLN e2e — composition root for RLN-on-LEZ scenarios";

  inputs = {
    nixpkgs.follows = "logos-core/nixpkgs";

    # Same sdk pin as logos-lez-rln and logos-rln-modules: one nixpkgs across
    # the stack.
    logos-core.url = "github:logos-co/logos-cpp-sdk/25c88f4d48fa95ea4437194bcf60bd8d0cf84a74";

    # The compatibility matrix. flake.lock records the exact revisions of the
    # producer repos this repo's scenarios are known to compose; bumping the
    # lock is the act of declaring a new known-good set. lez-rln is a source
    # pin (the harness consumes its deployment tooling as files, and its flake
    # exposes no outputs we need); rln-modules is a flake whose module bundles
    # we re-export below.
    lez-rln = {
      url = "github:logos-co/logos-lez-rln";
      flake = false;
    };
    rln-modules.url = "github:logos-co/logos-rln-modules";

    # logoscore is consumed as a flake: its default package is the daemon/CLI
    # every scenario drives. The module-stack e2e used to fetch it unpinned at
    # run time; locking it here makes it part of the matrix.
    logoscore-cli.url = "github:logos-co/logos-logoscore-cli";
  };

  outputs =
    {
      self,
      nixpkgs,
      lez-rln,
      rln-modules,
      logoscore-cli,
      ...
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      eachSystem = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = eachSystem (
        system: pkgs:
        {
          # The pinned source trees, as env for harness/artifacts.sh:
          #   . "$(nix build .#pins --no-link --print-out-paths)"
          pins = pkgs.writeText "e2e-pins.env" ''
            E2E_LEZ_RLN_SRC=${lez-rln}
          '';
        }
        # The module bundles every scenario loads, re-exported from the
        # rln-modules pin (they build from a clean fetch — the module-builder
        # stages the sdk and regenerates the scaffold in-derivation).
        // lib.optionalAttrs (rln-modules.packages ? ${system}) {
          lez-rln-module-lgx = rln-modules.packages.${system}.logos-lez-rln-module-lgx;
          rln-module-lgx = rln-modules.packages.${system}.logos-rln-module-lgx;
          wallet-lgx = rln-modules.packages.${system}.wallet-module;
        }
        // lib.optionalAttrs (logoscore-cli.packages ? ${system}) {
          logoscore = logoscore-cli.packages.${system}.default;
        }
      );

      devShells = eachSystem (
        system: pkgs: {
          default = pkgs.mkShell {
            packages = with pkgs; [
              jq
              curl
              python3
              openssl
              rsync
              gnutar
              shellcheck
            ];
          };
        }
      );
    };
}
