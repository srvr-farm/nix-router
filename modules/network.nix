{ lib, ... }:
{
  # ---------------------------------------------------------------------
  # Physical topology, translated from the OPNsense config:
  #
  #   WAN   igc0    Intel I226-V      02:76:c6:00:b1:b3   DHCP (v4+v6)
  #   LAN0  em0     Intel I219-LM     00:d8:61:3e:2b:a9   \
  #   LAN1  igc1    Intel I226-V      02:76:c6:00:b5:9b    \
  #   LAN3  sfxge0  Solarflare SFC9020 00:0f:53:08:5e:5c     bridged into
  #   LAN4  sfxge1  Solarflare SFC9020 00:0f:53:08:5e:5d     br-lan, one
  #   LAN5  ix0     Intel X540-AT2    00:e0:ed:90:e7:17    / flat switched
  #   LAN6  ix1     Intel X540-AT2    00:e0:ed:90:e7:18   /  LAN (was OPNsense
  #                                                          bridge0/opt5)
  #
  # OPNsense named these by BSD driver (igc0, em0, ...); Linux will enumerate
  # them unpredictably by PCI order, so we pin stable names by MAC address
  # via systemd .link files rather than relying on enumeration order.
  # ---------------------------------------------------------------------

  boot.kernelModules = [ "e1000e" "igc" "ixgbe" "sfc" ];
  hardware.enableRedistributableFirmware = true;

  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.hostName = "gateway";
  networking.domain = "callan.local";

  # IP forwarding (this box is a router)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    # Matches OPNsense system tunables: don't act on/leak ICMP redirects.
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
  };

  systemd.network.enable = true;

  # --- Stable interface naming by MAC -----------------------------------
  systemd.network.links = {
    "10-wan" = {
      matchConfig.PermanentMACAddress = "02:76:c6:00:b1:b3";
      linkConfig.Name = "wan";
    };
    "10-lan0" = {
      matchConfig.PermanentMACAddress = "00:d8:61:3e:2b:a9";
      linkConfig.Name = "lan0";
    };
    "10-lan1" = {
      matchConfig.PermanentMACAddress = "02:76:c6:00:b5:9b";
      linkConfig.Name = "lan1";
    };
    "10-lan3" = {
      matchConfig.PermanentMACAddress = "00:0f:53:08:5e:5c";
      linkConfig.Name = "lan3";
    };
    "10-lan4" = {
      matchConfig.PermanentMACAddress = "00:0f:53:08:5e:5d";
      linkConfig.Name = "lan4";
    };
    "10-lan5" = {
      matchConfig.PermanentMACAddress = "00:e0:ed:90:e7:17";
      linkConfig.Name = "lan5";
    };
    "10-lan6" = {
      matchConfig.PermanentMACAddress = "00:e0:ed:90:e7:18";
      linkConfig.Name = "lan6";
    };
  };

  # --- br-lan bridge (replaces OPNsense's bridge0/opt5/BRIDGE0) ---------
  systemd.network.netdevs."20-br-lan" = {
    netdevConfig = {
      Kind = "bridge";
      Name = "br-lan";
      # Matches bridge0's actual MAC for byte-for-byte L2 parity; harmless
      # to drop this line if you'd rather let Linux assign one.
      MACAddress = "58:9c:fc:00:2a:36";
    };
  };

  systemd.network.networks = {
    "30-wan" = {
      matchConfig.Name = "wan";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      dhcpV4Config.UseDNS = false;
      # OPNsense had dhcp6-ia-pd-len=0: no prefix delegation was requested,
      # just a single WAN address - LAN-side IPv6 was not actually live, so
      # we don't request PD here either. Plain dhcpV6Config.UseDNS=false
      # keeps the resolver authoritative (dnsmasq), matching WAN's v4 side.
      dhcpV6Config.UseDNS = false;
      linkConfig.RequiredForOnline = "routable";
    };

    "40-lan-members" = {
      matchConfig.Name = [ "lan0" "lan1" "lan3" "lan4" "lan5" "lan6" ];
      networkConfig.Bridge = "br-lan";
      linkConfig.RequiredForOnline = "enslaved";
    };

    "50-br-lan" = {
      matchConfig.Name = "br-lan";
      address = [ "10.0.0.1/24" ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
      # Static route: 10.0.1.0/24 ("Office Gateway" in OPNsense) reachable
      # directly on the LAN segment - the OPNsense static route's "gateway"
      # was just the bridge's own address (no real next hop), which in
      # netstat showed up as an on-link/interface route. A destination-only
      # route here does the same: the kernel ARPs for 10.0.1.0/24 hosts
      # directly on br-lan.
      routes = [
        { Destination = "10.0.1.0/24"; }
      ];
      linkConfig.RequiredForOnline = "routable";
    };
  };
}
