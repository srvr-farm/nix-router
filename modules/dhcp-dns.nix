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
      interface = [ "br-lan" "tailscale0" "pihole-shim" ];
      bind-interfaces = true;
      except-interface = "wan";

      domain = "callan.local";
      expand-hosts = true;
      domain-needed = true;
      # domain-needed only suppresses forwarding unqualified *forward*
      # lookups upstream - it does nothing for PTR (reverse) lookups.
      # Pi-hole PTRs every client IP it sees to populate its dashboard
      # with device names; without bogus-priv, any 10.0.0.x PTR dnsmasq
      # can't answer locally (i.e. isn't a known host) gets forwarded to
      # the public upstream resolvers below, continuously leaking this
      # LAN's internal address/device structure. bogus-priv makes dnsmasq
      # answer "no such name" itself for unresolvable RFC1918 PTRs
      # instead of forwarding them - known-good PTRs (any host dnsmasq
      # already knows about) are unaffected, since it answers those
      # locally either way.
      bogus-priv = true;

      dhcp-range = [ "10.0.0.100,10.0.0.200,12h" ];
      dhcp-option = [
        "option:router,10.0.0.1"
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

      # --- DHCP-advertised DNS server, in its own runtime-mutable file --
      # so scripts/dns-failover.sh (installed on the router via
      # modules/dhcp-tools.nix) can flip it between Pi-hole and a direct/
      # unfiltered fallback without a redeploy. Unlike dhcp-hostsfile
      # above, dhcp-option values are NOT re-read on SIGHUP - only a
      # full restart picks up a change here (that's what dns-failover
      # does). /etc/dnsmasq-conf.conf is the dnsmasq module's own
      # default conf-file (part of its networking.resolvconf
      # integration - unrelated to this, but must stay); mkForce'd
      # explicitly alongside our own entry rather than relying on
      # uncertain list-merge behavior between our definition and the
      # module's lib.mkDefault one.
      conf-file = lib.mkForce [
        "/etc/dnsmasq-conf.conf"
        "/var/lib/dnsmasq/dns-server.conf"
      ];

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
    # dnsmasq's "interface" list above includes pihole-shim with
    # bind-interfaces = true - with bind-interfaces, dnsmasq refuses to
    # start at all if a listed interface doesn't exist yet. pihole-shim
    # (modules/network.nix) has RequiredForOnline = "no", so nothing
    # otherwise guarantees it exists before dnsmasq starts (this already
    # caused one transient race, self-healed by Restart=always above).
    # The scarier case is scripts/dns-failover.sh's `bypass` command,
    # the emergency "get LAN DNS working right now" escape hatch, which
    # works by restarting dnsmasq - if pihole-shim were ever genuinely
    # absent (not just late), dnsmasq couldn't start at all, and the
    # emergency recovery path would fail in exactly the scenario it
    # exists for. This ordering dependency makes dnsmasq wait for the
    # pihole-shim device unit specifically, without touching
    # bind-interfaces semantics for any interface (br-lan/tailscale0
    # already work fine today, so leave their behavior alone). Unit name
    # confirmed live: `systemctl list-units | grep pihole-shim` shows
    # "sys-subsystem-net-devices-pihole\x2dshim.device".
    after = [ "sys-subsystem-net-devices-pihole\\x2dshim.device" ];
    wants = [ "sys-subsystem-net-devices-pihole\\x2dshim.device" ];
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
    "C /var/lib/dnsmasq/dns-server.conf 0644 dnsmasq dnsmasq - ${./dhcp-dns-server.seed}"
  ];
}
