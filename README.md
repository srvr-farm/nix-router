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
  disko.nix            # disk partitioning (single SATA SSD)
modules/
  network.nix          # interfaces, bridge, static route
  firewall.nix          # nftables: NAT, port-forwards, trust model
  dhcp-dns.nix           # dnsmasq: DHCP reservations + split-horizon DNS
  tailscale.nix          # subnet router + exit node
  ddns.nix                # Cloudflare dynamic DNS
  ssh.nix                  # root SSH keys/password carried over
secrets/
  ddclient.conf              # real Cloudflare tokens (gitignored)
  ddclient.conf.example      # safe-to-commit template
  tailscale-authkey.example  # instructions, not a real key
```

Validated with `nix flake check` / `nix eval` via the `nixos/nix` Docker
image (no local Nix install on the machine this was written on) - not yet
boot-tested on the actual router hardware. See MIGRATION.md's "What I could
not test" section before paving the disk.
