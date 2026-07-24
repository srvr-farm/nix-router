{ pkgs, ... }:
{
  imports = [
    ../../modules/network.nix
    ../../modules/firewall.nix
    ../../modules/dhcp-dns.nix
    ../../modules/tailscale.nix
    ../../modules/ddns.nix
    ../../modules/ssh.nix
  ];

  # --- Boot / hardware ---------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # i7-8700, 8GB RAM, single SATA SSD - see hosts/router/disko.nix.
  nixpkgs.hostPlatform = "x86_64-linux";

  # --- Base system, carried over from OPNsense's <system> settings -------
  time.timeZone = "America/Los_Angeles";
  services.timesyncd.enable = true;
  services.timesyncd.servers = [
    "0.opnsense.pool.ntp.org"
    "1.opnsense.pool.ntp.org"
    "2.opnsense.pool.ntp.org"
    "3.opnsense.pool.ntp.org"
  ];

  environment.systemPackages = with pkgs; [
    vim
    tcpdump
    ethtool
    conntrack-tools
    mtr
  ];

  # Bumping this on upgrade is your job, not an automated one - this just
  # pins the state format this config was written against.
  system.stateVersion = "24.11";
}
