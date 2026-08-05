# Package definitions for the srvr-farm read-only hardware monitor TUIs
# (cpuwatch, memwatch, ifs/interfaces, diskwatch). Built with
# nixpkgs-unstable's Rust toolchain - see the comment on the
# nixpkgs-unstable flake input in flake.nix for why.
#
# Consumed by:
#   - flake.nix, as `packages.<system>.{cpuwatch,memwatch,interfaces,diskwatch}`
#   - modules/srvr-farm-tools.nix, which wires these into the router
#     (environment.systemPackages + security.wrappers for the capabilities
#     upstream's own packaging grants via setcap)
{ pkgs, unstablePkgs }:
let
  mkSrvrFarmTool = { pname, repo ? pname, rev, hash, cargoHash }:
    unstablePkgs.rustPlatform.buildRustPackage {
      inherit pname cargoHash;
      version = "unstable-2026-08-05";
      src = pkgs.fetchFromGitHub {
        owner = "srvr-farm";
        inherit repo rev hash;
      };
      doCheck = false; # read-only hardware monitors - tests need real /proc, /sys, disks etc.
    };
in
{
  cpuwatch = mkSrvrFarmTool {
    pname = "cpuwatch";
    rev = "5a1c8792ff51a6b014a228f640607920786163df";
    hash = "sha256-4L7fcLlGRIb5ZGiUibkC96azTNNvDg7ZZsbhk2XroJY=";
    cargoHash = "sha256-PkbDCdXQdhDZ8WiPYSnLL+Zmyc8eY3XMAxtTK9CuOEA=";
  };

  memwatch = mkSrvrFarmTool {
    pname = "memwatch";
    rev = "0bc60c16287807ff79e50f91042065e126d7d2f0";
    hash = "sha256-34pWV0OD2IVeRmu5FBOI6ZypsHx+H1oDFkiCSUhQdN8=";
    cargoHash = "sha256-lm10ZzWNzroCzRaJAPDf5PJAl9h7/yOrv1tk+VHItzE=";
  };

  # Repo is "interfaces" but the crate/binary is named "ifs" (Cargo.toml
  # `[package] name = "ifs"`) - `pname` drives both the derivation name
  # and the resulting $out/bin name, so it stays "ifs" with `repo`
  # overridden separately for the actual GitHub fetch.
  interfaces = mkSrvrFarmTool {
    pname = "ifs";
    repo = "interfaces";
    rev = "5d4f97c6ca571fba3f434e914d024f8f8537b834";
    hash = "sha256-4mTTGmAgBNVPx7GO6ZRqPHo9vtPF2JMUxkeiTRrIBZU=";
    cargoHash = "sha256-CPFsuX7hgvVwzNod5LSCJ8dXsZO0TGIKsr/DOqs2ELM=";
  };

  diskwatch = mkSrvrFarmTool {
    pname = "diskwatch";
    rev = "a68323f4fed9311c53f9f7b3982c673d3af2df2a";
    hash = "sha256-toWIdcxZM3gJT5yKz95D2Z5r/9RCmu65HyAmAvdK4Qw=";
    cargoHash = "sha256-wNYa8h2jimMI4T24oe/B1Wyzshr1SbuOUbHrc4WMQFU=";
  };
}
