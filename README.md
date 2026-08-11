# nix-router

NixOS flake for the home router at gateway.srvr.farm (10.0.0.1), migrated
from OPNsense. Functionality (static IPs, DHCP reservations, port-forwards/
NAT, routing, DNS split-horizon, Tailscale, DDNS) is meant to match the old
OPNsense config exactly; the implementation (systemd-networkd, nftables,
dnsmasq) is different by design.

**Start here: [MIGRATION.md](./MIGRATION.md)** - full spec of what was
carried over, what was deliberately dropped (and why), the two data
conflicts found in the source config that need a human decision, and the
step-by-step cutover runbook.

```
hosts/router/
  configuration.nix   # entrypoint, imports everything below
  disko.nix            # disk partitioning (dual SATA SSD, target = non-boot disk)
modules/
  network.nix          # interfaces, bridge, static route, NIC offload/RSS
  firewall.nix          # nftables: NAT, port-forwards, trust model, flowtable
  dhcp-dns.nix           # dnsmasq: DHCP reservations + split-horizon DNS
  tailscale.nix          # subnet router + exit node
  ddns.nix                # Cloudflare dynamic DNS
  ssh.nix                  # root + mark users, passwordless sudo for mark
  monitoring.nix            # netdata dashboard
  srvr-farm-tools.nix        # cpuwatch/memwatch/interfaces/diskwatch (nixpkgs-unstable toolchain)
  dhcp-tools.nix             # on-router CLI: dhcp-static, dhcp-leases, lan-hosts, dns-failover
  pihole.nix                  # Pi-hole container (Podman/macvlan) + DHCP cutover
secrets/
  ddclient.conf                     # real Cloudflare tokens (gitignored)
  ddclient.conf.example             # safe-to-commit template
  tailscale-authkey.example         # instructions, not a real key
  pihole-webpassword.env.example    # instructions, not a real password
```

Currently targets a Supermicro X10SLH-N6-ST031 (`mcallan@10.0.0.129`) -
see MIGRATION.md's "Hardware" section for the full port map and a real,
unresolved hardware bug (5 of 6 X540 10G ports fail to probe under the
stock kernel; the fix is believed but not yet confirmed on real hardware -
verify at first boot). `nix flake check` and the actual `diskoImage` build
(`nix build .#packages.x86_64-linux.diskoImage`, includes a full local
kernel compile) both pass end to end; not yet boot-tested on the real
hardware. See MIGRATION.md's "What I could not test" section before
paving the disk.
