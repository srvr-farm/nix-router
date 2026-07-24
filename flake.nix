{
  description = "NixOS router configuration, migrated from OPNsense (gateway.srvr.farm)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.router = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          ./hosts/router/disko.nix
          ./hosts/router/configuration.nix
        ];
      };

      # Bootable installer ISO that carries this flake + an auto-login root
      # shell with git/disko preinstalled, so the whole install is:
      #   boot ISO -> git clone (or copy) this repo -> nixos-install --flake .#router
      # See README.md for the full cutover runbook.
      nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          disko.nixosModules.disko
          {
            isoImage.isoBaseName = "nixos-router-installer";
            environment.systemPackages = [
              nixpkgs.legacyPackages.${system}.git
              disko.packages.${system}.disko
            ];
          }
        ];
      };

      packages.${system}.iso = self.nixosConfigurations.installer.config.system.build.isoImage;
    };
}
