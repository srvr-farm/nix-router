{ config, lib, pkgs, ... }:
{
  # We hand-roll the whole ruleset with nftables directly rather than the
  # high-level networking.firewall module, since we need custom DNAT/hairpin
  # behavior that maps 1:1 onto OPNsense's port-forward + NAT-reflection setup.
  networking.firewall.enable = false;
  networking.nftables.enable = true;

  # The flowtable below binds to the real "wan"/"br-lan" netdevs, which
  # don't exist inside the Nix build sandbox - `nft -c` (NixOS's default
  # build-time ruleset syntax check) fails trying to resolve them
  # ("Could not process rule: No such file or directory"), a known
  # incompatibility between nftables flowtables and static ruleset
  # checking. Disabling the check trades that safety net away in exchange
  # for flowtable support; double check ruleset syntax by hand (or via
  # `nft -c` on a live system) after editing the ruleset below.
  networking.nftables.checkRuleset = false;

  # OPNsense enabled blockpriv/blockbogons on WAN (drop spoofed/private
  # source addresses arriving from the internet). Strict reverse-path
  # filtering is the standard Linux equivalent.
  boot.kernel.sysctl = {
    "net.ipv4.conf.wan.rp_filter" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
  };

  # ------------------------------------------------------------------
  # WAN is DHCP-assigned, so port-forward/hairpin DNAT rules match
  # against a `wan_ip` set kept in sync with the interface's current
  # address, rather than a hardcoded IP. This is the direct equivalent
  # of pf's `to (igc0)` destination match, which always meant "whatever
  # igc0's current address is" - reflection worked from LAN/loopback/
  # tailscale as ingress, but only for traffic actually addressed to
  # the WAN IP itself (traffic to br-lan's or tailscale's own address
  # is deliberately NOT touched, so e.g. admin SSH to the router's own
  # LAN/tailscale address keeps reaching the router, not 10.0.0.80).
  # ------------------------------------------------------------------
  systemd.services.nft-wan-ip-sync = {
    description = "Keep the nftables wan_ip set in sync with the WAN interface's current address";
    after = [ "network.target" "systemd-networkd.service" "nftables.service" ];
    wants = [ "nftables.service" ];
    path = [ pkgs.iproute2 pkgs.nftables ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -eu
      addr=$(ip -4 -o addr show dev wan | awk '{print $4}' | cut -d/ -f1 | head -n1)
      nft flush set inet nat wan_ip
      if [ -n "''${addr:-}" ]; then
        nft add element inet nat wan_ip "{ $addr }"
      fi
    '';
  };

  systemd.timers.nft-wan-ip-sync = {
    description = "Periodically refresh the nftables wan_ip set";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "30s";
    };
  };

  networking.nftables.ruleset = ''
    table inet nat {
      set wan_ip {
        type ipv4_addr
      }

      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        # Never DNAT traffic addressed to the router's own LAN address or
        # loopback - only the WAN address is subject to port-forwarding/
        # hairpin, matching OPNsense's `to (igc0)` scoped rdr rules.
        ip daddr 10.0.0.1 return
        ip daddr 127.0.0.1 return

        ip daddr @wan_ip jump portforwards
      }

      chain portforwards {
        # `dnat ip to` (not bare `dnat to`) is required here because this is
        # a dual-stack `inet` table - nftables needs the address family
        # disambiguated even though every target below is IPv4.

        # Minecraft
        tcp dport 25565 dnat ip to 10.0.0.65:25565

        # Mailcow
        tcp dport 25   dnat ip to 10.0.0.60:25
        tcp dport 465  dnat ip to 10.0.0.60:465
        tcp dport 587  dnat ip to 10.0.0.60:587
        tcp dport 143  dnat ip to 10.0.0.60:143
        tcp dport 993  dnat ip to 10.0.0.60:993
        tcp dport 110  dnat ip to 10.0.0.60:110
        tcp dport 995  dnat ip to 10.0.0.60:995
        tcp dport 4190 dnat ip to 10.0.0.60:4190

        # TF2
        tcp dport 27015 dnat ip to 10.0.0.10:27015
        udp dport 27015 dnat ip to 10.0.0.10:27015
        udp dport 27020 dnat ip to 10.0.0.10:27020
        udp dport 27005 dnat ip to 10.0.0.10:27005

        # Web Proxy (-> jenkins host, 10.0.0.10)
        tcp dport 443 dnat ip to 10.0.0.10:443
        tcp dport 80  dnat ip to 10.0.0.10:80

        # NAS-01 IPMI (external 8080/8043 -> internal 80/443)
        tcp dport 8080 dnat ip to 10.0.0.104:80
        tcp dport 8043 dnat ip to 10.0.0.104:443

        # Jenkins
        tcp dport 50000 dnat ip to 10.0.0.10:50000

        # SSH (three separate external-port forwards, as configured)
        tcp dport 22    dnat ip to 10.0.0.80:22
        tcp dport 51413 dnat ip to 10.0.0.157:51413
        tcp dport 8337  dnat ip to 10.0.0.10:8337
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # OPNsense outbound NAT mode was "automatic": masquerade everything
        # leaving via WAN, regardless of source (covers LAN clients and
        # Tailscale exit-node/subnet-router egress alike).
        oifname "wan" masquerade
      }
    }

    table inet filter {
      # Software flow offload: after a TCP/UDP flow's first packets pass
      # the forward chain below and hit conntrack "established", later
      # packets are handed to this flowtable and skip full ruleset +
      # conntrack evaluation entirely. This is the standard software
      # NAT/routing fast-path used to keep CPU load down at 10G rates -
      # the X540/Solarflare NICs here don't support true hardware flow
      # offload (that's a SmartNIC feature), so this is the software
      # equivalent, paired with the NIC-level TSO/GSO/checksum offload
      # and RSS multi-queueing configured in modules/network.nix.
      flowtable fastpath {
        hook ingress priority filter
        devices = { wan, br-lan }
      }

      chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # LAN and Tailscale are fully trusted, matching OPNsense's
        # allow-all floating rules for LAN_GROUP/opt5/opt2.
        iifname "br-lan" accept
        iifname "tailscale0" accept

        icmp type echo-request accept
        icmpv6 type { echo-request, nd-router-advert, nd-router-solicit, nd-neighbor-advert, nd-neighbor-solicit } accept

        # Nothing else is exposed directly on WAN (OPNsense's own admin
        # GUI on :8443 has no equivalent here - router administration is
        # via SSH over LAN/Tailscale only).
      }

      chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop

        # Return path for the DNAT'd port-forwards above, from any ingress.
        ct status dnat accept

        # LAN can reach anything (WAN, Tailscale) - matches the "Any
        # Internal"/LAN_GROUP allow-all floating rules.
        iifname "br-lan" accept

        # Tailscale subnet-router/exit-node traffic in both directions.
        iifname "tailscale0" accept
        oifname "tailscale0" accept

        # Hand established TCP/UDP flows crossing wan<->br-lan to the
        # flowtable fast path (defined above) for the rest of their
        # lifetime.
        meta l4proto { tcp, udp } flow add @fastpath
      }

      chain output {
        type filter hook output priority 0; policy accept;
      }
    }
  '';
}
