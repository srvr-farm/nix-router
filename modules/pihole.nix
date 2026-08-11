{ pkgs, ... }:
let
  piholeNet = "pihole-net";
  lanIface = "br-lan";
in
{
  # Only container workload on this box - Podman avoids running a full
  # Docker daemon for one container, and is the more NixOS-idiomatic
  # default when nothing else already needs Docker specifically.
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # Pi-hole gets its own MAC/IP on br-lan via macvlan, rather than host
  # networking, so it can bind :53 without colliding with dnsmasq's own
  # :53 on 10.0.0.1 - each has its own IP, no port conflict possible.
  # This does mean the router's own network namespace generally can't
  # reach 10.0.0.53 directly (a well-known macvlan-bridge-mode
  # limitation - only other LAN hosts can) - not a problem here, since
  # the router's own local DNS resolution (networking.nameservers)
  # stays pointed at dnsmasq, not Pi-hole.
  systemd.services.podman-network-pihole = {
    description = "Create the macvlan network the Pi-hole container attaches to";
    after = [ "network-online.target" "systemd-networkd.service" ];
    wants = [ "network-online.target" ];
    # "podman-pihole.service" is the container service Task 2 creates -
    # NixOS's oci-containers module names it "${backend}-${name}.service"
    # by default (confirmed against the module source).
    before = [ "podman-pihole.service" ];
    requiredBy = [ "podman-pihole.service" ];
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      current_gw=$(podman network inspect ${piholeNet} --format '{{range .Subnets}}{{.Gateway}}{{end}}' 2>/dev/null || true)
      if [ "$current_gw" != "10.0.0.254" ]; then
        # A container attached to this network blocks removing it -
        # explicitly remove it first. It'll be recreated by
        # podman-pihole.service's own pre-start, which already does
        # this unconditionally on every start regardless (this is
        # NixOS's oci-containers module's own standard behavior, not
        # something added here).
        podman rm -f pihole 2>/dev/null || true
        podman network rm -f ${piholeNet} 2>/dev/null || true
        podman network create -d macvlan \
          -o parent=${lanIface} \
          --subnet=10.0.0.0/24 --gateway=10.0.0.254 \
          ${piholeNet}
      fi
    '';
  };

  # Gravity DB, query log, and settings persist here across container/
  # image recreation. Pi-hole manages ownership/permissions inside this
  # directory itself on first start.
  systemd.tmpfiles.rules = [
    "d /var/lib/pihole/etc-pihole 0755 root root -"
  ];

  virtualisation.oci-containers.containers.pihole = {
    image = "pihole/pihole:2026.07.2";
    environment = {
      TZ = "America/Los_Angeles";
      # Same 4 resolvers dnsmasq already uses (modules/dhcp-dns.nix).
      FTLCONF_dns_upstreams = "1.1.1.1;1.0.0.1;208.67.222.222;208.67.220.220";
      # Conditional forwarding to dnsmasq for local names: the DHCP
      # domain, the srvr.farm split-horizon overrides (modules/dhcp-dns.nix),
      # and the LAN's reverse zone (so Pi-hole's query log shows real
      # device names, not raw IPs - the main reason to run it in
      # direct-resolver mode at all). Raw dnsmasq server=/domain/ip
      # syntax - FTL is dnsmasq-derived and understands it directly via
      # this env var, no mounted conf file needed.
      FTLCONF_misc_dnsmasq_lines = ''
        server=/callan.local/10.0.0.254
        server=/srvr.farm/10.0.0.254
        server=/0.0.10.in-addr.arpa/10.0.0.254
      '';
    };
    environmentFiles = [ "/etc/pihole-webpassword.env" ];
    volumes = [ "/var/lib/pihole/etc-pihole:/etc/pihole" ];
    extraOptions = [
      "--network=pihole-net"
      "--ip=10.0.0.53"
      "--mac-address=02:00:00:00:00:53"
    ];
  };
}
