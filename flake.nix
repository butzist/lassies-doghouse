{
  description = "Lassie's Doghouse: a jailed ColliePWA built from source, with a network/filesystem jail for the bridge, an allowlisted Web Push egress proxy, and an optional tailscale serve front door";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # Converts the two pinned bun.lock files into Nix-fetchable dependency
    # sets, so the Collie source build runs offline in the sandbox.
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    bun2nix,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];

    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system:
        f {
          inherit system;
          pkgs = nixpkgs.legacyPackages.${system};
        });

    # The module's package default must resolve against the *consumer's*
    # system, not the flake evaluation system, so pass a function rather than a
    # fixed derivation.
    homeManagerModule = import ./modules/home.nix {
      packageFor = system: self.packages.${system}.collie;
    };
  in {
    packages = forAllSystems ({
      pkgs,
      system,
    }: rec {
      collie = pkgs.callPackage ./packages/collie.nix {
        bun2nix = bun2nix.packages.${system}.default;
      };
      default = collie;
    });

    homeManagerModules = {
      default = homeManagerModule;
      collie = homeManagerModule;
    };

    nixosModules = {
      default = ./modules/nixos.nix;
      collie-serve = ./modules/nixos.nix;
    };

    devShells = forAllSystems ({
      pkgs,
      system,
    }: {
      default = pkgs.mkShell {
        packages = [
          bun2nix.packages.${system}.default
          pkgs.alejandra
          pkgs.bun
          pkgs.deadnix
          pkgs.nixd
          pkgs.statix
        ];
      };
    });

    formatter = forAllSystems ({pkgs, ...}: pkgs.alejandra);
  };
}
