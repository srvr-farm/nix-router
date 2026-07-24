# OPNsense → NixOS router migration

This repo is a NixOS flake meant to replace the OPNsense install currently
running on `gateway.srvr.farm` (10.0.0.1) with the *same* functionality:
same static IPs, same DHCP reservations, same port-forwards/NAT, same
routing, same DNS split-horizon, same Tailscale/DDNS behavior. It does **not**
try to replicate OPNsense's internal architecture (pf, unbound, dhcpd, ...) -
it uses systemd-networkd, nftables, and dnsmasq instead, per your instruction
that the *how* doesn't matter.

Everything here was pulled live from the router on 2026-07-24 via SSH
(`root@10.0.0.1`, key-based auth already worked) and cross-checked against
`config.xml`, `ifconfig -a`, `netstat -rn`, `pfctl -sn`/`-sr`, and hardware
queries (`pciconf`, `gpart show`, `camcontrol devlist`). I did not use the
API key in `api-key` - it's a single 80-char string with no `key:secret`
separator, so I couldn't tell how to split it for OPNsense's Basic-Auth API
scheme, and SSH access already worked and was more direct for a full config
dump anyway.

**One thing worth flagging upfront:** `gateway.srvr.farm` resolves to
10.0.0.10 (a different box, identifying itself as `jenkins.srvr.farm`), not
10.0.0.1. That's not a mistake on your end - the router's own Unbound config
has a deliberate split-horizon override sending `gateway.srvr.farm` to
10.0.0.10, presumably because that's where a reverse proxy or app named
"gateway" lives. It's carried over as-is in `modules/dhcp-dns.nix`. If that's
not what you want, that's the line to change.

## Hardware

Single box: Intel i7-8700 (6c/12t), 8GB RAM, one 120GB Samsung 850 EVO SATA
SSD, GPT-partitioned (EFI + one root partition) - see `hosts/router/disko.nix`.
7 NICs, pinned by MAC in `modules/network.nix` so Linux's PCI enumeration
order can't shuffle interface roles:

| Role | OPNsense name | Chip                  | Linux driver | MAC |
|------|---------------|------------------------|--------------|-----|
| WAN  | igc0 (wan)    | Intel I226-V           | `igc`        | 02:76:c6:00:b1:b3 |
| LAN0 | em0 (lan)     | Intel I219-LM          | `e1000e`     | 00:d8:61:3e:2b:a9 |
| LAN1 | igc1 (opt1)   | Intel I226-V           | `igc`        | 02:76:c6:00:b5:9b |
| LAN3 | sfxge0 (opt3) | Solarflare SFC9020 10G | `sfc`        | 00:0f:53:08:5e:5c |
| LAN4 | sfxge1 (opt4) | Solarflare SFC9020 10G | `sfc`        | 00:0f:53:08:5e:5d |
| LAN5 | ix0 (opt6)    | Intel X540-AT2 10G     | `ixgbe`      | 00:e0:ed:90:e7:17 |
| LAN6 | ix1 (opt7)    | Intel X540-AT2 10G     | `ixgbe`      | 00:e0:ed:90:e7:18 |

All six LAN ports were bridged together in OPNsense (`bridge0`/opt5/BRIDGE0,
one flat switched network) - `modules/network.nix` recreates that as a Linux
bridge `br-lan` with the same MAC (58:9c:fc:00:2a:36) and the same static
address, 10.0.0.1/24.

## Networking (`modules/network.nix`)

- `wan`: DHCPv4 + DHCPv6 client, exactly like OPNsense's WAN.
- `br-lan`: static 10.0.0.1/24, bridges lan0/lan1/lan3/lan4/lan5/lan6.
- Static route: 10.0.1.0/24 ("Office Gateway" in OPNsense) as a direct/on-link
  route via br-lan - this mirrors the OPNsense static route, whose
  configured "gateway" was just the bridge's own address (no real next hop),
  and which `netstat -rn` showed as an interface route.

**Not carried over, because it wasn't actually live:**
- LAN-side IPv6 (DHCPv6 on opt5 had no `<enable>` in config.xml).
- The old `lan` interface's DHCP scope (10.10.0.10-245) - `lan` is just a
  bridge member now with no IP of its own, so that scope is dead config
  from before the bridge existed. Skipped.
- A second gateway named "hypervisor" (10.0.0.10 via opt5, "Hypervisor
  Gateway to Guest Subnet") existed in OPNsense's Gateways list but wasn't
  referenced by any static route or rule I could find. Also skipped -
  if you know what it was for, tell me and I'll wire up the equivalent.

## DHCP + DNS (`modules/dhcp-dns.nix`, dnsmasq)

Range 10.0.0.100-10.0.0.200, ~20 static reservations carried over from
OPNsense's opt5 dhcpd staticmaps, plus the *.srvr.farm split-horizon
overrides that were in Unbound's host overrides (so LAN clients keep
resolving things like `mark.srvr.farm` / `registry.srvr.farm` straight to
10.0.0.10 instead of round-tripping out to the internet and back in).

Upstream resolution: OPNsense's Unbound had forwarding *disabled*, i.e. it
was doing full recursive resolution itself. dnsmasq here instead forwards to
the same four resolvers OPNsense listed system-wide (1.1.1.1, 1.0.0.1,
208.67.222.222, 208.67.220.220). Functionally equivalent for every device on
the LAN; the only difference is who does the recursion.

**Two problems found in the source config that I did not silently
"resolve" for you:**

1. **IP conflict**: `ws-19` (Piano Workstation, MAC c8:3a:35:c0:39:d8) and
   `ws-12` (Leon's Desktop, MAC 98:8d:46:92:d5:51) were *both* statically
   mapped to 10.0.0.81 in OPNsense. That's not something two different
   DHCP servers can both honor. I kept ws-19's mapping (it appeared first)
   and left ws-12 unpinned (dynamic pool) - see the comment in
   `modules/dhcp-dns.nix`. Pick a free static IP for ws-12 and uncomment/
   edit that line.
2. **Duplicate hostname**: two different reservations were both named
   `ws-01` (10.0.0.6 and 10.0.0.80). Both static IPs are preserved, but I
   renamed the second one's dnsmasq hostname label to `ws-01-b` to avoid a
   dnsmasq startup conflict over a duplicate name. This only affects the
   auto-generated hostname-based DNS entry, not the IP address.

**Not carried over, because they were disabled/unused in the source config:**
Kea DHCP (disabled, legacy dhcpd was in use), the dnsmasq plugin itself
(disabled - OPNsense was using Unbound + dhcpd), captive portal (unconfigured).

## Firewall + NAT (`modules/firewall.nix`, nftables)

OPNsense's posture, translated directly:
- **Outbound NAT**: `automatic` mode → `oifname "wan" masquerade` for
  everything leaving via WAN (covers both normal LAN egress and Tailscale
  exit-node/subnet-router egress, same as before).
- **Port forwards**: all 21 NAT rules carried over 1:1 (table below).
- **NAT reflection/hairpin**: OPNsense had `enablenatreflectionhelper=yes`,
  meaning LAN clients (and the router itself, and Tailscale peers) hitting
  the WAN IP on a forwarded port get redirected same as external traffic
  would. Reproduced via an nftables set (`wan_ip`) kept in sync with the
  `wan` interface's current DHCP-assigned address by a small
  `nft-wan-ip-sync` systemd service/timer (30s refresh) - necessary because,
  unlike a static IP, there's no fixed address to hardcode into the ruleset.
  Traffic to br-lan's own address (10.0.0.1) or loopback is explicitly
  excluded from this, matching the original pf rules, so e.g. admin SSH to
  the router's own LAN or Tailscale address still reaches the router itself
  rather than getting redirected by the port 22 forward rule below.
- **Trust model**: LAN (`br-lan`) and Tailscale (`tailscale0`) are fully
  trusted in both the input and forward chains, matching OPNsense's
  allow-all floating rules for LAN_GROUP/opt5/opt2. WAN gets nothing beyond
  ICMP echo, the ICMPv6 ND/RA traffic IPv6 needs to function, and the
  specific DNAT'd ports below - default-deny otherwise.
- **Anti-spoofing**: OPNsense's blockpriv/blockbogons (dropping WAN-sourced
  packets claiming private/bogon addresses) is replaced with Linux strict
  reverse-path filtering (`rp_filter=1`) - same practical effect.
- **No equivalent for**: OPNsense's own admin web GUI on WAN:8443. NixOS has
  no such GUI; router administration is SSH over LAN/Tailscale only, which
  is a small security improvement, not a functionality regression against
  anything you listed as required (port-forwards/NAT/routing/static IPs).

### Port forward table (external → internal)

| Description | Proto | Ext. port | Internal target |
|---|---|---|---|
| Minecraft | tcp | 25565 | 10.0.0.65:25565 |
| Mailcow SMTP | tcp | 25 | 10.0.0.60:25 |
| Mailcow SMTPS | tcp | 465 | 10.0.0.60:465 |
| Mailcow Submission | tcp | 587 | 10.0.0.60:587 |
| Mailcow IMAP | tcp | 143 | 10.0.0.60:143 |
| Mailcow IMAPS | tcp | 993 | 10.0.0.60:993 |
| Mailcow POP3 | tcp | 110 | 10.0.0.60:110 |
| Mailcow POP3S | tcp | 995 | 10.0.0.60:995 |
| Mailcow ManageSieve | tcp | 4190 | 10.0.0.60:4190 |
| TF2 | tcp | 27015 | 10.0.0.10:27015 |
| TF2 | udp | 27015 | 10.0.0.10:27015 |
| TF2 | udp | 27020 | 10.0.0.10:27020 |
| TF2 | udp | 27005 | 10.0.0.10:27005 |
| Web Proxy | tcp | 443 | 10.0.0.10:443 |
| Web Proxy | tcp | 80 | 10.0.0.10:80 |
| NAS-01 IPMI | tcp | 8080 | 10.0.0.104:80 |
| NAS-01 IPMI | tcp | 8043 | 10.0.0.104:443 |
| Jenkins | tcp | 50000 | 10.0.0.10:50000 |
| SSH | tcp | 22 | 10.0.0.80:22 |
| SSH (really looks like torrent) | tcp | 51413 | 10.0.0.157:51413 |
| SSH | tcp | 8337 | 10.0.0.10:8337 |

**Not carried over, because disabled in the source config**: the OPNsense
Nginx reverse-proxy plugin (SNI routing for mark.srvr.farm/registry.srvr.farm
to 10.0.0.64/10.0.0.10) exists in config.xml but `enabled=0` - it isn't
actually in the traffic path today (the WAN:443/80 NAT rules above go
straight to 10.0.0.10). IDS/Suricata, Squid proxy, monit, and IPsec/Swanctl
were all likewise present but disabled/empty.

## Tailscale (`modules/tailscale.nix`)

Subnet router for 10.0.0.0/24, exit node, accepting routes from other
tailnet nodes - same flags OPNsense had set (`advertiseExitNode=1`,
`acceptSubnetRoutes=1`). That's also the explanation for why 10.0.1.0/24 and
10.1.1.0/24 show up as "trusted internal" networks in the OPNsense firewall
rules: they're subnet routes advertised by *other* tailnet nodes and
accepted here, not directly-attached networks.

The pre-auth key that was in OPNsense's config is not reused - it's almost
certainly already consumed by the existing node. Generate a fresh one and
drop it at `/etc/tailscale/authkey` (see `secrets/tailscale-authkey.example`),
or just run `tailscale up` interactively once after first boot.

## Dynamic DNS (`modules/ddns.nix`, ddclient)

Two Cloudflare accounts (srvr.farm, crowdcomputing.io) - real config already
filled in at `secrets/ddclient.conf` (gitignored, not committed). Deploy that
file to `/etc/ddclient/ddclient.conf` on the router (root:root, mode 0600).
**Verify the `protocol=cloudflare` field mapping against the actual ddclient
version in nixpkgs before trusting it** - this is a best-effort translation
of OPNsense's DynDNS fields, not something I could test end-to-end.

## What I could not test

I don't have a NixOS/Nix environment on this machine, only Docker, so I used
`nixos/nix:latest` in a container to sanity-check that the flake evaluates
(see below) - but I could not do a full `nixos-install` dry run or boot-test
this on the actual router hardware. Review the diff between this doc and
your own expectations before paving the disk.

## Cutover runbook

1. **Back up first.** Download OPNsense's config.xml (Diagnostics → Backup &
   Restore) somewhere safe, and note the WAN's current DHCP lease details in
   case you need to fall back quickly.
2. On a machine with Nix installed (or reuse the `nixos/nix` Docker
   container this was validated with):
   ```
   nix flake lock
   nix flake check
   ```
3. Build the installer ISO:
   ```
   nix build .#packages.x86_64-linux.iso
   ```
   (or use the stock NixOS minimal ISO from nixos.org - either works, since
   the installer just needs `git` + `disko` + network access to pull this
   flake).
4. Write the ISO to a USB stick, boot the router from it.
5. Confirm the disk device path (`ls -l /dev/disk/by-id/ | grep -i samsung`)
   and update `hosts/router/disko.nix` if it doesn't match
   `ata-Samsung_SSD_850_EVO_120GB`.
6. Partition + format:
   ```
   git clone <this repo> /tmp/nix-router   # or scp it over
   cd /tmp/nix-router
   sudo disko --mode disko ./hosts/router/disko.nix
   ```
7. Deploy the secrets that don't belong in git:
   ```
   mkdir -p /mnt/etc/ddclient /mnt/etc/tailscale
   cp secrets/ddclient.conf /mnt/etc/ddclient/ddclient.conf
   chmod 600 /mnt/etc/ddclient/ddclient.conf
   cp <your-fresh-tailscale-authkey> /mnt/etc/tailscale/authkey
   chmod 600 /mnt/etc/tailscale/authkey
   ```
8. Install:
   ```
   sudo nixos-install --root /mnt --flake /tmp/nix-router#router
   ```
9. Before rebooting, physically double check cabling: LAN0/1/3/4/5/6 need to
   land on the same physical ports OPNsense had them on (doesn't actually
   matter *which* physical port maps to which role since they're all bridged
   into the same flat network anyway - this only matters if you ever split
   them back into separate VLANs/subnets later).
10. Reboot into the new system. Verify, in order: `ip a` (br-lan has
    10.0.0.1/24, wan has a DHCP lease), `ping 1.1.1.1` from a LAN client,
    DHCP handout to a test device, DNS resolution of a *.srvr.farm override,
    the port-forwards from an external vantage point (e.g. curl the WAN IP
    on port 80/443, or nmap the forwarded ports), `tailscale status`.
11. Keep the old OPNsense disk/backup around until you're confident - this
    was not boot-tested on real hardware.
