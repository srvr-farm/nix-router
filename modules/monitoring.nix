{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.htop ];

  # Real-time + historical (default retention: a few days, dbengine on
  # disk) dashboard for CPU, memory, disk I/O, per-NIC bandwidth, and
  # per-process resource usage over time - covers "what was using the
  # most CPU an hour ago" via its Applications section, no separate tool
  # needed for that. Zero manual config beyond binding it off WAN.
  services.netdata = {
    enable = true;
    config.web."bind to" = "10.0.0.1 127.0.0.1";
  };

  # Belt-and-suspenders: modules/firewall.nix's input chain already only
  # accepts br-lan/tailscale0/lo (default-drop otherwise), so :19999 was
  # never WAN-reachable regardless - binding above is the primary control,
  # this just keeps the two in sync if the firewall ever changes.
}
