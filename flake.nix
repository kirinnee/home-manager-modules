{
  description = "Home Manager modules for multi-account CLI tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    gws.url = "github:googleworkspace/cli";
  };

  outputs = { self, nixpkgs, home-manager, gws, ... }: {
    # Home Manager modules - main outputs for users
    homeManagerModules.multi-claude = import ./modules/multi-claude.nix;
    homeManagerModules.multi-gh = import ./modules/multi-gh.nix;
    homeManagerModules.multi-gws =
      { pkgs, ... }@args:
      import ./modules/multi-gws.nix (args // {
        gwsPackage = gws.packages.${pkgs.stdenv.hostPlatform.system}.default;
      });

    # Development shell for nix tooling
    devShells = builtins.mapAttrs
      (system: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            nixpkgs-fmt
            nil
          ];
        };
      })
      nixpkgs.legacyPackages;
  };
}
