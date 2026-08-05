{ pkgs, lib, nixpkgs-unstable, ... }:
let
  # See flake.nix - these 4 tools' dependencies need a newer rustc than
  # nixos-24.11 ships, so they're built with nixpkgs-unstable's toolchain
  # while staying part of this otherwise-24.11 system closure.
  unstablePkgs = nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  tools = import ../pkgs/srvr-farm-tools.nix { inherit pkgs unstablePkgs; };
  inherit (tools) cpuwatch memwatch interfaces diskwatch;
in
{
  environment.systemPackages = [
    cpuwatch
    memwatch
    interfaces
    diskwatch
    pkgs.dmidecode # memwatch shells out to this for DIMM details
    pkgs.smartmontools # diskwatch shells out to `smartctl` for SMART health
  ];

  # cpuwatch/memwatch/diskwatch read root-only /proc, /sys (and, for
  # memwatch, perf_event) state; upstream's own packaging (Makefile
  # `install`/`capability` targets) grants this via `setcap` rather than
  # running as root. security.wrappers is the NixOS equivalent - it makes
  # a small setuid-root wrapper at /run/wrappers/bin/<name> that applies
  # just these capabilities before exec'ing the real (unprivileged) store
  # binary. `ifs` (interfaces) needs no capability upstream, so it's only
  # in systemPackages above, unwrapped.
  security.wrappers = {
    cpuwatch = {
      source = "${cpuwatch}/bin/cpuwatch";
      owner = "root";
      group = "root";
      permissions = "u+rx,g+rx,o+rx";
      capabilities = "cap_dac_read_search+ep";
    };
    memwatch = {
      source = "${memwatch}/bin/memwatch";
      owner = "root";
      group = "root";
      permissions = "u+rx,g+rx,o+rx";
      capabilities = "cap_perfmon,cap_dac_read_search+ep";
    };
    diskwatch = {
      source = "${diskwatch}/bin/diskwatch";
      owner = "root";
      group = "root";
      permissions = "u+rx,g+rx,o+rx";
      capabilities = "cap_dac_read_search+ep";
    };
  };
}
