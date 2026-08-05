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

**Retargeted 2026-08-03** from the original i7-8700/single-SSD box to a
Supermicro X10SLH-N6-ST031 (Xeon E3-1281 v3, 4c/8t, 32GB RAM), reachable at
`mcallan@10.0.0.129` and running Ubuntu 24.04 at the time of retargeting. Two
120GB Samsung 850 EVO SATA SSDs:

- Boot disk (Ubuntu, untouched by this repo): serial `S21TNSAFC16808W`.
- Target disk for the NixOS image: serial `S21TNXAGB11943E` - this is, not
  coincidentally, the *original* i7-8700 box's old OPNsense/FreeBSD disk,
  physically relocated into this machine as its second drive. It still has
  a FreeBSD partition on it from that former life; the image build/write
  process below overwrites it.

**This board is legacy BIOS only** (no `/sys/firmware/efi`) - see
`hosts/router/configuration.nix` for why GRUB (not systemd-boot) is used,
and `hosts/router/disko.nix` for the GPT "BIOS boot" partition GRUB needs
in place of an EFI System Partition.

8 usable 10G-capable ports, pinned by MAC in `modules/network.nix` so
Linux's PCI enumeration order can't shuffle interface roles. All MACs were
read directly from the X540 boot-agent firmware pages in BIOS setup, not
from Linux - see the SR-IOV note below for why.

| Role | PCI addr | Chip                | Linux driver | MAC | Physical use |
|------|----------|----------------------|--------------|-----|---------------|
| WAN  | 04:00.0  | Intel X540-AT2 10G   | `ixgbe`      | 0c:c4:7a:59:8a:dc | Internet uplink |
| LAN0 | 03:00.0  | Solarflare SFC9020 10G | `sfc_siena` | 00:0f:53:07:99:50 | Switch uplink 1 |
| LAN1 | 03:00.1  | Solarflare SFC9020 10G | `sfc_siena` | 00:0f:53:07:99:51 | Switch uplink 2 |
| LAN2 | 04:00.1  | Intel X540-AT2 10G   | `ixgbe`      | 0c:c4:7a:59:8a:dd | Wireless AP 1 |
| LAN3 | 05:00.0  | Intel X540-AT2 10G   | `ixgbe`      | 0c:c4:7a:59:8a:de | Wireless AP 2 |
| LAN4 | 05:00.1  | Intel X540-AT2 10G   | `ixgbe`      | 0c:c4:7a:59:8a:df | Spare (up, unused) |
| LAN5 | 06:00.0  | Intel X540-AT2 10G   | `ixgbe`      | 0c:c4:7a:59:8a:e0 | Spare (up, unused) |
| LAN6 | 06:00.1  | Intel X540-AT2 10G   | `ixgbe`      | 0c:c4:7a:59:8a:e1 | Spare (up, unused) |

All 7 LAN-role ports are bridged into one flat `br-lan` (static 10.0.0.1/24) -
same flat-network design as the box this replaces, so nothing changes from a
LAN client's perspective (switch uplinks, AP uplinks, and the 3 spare ports
all land on the same network).

**SR-IOV / X540 hardware bug found during retargeting:** under the stock
Ubuntu kernel, only 1 of the 6 onboard X540 ports (04:00.0) actually probes;
the other 5 fail with `probe ... failed with error -5`, preceded by
`VF BAR ... can't assign; no space` in dmesg. Root cause: this board's
legacy BIOS can't fit the SR-IOV "VF BAR" address-space reservations all 6
ports advertise (64 potential VFs each, never actually used) into its PCI
MMIO window. Tried and confirmed *not* sufficient: kernel param
`intremap=no_x2apic_optout` (BIOS was opting out of x2APIC), kernel param
`pci=realloc`, and BIOS "Above 4G Decoding" (enabled + full power cycle, no
change). No SR-IOV toggle exists in this BIOS at the chipset or per-NIC
firmware level. The fix landed in `hosts/router/configuration.nix`:
`CONFIG_PCI_IOV=n` compiled into the kernel, so Linux never requests that
VF BAR space in the first place. This forces a local kernel build (no Hydra
binary cache hit for `system.build.toplevel`) and **has not been confirmed
to fix the other 5 ports - verify on first real boot** (`ip -br link`
should show all of wan/lan0-lan6 with carrier, not just wan+lan0+lan1).

## Networking (`modules/network.nix`)

- `wan`: DHCPv4 + DHCPv6 client, exactly like OPNsense's WAN.
- `br-lan`: static 10.0.0.1/24, bridges lan0 through lan6 (all 7 non-WAN
  ports - see the Hardware section above for what's physically plugged into
  each one).
- Static route: 10.0.1.0/24 ("Office Gateway" in OPNsense) as a direct/on-link
  route via br-lan - this mirrors the OPNsense static route, whose
  configured "gateway" was just the bridge's own address (no real next hop),
  and which `netstat -rn` showed as an interface route.
- **NIC offload + RSS**: every pinned interface gets TSO/GSO/GRO and
  checksum offload pushed onto the NIC, plus 8 combined RX/TX channels
  (RSS, one queue per core) so packet processing isn't serialized on a
  single CPU. `services.irqbalance` spreads the resulting per-queue
  interrupts across all cores. Requested because software routing on the
  original box was CPU-bound and capping throughput; see the flowtable
  note in the Firewall section below for the other half of that fix.

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
- **Flowtable fast-path offload**: established TCP/UDP flows crossing
  wan<->br-lan get handed to an nftables flowtable after their first few
  packets, skipping full ruleset + conntrack evaluation for the rest of
  the flow's lifetime. This is the software-level half of the CPU-offload
  work (the NIC-level half is in `modules/network.nix`) - X540/Solarflare
  are generic 10G NICs with no hardware NAT/flow-offload capability
  (that's a SmartNIC feature), so this software fast path plus NIC
  TSO/GSO/checksum offload and RSS is the realistic ceiling here.
  `networking.nftables.checkRuleset = false` had to be set because the
  flowtable's `devices = { wan, br-lan }` binding can't be validated by
  `nft -c` inside the Nix build sandbox (those netdevs don't exist there) -
  double-check ruleset syntax by hand after future edits.

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

`secrets/tailscale-authkey` (gitignored) now contains the actual pre-auth key
pulled from OPNsense's live config, at your request - but pre-auth keys are
normally single-use and this one is almost certainly already consumed by the
existing node, so **expect `tailscale-autoconnect.service` to fail on first
boot** with this key. If it does, either generate a fresh key at
https://login.tailscale.com/admin/settings/keys and overwrite
`/etc/tailscale/authkey` with it, or just delete that file and run
`tailscale up --advertise-routes=10.0.0.0/24 --advertise-exit-node
--accept-routes` interactively once after boot.

## Dynamic DNS (`modules/ddns.nix`, ddclient)

Two Cloudflare accounts (srvr.farm, crowdcomputing.io) - real config already
filled in at `secrets/ddclient.conf` (gitignored, not committed). Deploy that
file to `/etc/ddclient/ddclient.conf` on the router (root:root, mode 0600).
**Verify the `protocol=cloudflare` field mapping against the actual ddclient
version in nixpkgs before trusting it** - this is a best-effort translation
of OPNsense's DynDNS fields, not something I could test end-to-end.

## Users + SSH (`modules/ssh.nix`)

Root SSH access (password + the original three keys) is unchanged from the
initial migration. Added during retargeting: a `mark` user (wheel group,
passwordless sudo via `security.sudo.wheelNeedsPassword = false`) with the
same authorized_keys as root, matching what was already on the live Ubuntu
box's `~mcallan/.ssh/authorized_keys` (`opc_rsa` and `imaging_test_rsa`) so
existing access keeps working without changes.

## Build status

Nix (multi-user, daemon mode, official installer, flakes/nix-command enabled)
is installed on this machine. The flake evaluates cleanly, and the installer
ISO has been built for real:

```
nix build .#packages.x86_64-linux.iso
```

Result: `/home/mark/nixos-router-installer.iso` (1.3G)
sha256: `522f7601b1ea0859201f8d24f68b2f535a5d177e72b74f381a87623a27f0ac86`

That ISO boots into a minimal NixOS installer with `git` and `disko`
preinstalled - it does *not* itself contain the router config baked in
(booting it gives you a generic installer, not a pre-configured router). This
isn't the path actually used for the retarget below (see Option B), but it's
kept working in case the dd-image path ever needs a fallback.

The `diskoImage` output builds the actual installed `router` system (disko
layout + configuration.nix baked in, custom kernel with SR-IOV compiled out)
as a raw disk image sized to match the real target disk (~111.79 GiB, see
`hosts/router/disko.nix`), so it can be `dd`'d straight onto the drive with
no post-write partition-growing step:

```
nix build .#packages.x86_64-linux.diskoImage
sudo ./result --post-format-files secrets/ddclient.conf /etc/ddclient/ddclient.conf \
              --post-format-files secrets/tailscale-authkey /etc/tailscale/authkey
```

This produces `nixos-router.raw` (111G, per `hosts/router/disko.nix`'s
`imageSize`) in the current directory. It needs KVM and, because of the
custom kernel build (`CONFIG_PCI_IOV=n`, no Hydra binary cache hit), takes
noticeably longer than a normal disko image build.

Two real bugs were caught along the way, both now fixed:
- `dnat to` inside a dual-stack `inet nat` table needs `dnat ip to` to
  disambiguate address family, and `nd-router-advertisement` isn't a valid
  nftables ICMPv6 type keyword (it's `nd-router-advert`) - found building
  against the original hardware target.
- The flowtable added during retargeting can't pass NixOS's default
  build-time `nft -c` ruleset check, since its `devices = { wan, br-lan }`
  binding references netdevs that don't exist in the build sandbox - fixed
  via `networking.nftables.checkRuleset = false` in `modules/firewall.nix`.
- The kernel-config override to disable SR-IOV (`PCI_IOV = lib.kernel.no`)
  was silently overridden back to `y` by three Intel QAT crypto VF drivers
  and the Cisco USNIC Infiniband driver, all of which unconditionally
  `select PCI_IOV` in their Kconfig and are all irrelevant to this box -
  fixed by disabling those four options too (see the comment in
  `hosts/router/configuration.nix`).

`nixosConfigurations.router.config.system.build.toplevel` and the full
`diskoImage` build both complete cleanly end to end.

## What I could not test

**Not boot-tested on the actual router hardware.** The `router`
nixosConfiguration builds end to end, including the full `diskoImage`, which
is a stronger signal than just evaluation - but it's not the same as having
actually booted it. Two things specifically need verification at first real
boot on the Supermicro box:

1. **All 8 interfaces come up** - `ip -br link` should show `wan` and
   `lan0` through `lan6` all with carrier, not just the 3 that worked under
   Ubuntu (`wan`=04:00.0, `lan0`/`lan1`=the two Solarflare ports). The
   `CONFIG_PCI_IOV=n` kernel fix in `hosts/router/configuration.nix` is
   reasoned from dmesg evidence but was never confirmed against a real
   boot, since it requires the actual NixOS kernel rather than something
   testable under Ubuntu.
2. **GRUB actually boots** on this legacy-BIOS board - the disko image was
   built and validated on a different (UEFI) machine; the switch from
   systemd-boot to GRUB was made from reasoning about the hardware
   (`/sys/firmware/efi` absent on the target), not from a real boot test.

Review the diff between this doc and your own expectations before paving
the disk, and don't wipe anything you need until you've verified the new
system works. (The target disk - see Hardware above - already holds a
defunct copy of the *original* OPNsense install, not the live one; the live
OPNsense box, if it still exists, is untouched by any of this.)

## Cutover runbook

The target machine (`mcallan@10.0.0.129`, Supermicro X10SLH-N6-ST031) is
reachable over the network and already running Ubuntu on its *other* disk,
so this cutover writes the image directly to the second disk over SSH
rather than via a USB-SATA dock - no physical access to the router needed
for this part.

1. **Back up first.** The target disk (serial `S21TNXAGB11943E`) already
   holds a defunct FreeBSD/OPNsense install from this box's former life,
   which this process destroys - if that's not actually expendable, image
   it off first. If a *live* OPNsense box still exists elsewhere, this
   process doesn't touch it at all.
2. Build the image (needs KVM; forces a full local kernel compile because
   of the `CONFIG_PCI_IOV=n` patch, so budget real time for this):
   ```
   nix flake check
   nix build .#packages.x86_64-linux.diskoImage
   sudo ./result --post-format-files secrets/ddclient.conf /etc/ddclient/ddclient.conf \
                 --post-format-files secrets/tailscale-authkey /etc/tailscale/authkey
   ```
   Produces `nixos-router.raw` (111G, sparse - actual written content is
   much smaller) in the current directory.
3. Confirm the target disk is still `/dev/sda` (by-id serial
   `S21TNXAGB11943E`) and not, say, the Ubuntu boot disk, before writing
   anything:
   ```
   ssh mcallan@10.0.0.129 'ls -l /dev/disk/by-id/ | grep -i samsung; findmnt -no SOURCE /'
   ```
   The disk that does **not** match `findmnt`'s answer is the target.
4. Stream the image over SSH straight onto that disk. Since the raw file is
   sparse (mostly zeros) and mostly-empty ext4 compresses extremely well,
   compress in flight rather than pushing the full 111G over the wire:
   ```
   zstd -T0 -c nixos-router.raw | ssh mcallan@10.0.0.129 \
     'zstd -d | sudo dd of=/dev/disk/by-id/ata-Samsung_SSD_850_EVO_120GB_S21TNXAGB11943E bs=4M status=progress conv=fsync'
   ```
   **This overwrites the target device with no confirmation prompt** - step
   3 is not optional. No partition-growing step is needed afterward; the
   image is sized to fit the real disk exactly (see Hardware above).
5. Before rebooting into it: physically confirm which switches/APs/spares
   are cabled into which port matches the Hardware table above (doesn't
   actually matter *which* physical port maps to which role for
   functionality, since they're all bridged into the same flat network -
   only matters if you ever split them into separate VLANs later), and set
   this disk as the boot device (BIOS boot order, or `ipmitool chassis
   bootdev disk` for a one-time override) since Ubuntu's disk is still
   first in boot order.
6. Reboot into the new system and verify, in order:
   - `ip -br link` - **all 8** interfaces (`wan`, `lan0`-`lan6`) should show
     carrier, not just the 3 that worked under Ubuntu (see "What I could
     not test" above - this is the one open question from retargeting).
   - `ip a` - `br-lan` has 10.0.0.1/24, `wan` has a DHCP lease.
   - `ping 1.1.1.1` from a LAN client, DHCP handout to a test device, DNS
     resolution of a `*.srvr.farm` override.
   - The port-forwards from an external vantage point (e.g. curl the WAN IP
     on port 80/443, or nmap the forwarded ports).
   - `tailscale status`.
   - `ssh mark@10.0.0.1` with the carried-over keys, and `sudo -n true` to
     confirm passwordless sudo is live.
7. Keep the old boot disk/backups around until you're confident - none of
   this was boot-tested on the real hardware beforehand.
