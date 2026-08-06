{ lib, ... }:
{
  # dnsmasq replaces OPNsense's dhcpd (on opt5/bridge0) + Unbound (with its
  # custom host overrides for the srvr.farm split-horizon DNS). OPNsense's
  # Unbound was doing full recursive resolution (forwarding disabled); we
  # forward to the same four resolvers OPNsense listed system-wide instead,
  # which is functionally equivalent for anything on this LAN.
  networking.nameservers = [ "127.0.0.1" ];

  services.dnsmasq = {
    enable = true;
    settings = {
      interface = [ "br-lan" "tailscale0" ];
      bind-interfaces = true;
      except-interface = "wan";

      domain = "callan.local";
      expand-hosts = true;
      domain-needed = true;

      dhcp-range = [ "10.0.0.100,10.0.0.200,12h" ];
      dhcp-option = [
        "option:router,10.0.0.1"
        "option:dns-server,10.0.0.1"
      ];

      # Upstream resolvers (same set OPNsense had configured system-wide).
      no-resolv = true;
      server = [ "1.1.1.1" "1.0.0.1" "208.67.222.222" "208.67.220.220" ];

      # --- Static DHCP reservations ---------------------------------------
      # These live outside this file now, in a plain-text dnsmasq
      # dhcp-hostsfile that's re-read on SIGHUP (no redeploy/restart
      # needed). That's deliberate: scripts/dhcp-static.sh and
      # scripts/dhcp-leases.sh (installed on the router itself via
      # modules/dhcp-tools.nix) manage this file directly, and the router
      # has no checkout of this repo for them to edit instead. See
      # modules/dhcp-static-hosts.seed for the checked-in baseline this
      # file gets seeded from the first time it's missing (i.e. on a full
      # reimage) - it also carries the migration history/notes that used
      # to live in this comment block.
      dhcp-hostsfile = "/var/lib/dnsmasq/static-hosts.conf";

      # --- Split-horizon overrides for *.srvr.farm, carried over from
      #     Unbound's host overrides ------------------------------------
      address = [
        "/registry.srvr.farm/10.0.0.10"
        "/mark.srvr.farm/10.0.0.10"
        "/resume.srvr.farm/10.0.0.10"
        "/omada.srvr.farm/10.0.0.10"
        "/gateway.srvr.farm/10.0.0.10"
        "/jenkins.srvr.farm/10.0.0.10"
        "/backrest.srvr.farm/10.0.0.10"
        "/code.srvr.farm/10.0.0.10"
        "/files.srvr.farm/10.0.0.10"
        "/ha.srvr.farm/10.0.0.10"
        "/tf2.srvr.farm/10.0.0.10"
        "/inventory.srvr.farm/10.0.0.8"
        "/ai.srvr.farm/10.0.0.10"
        "/m0.srvr.farm/10.0.0.10"
        "/chris.srvr.farm/10.0.0.10"
        "/memos.srvr.farm/10.0.0.10"
      ];
    };
  };

  # DNS/DHCP for the whole LAN depends on this service - it must keep
  # retrying forever, not give up. Without this, systemd's defaults
  # (DefaultStartLimitBurst=5 within DefaultStartLimitIntervalSec=10s) stop
  # restarting it after 5 failures in a 10s window; startLimitIntervalSec=0
  # disables that rate limit entirely so it always retries.
  systemd.services.dnsmasq = {
    startLimitIntervalSec = 0;
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 5;
    };
  };

  # Seed the dhcp-hostsfile referenced above from the checked-in baseline,
  # but only if it doesn't already exist ('C' = copy-if-missing) - once the
  # router (or scripts/dhcp-static.sh, run manually) has written a real
  # file there, redeploys must never clobber it. The 'd' rule creates
  # /var/lib/dnsmasq itself first, since on a fresh reimage nothing has
  # created it yet at the point systemd-tmpfiles runs (dnsmasq's own
  # preStart normally does that, but only once the service itself starts).
  systemd.tmpfiles.rules = [
    "d /var/lib/dnsmasq 0755 dnsmasq dnsmasq -"
    "C /var/lib/dnsmasq/static-hosts.conf 0644 dnsmasq dnsmasq - ${./dhcp-static-hosts.seed}"
  ];
}
