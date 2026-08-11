{ lib, ... }:
let
  # RxChannels/TxChannels/CombinedChannels enable RSS (multi-queue, one
  # queue per core) so packet processing isn't serialized on one CPU;
  # the *SegmentationOffload/*ChecksumOffload options push TSO/GSO/GRO and
  # checksumming onto the NIC itself. Both ixgbe and sfc_siena support all
  # of this in hardware - this is the offload story on generic 10G NICs
  # (there's no SmartNIC-style hardware NAT offload available here); the
  # software side of the story is the nftables flowtable in firewall.nix.
  #
  # LargeReceiveOffload is deliberately OFF (and applied here as an
  # explicit `false`, not just an omission) despite being applied to every
  # other *Offload knob: LRO irreversibly merges received TCP segments in
  # the NIC before the stack ever sees individual packet boundaries, which
  # is only safe for frames that stay local. Every interface here is
  # either the WAN side of IP forwarding or a br-lan bridge member -
  # i.e. none of them ever just locally consume what they receive - so
  # LRO corrupts/reorders forwarded traffic instead of speeding it up.
  # Confirmed as the cause of a real slow-internet report (2026-08-05):
  # WAN showed 802 out-of-order segments and a collapsed TCP cwnd on an
  # otherwise 100%-idle router. GRO (the forwarding-safe equivalent -
  # NIC-batched but stack-visible per-packet, and properly resegmented via
  # GSO on the way back out) stays on by default at the kernel level
  # without needing to be listed here, so this costs nothing CPU-wise.
  offload = {
    TCPSegmentationOffload = true;
    GenericSegmentationOffload = true;
    LargeReceiveOffload = false;
    ReceiveChecksumOffload = true;
    TransmitChecksumOffload = true;
    CombinedChannels = 8;
  };
in
{
  # ---------------------------------------------------------------------
  # Physical topology - Supermicro X10SLH-N6-ST031 (Xeon E3-1281 v3, 32GB),
  # replacing the original i7-8700 box. 8 usable 10G-capable ports:
  #
  #   WAN    04:00.0  Intel X540-AT2       0c:c4:7a:59:8a:dc   DHCP (v4+v6)
  #   LAN0   03:00.0  Solarflare SFC9020   00:0f:53:07:99:50   \ uplink to
  #   LAN1   03:00.1  Solarflare SFC9020   00:0f:53:07:99:51   / switch 1/2
  #   LAN2   04:00.1  Intel X540-AT2       0c:c4:7a:59:8a:dd   \ wireless
  #   LAN3   05:00.0  Intel X540-AT2       0c:c4:7a:59:8a:de   / AP uplinks
  #   LAN4   05:00.1  Intel X540-AT2       0c:c4:7a:59:8a:df   \
  #   LAN5   06:00.0  Intel X540-AT2       0c:c4:7a:59:8a:e0    > spare, up
  #   LAN6   06:00.1  Intel X540-AT2       0c:c4:7a:59:8a:e1   /  but unused
  #
  # All MACs were read directly from the X540 boot-agent firmware config
  # pages in BIOS setup (Advanced -> per-port "Intel(R) Ethernet Controller
  # X540-AT2" submenus) rather than from Linux, because 5 of the 6 X540
  # ports fail to probe under the stock kernel - see the CONFIG_PCI_IOV
  # note in hosts/router/configuration.nix for why and the intended fix.
  #
  # LAN0-6 are all bridged into one flat br-lan, same as the original
  # design - the switch uplinks, AP uplinks, and spare ports all land on
  # the same 10.0.0.0/24 network so nothing changes from a client's
  # perspective versus the box this replaces.
  # ---------------------------------------------------------------------

  boot.kernelModules = [ "ixgbe" "sfc_siena" "tcp_bbr" ];
  hardware.enableRedistributableFirmware = true;

  # Always-on, plugged-in router with headroom to spare - trade the small
  # power savings of dynamic frequency scaling for consistent low latency.
  # `schedutil` (the default) is fast but still has ms-scale ramp-up
  # lag from idle (800MHz) to full (4.1GHz) on bursty small-packet
  # traffic, which matters for a box whose whole job is first-hop latency.
  powerManagement.cpuFreqGovernor = "performance";

  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.hostName = "gateway";
  networking.domain = "callan.local";

  # IP forwarding (this box is a router)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;

    # BBR only affects sockets this box itself opens/accepts (SSH, DNS
    # upstream queries, Tailscale, nix substitution, the iperf3 server
    # below) - forwarded LAN<->WAN traffic is unaffected, since forwarding
    # never touches the router's own TCP stack/congestion control. Still
    # a straightforward win for admin responsiveness (SSH) and is what
    # every modern router/CDN defaults to over cubic. tcp_bbr is loaded
    # explicitly above since it's a module, not built in, on this kernel.
    "net.ipv4.tcp_congestion_control" = "bbr";

    # Defaults (208KB max) are conservative for a box with 10G NICs and
    # 32GB RAM doing its own local transfers (iperf3 tests, SSH, nix
    # fetches) - bumping the ceiling costs nothing idle (Linux still
    # auto-tunes within it) and removes a throughput cap on those local
    # connections. Doesn't affect the forwarding path either, same
    # reasoning as tcp_congestion_control above.
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 131072 16777216";
    "net.ipv4.tcp_wmem" = "4096 16384 16777216";
  };

  systemd.network.enable = true;

  # irqbalance spreads the multi-queue NIC interrupt load enabled below
  # across all 8 CPU cores instead of pinning it to CPU0.
  services.irqbalance.enable = true;

  # --- Stable interface naming by MAC, plus NIC offload -----------------
  systemd.network.links = {
    "10-wan" = {
      matchConfig.PermanentMACAddress = "0c:c4:7a:59:8a:dc";
      linkConfig = { Name = "wan"; } // offload;
    };
    "10-lan0" = {
      matchConfig.PermanentMACAddress = "00:0f:53:07:99:50";
      linkConfig = { Name = "lan0"; } // offload;
    };
    "10-lan1" = {
      matchConfig.PermanentMACAddress = "00:0f:53:07:99:51";
      linkConfig = { Name = "lan1"; } // offload;
    };
    "10-lan2" = {
      matchConfig.PermanentMACAddress = "0c:c4:7a:59:8a:dd";
      linkConfig = { Name = "lan2"; } // offload;
    };
    "10-lan3" = {
      matchConfig.PermanentMACAddress = "0c:c4:7a:59:8a:de";
      linkConfig = { Name = "lan3"; } // offload;
    };
    "10-lan4" = {
      matchConfig.PermanentMACAddress = "0c:c4:7a:59:8a:df";
      linkConfig = { Name = "lan4"; } // offload;
    };
    "10-lan5" = {
      matchConfig.PermanentMACAddress = "0c:c4:7a:59:8a:e0";
      linkConfig = { Name = "lan5"; } // offload;
    };
    "10-lan6" = {
      matchConfig.PermanentMACAddress = "0c:c4:7a:59:8a:e1";
      linkConfig = { Name = "lan6"; } // offload;
    };
  };

  # --- br-lan bridge (all 7 LAN-role ports, one flat switched network) --
  systemd.network.netdevs."20-br-lan" = {
    netdevConfig = {
      Kind = "bridge";
      Name = "br-lan";
    };
  };

  # Host-side macvlan interface, same parent (br-lan) as the Pi-hole
  # container's own macvlan network (modules/pihole.nix) - lets the
  # container reach something running on the router itself. macvlan
  # bridge-mode isolates a child from its own parent device's IP stack
  # in BOTH directions (confirmed via live testing during Task 2 - the
  # router can't reach 10.0.0.53 directly, and the container can't
  # reach 10.0.0.1 directly either) - but macvlan SIBLINGS on the same
  # parent CAN reach each other. This interface is that sibling:
  # dnsmasq listens on its address too (modules/dhcp-dns.nix), and it's
  # what the Pi-hole container uses as its gateway/conditional-
  # forwarding target instead of 10.0.0.1.
  systemd.network.netdevs."25-pihole-shim" = {
    netdevConfig = {
      Kind = "macvlan";
      Name = "pihole-shim";
    };
    macvlanConfig.Mode = "bridge";
  };

  systemd.network.networks = {
    "30-wan" = {
      matchConfig.Name = "wan";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      dhcpV4Config.UseDNS = false;
      dhcpV6Config.UseDNS = false;
      linkConfig.RequiredForOnline = "routable";
    };

    "40-lan-members" = {
      matchConfig.Name = [ "lan0" "lan1" "lan2" "lan3" "lan4" "lan5" "lan6" ];
      networkConfig.Bridge = "br-lan";
      linkConfig.RequiredForOnline = "enslaved";
    };

    "50-br-lan" = {
      matchConfig.Name = "br-lan";
      address = [ "10.0.0.1/24" ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
        # Binds pihole-shim (defined above) to this interface as its
        # parent.
        MACVLAN = [ "pihole-shim" ];
      };
      # Static route: 10.0.1.0/24 ("Office Gateway" in OPNsense) reachable
      # directly on the LAN segment.
      routes = [
        { Destination = "10.0.1.0/24"; }
      ];
      linkConfig.RequiredForOnline = "routable";
    };

    # Ordinal is deliberately after "50-br-lan" (not before, despite the
    # netdev itself being "25-pihole-shim") - see the /32 note below for
    # why this network block must not install a second /24 route.
    "55-pihole-shim" = {
      matchConfig.Name = "pihole-shim";
      # /32, not /24: a /32 still lets this interface send/receive on the
      # L2 segment and be assigned 10.0.0.254, but it does NOT install a
      # second connected route for 10.0.0.0/24 - br-lan's "50-br-lan"
      # network block already installs that one. Two undifferentiated
      # /24 connected routes for the same prefix is a routing footgun:
      # today br-lan's wins (confirmed live), but which one wins is
      # decided by kernel/networkd route-add ordering, not anything
      # pinned here - accidental, not deliberate. A /32 here removes the
      # ambiguity outright rather than relying on ordering to keep
      # working. The container's own explicit 10.0.0.53/32 route below is
      # unrelated/unaffected - that's a separate, more-specific route
      # entry regardless of this interface's own prefix length.
      address = [ "10.0.0.254/32" ];
      networkConfig.ConfigureWithoutCarrier = true;
      # Not "routable" - this is an auxiliary side-channel interface,
      # not something the box's basic connectivity depends on; it
      # shouldn't be able to block systemd-networkd-wait-online.
      linkConfig.RequiredForOnline = "no";
      # Host route for the Pi-hole container's own address, more specific
      # than br-lan's own connected 10.0.0.0/24 route. Without this, any
      # packet the router sends to 10.0.0.53 - dnsmasq's own replies to
      # the container's conditional-forwarding queries, and NAT return
      # traffic for the container's own upstream DNS queries alike - gets
      # a routing-table lookup that resolves to br-lan (same-cost/first
      # connected route to that /24) instead of pihole-shim, since both
      # interfaces share the 10.0.0.0/24 subnet. That silently defeats
      # the whole point of the shim: br-lan is the macvlan *parent*,
      # which can't reach the container any more than 10.0.0.1 could
      # before this fix. Confirmed live via `ip route get 10.0.0.53`
      # resolving to `dev br-lan` pre-fix, and DNS working end-to-end
      # once this /32 route was in place (task-2b-report.md). Longest-
      # prefix-match makes this override br-lan's /24 for just this one
      # address, without touching routing for any other LAN host.
      routes = [
        { Destination = "10.0.0.53/32"; }
      ];
    };
  };
}
