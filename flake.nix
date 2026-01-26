{
  description = "Home Manager modules for multi-account Claude Code and GitHub CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }: {
    # Home Manager modules - main outputs for users
    homeManagerModules.multi-claude = import ./modules/multi-claude.nix;
    homeManagerModules.multi-gh = import ./modules/multi-gh.nix;

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
