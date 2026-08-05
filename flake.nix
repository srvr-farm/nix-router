{
  description = "NixOS router configuration, migrated from OPNsense (gateway.srvr.farm)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Used only as the Rust toolchain for modules/srvr-farm-tools.nix - the
    # srvr-farm tools' Cargo.lock pulls in dependencies (darling, instability,
    # unicode-segmentation) whose MSRV (1.85-1.88) is newer than nixos-24.11's
    # pinned rustc (1.82). Nothing else in the system uses this input, so the
    # rest of the router stays on the already-validated 24.11 pin.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      unstablePkgs = nixpkgs-unstable.legacyPackages.${system};
      srvrFarmTools = import ./pkgs/srvr-farm-tools.nix { inherit pkgs unstablePkgs; };
    in
    {
      nixosConfigurations.router = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit nixpkgs-unstable; };
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

      packages.${system} = {
        iso = self.nixosConfigurations.installer.config.system.build.isoImage;

        # Raw disk image of the *installed* router config (disko + configuration.nix
        # baked in, no separate install step). Build then run the resulting script
        # to produce a nixos-router.raw file, which can be `dd`'d straight onto the
        # real disk. See MIGRATION.md's cutover runbook for the secrets-embedding
        # invocation and the post-dd partition-growing step.
        diskoImage = self.nixosConfigurations.router.config.system.build.diskoImagesScript;
      } // srvrFarmTools;
    };
}
