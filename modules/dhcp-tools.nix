{ pkgs, ... }:
let
  # Shared PATH for all three tools: gawk (TSV parsing), util-linux (flock
  # for safe concurrent edits, column for table output), plus the usual
  # coreutils/grep/sed and systemctl (dnsmasq reload, reading its live
  # ExecStart to find the active conf file).
  runtimeInputs = with pkgs; [
    gawk
    gnugrep
    gnused
    coreutils
    util-linux
    systemd
  ];

  dhcpStatic = pkgs.writeShellApplication {
    name = "dhcp-static";
    inherit runtimeInputs;
    text = builtins.readFile ../scripts/dhcp-static.sh;
  };

  # dhcp-leases shells out to `dhcp-static add` for its `promote`
  # subcommand, so it needs that package on its own PATH too.
  dhcpLeases = pkgs.writeShellApplication {
    name = "dhcp-leases";
    runtimeInputs = runtimeInputs ++ [ dhcpStatic ];
    text = builtins.readFile ../scripts/dhcp-leases.sh;
  };

  lanHosts = pkgs.writeShellApplication {
    name = "lan-hosts";
    runtimeInputs = runtimeInputs ++ [ dhcpStatic ];
    text = builtins.readFile ../scripts/lan-hosts.sh;
  };

  dnsFailover = pkgs.writeShellApplication {
    name = "dns-failover";
    inherit runtimeInputs;
    text = builtins.readFile ../scripts/dns-failover.sh;
  };
in
{
  environment.systemPackages = [
    dhcpStatic
    dhcpLeases
    lanHosts
    dnsFailover
  ];
}
