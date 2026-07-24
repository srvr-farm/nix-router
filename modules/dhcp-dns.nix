{ ... }:
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

      # --- Static DHCP reservations, carried over from OPNsense's opt5
      #     dhcpd staticmaps -----------------------------------------------
      dhcp-host = [
        "18:47:3d:eb:d8:65,NPI04B2F6" # HP LaserJet Printer - no static IP in source config either
        "70:3a:cb:4e:87:72,wifi,10.0.0.2"
        "20:36:26:d7:c5:60,ap-01,10.0.0.3" # Omada WiFi AP 1
        "0c:c4:7a:06:80:ac,com-01,10.0.0.4" # Management NIC on com-01
        "20:36:26:d6:5f:60,ap-02,10.0.0.5" # Omada WiFi AP 2
        "f4:52:14:8c:5b:90,ws-01,10.0.0.6"
        "00:02:c9:50:0d:f4,ws-01-m,10.0.0.7" # Management NIC for ws-01
        "9c:7b:ef:bc:2b:42,bastion-01,10.0.0.8" # Bastion
        "50:eb:71:76:1e:43,ws-02,10.0.0.9"
        "58:47:ca:7a:b3:9a,nas-02,10.0.0.10"
        "5a:cc:06:34:5d:e7,nas-02-1,10.0.0.11"
        "58:47:ca:7a:b3:9c,nas-02-2,10.0.0.12"
        "0c:c4:7a:06:80:ad,com-01-m2,10.0.0.14" # com-01 backup management port
        "52:54:00:b5:06:12,ha,10.0.0.20" # Home Assistant
        "00:25:90:f5:6c:ff,com-02,10.0.0.40"
        "c4:8b:66:54:99:b1,nas-02-wifi,10.0.0.50" # nas-02 wireless connection
        "34:97:f6:32:74:30,ws-01-b,10.0.0.80" # source config also calls this host "ws-01" (dup of 10.0.0.6); renamed here to avoid a dnsmasq hostname clash
        "c8:3a:35:c0:39:d8,ws-19,10.0.0.81" # Piano Workstation

        # CONFLICT IN SOURCE CONFIG, NOT RESOLVED AUTOMATICALLY:
        # ws-12 / Leon's Desktop (MAC 98:8d:46:92:d5:51) was *also* statically
        # mapped to 10.0.0.81 in OPNsense, colliding with ws-19 above. That
        # can't be replicated as-is (one IP, two MACs), so it's left off the
        # static map here - the device will just get a dynamic pool address.
        # Pick a free static IP for it and add a line like:
        #   "98:8d:46:92:d5:51,ws-12,10.0.0.XX"

        "4c:82:a9:93:66:b9,ws-09,10.0.0.82" # Dmitri's Computer
        "9e:71:5b:6b:d9:08,px-01,10.0.0.90" # Pixel 9 Pro
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
}
