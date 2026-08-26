{
  description = "nim-rln-consumer - Nim mock of logos-delivery's RLN integration, as a logos-core module";

  nixConfig = {
    extra-substituters = [ "https://cache.nix.logos.co/public" ];
    extra-trusted-public-keys = [ "public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=" ];
  };

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.2.5";
    nix-bundle-lgx.url = "github:logos-co/nix-bundle-lgx";
  };

  outputs = inputs@{ self, logos-module-builder, ... }:
    let
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      # The Nim library, wrapped flake-shaped so mkLogosModule's
      # externalLibInputs resolves it per system.
      rlnconsumerLib = {
        packages = nixpkgs.lib.genAttrs systems (system: {
          default = import ./nim-lib/nix {
            pkgs = import nixpkgs { inherit system; };
            src = ./nim-lib;
          };
        });
      };
    in
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
      externalLibInputs = {
        rlnconsumer = rlnconsumerLib;
      };
    };
}
