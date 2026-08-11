# Pi-hole on the router

## Goal

Add Pi-hole as the LAN's DNS-level ad/tracker blocker, with real per-device
query stats (not just aggregate), and two independent ways to back out of
it quickly if something goes wrong - pausing filtering, and bypassing
Pi-hole entirely at the DHCP level if the container itself is unreachable.

## Context

The router runs dnsmasq (`modules/dhcp-dns.nix`) for DHCP + local hostname
resolution + `*.srvr.farm` split-horizon DNS overrides, at `10.0.0.1`.
There is no existing container infrastructure in this repo (`virtualisation.*`
is unused today). The firewall (`modules/firewall.nix`) fully trusts
`br-lan` and `tailscale0` in its input chain; WAN never gets a rule for
anything not explicitly port-forwarded.

There's no native NixOS module for Pi-hole in nixpkgs (confirmed: only a
Prometheus exporter for an *existing* Pi-hole exists at
`nixos/modules/services/monitoring/prometheus/exporters/pihole.nix`) -
Pi-hole is designed around its own installer/updater, not a declarative
config surface, so the standard and only realistic path on NixOS is
running the official `pihole/pihole` container image declaratively via
`virtualisation.oci-containers`.

## Decisions

**Pi-hole is the LAN's DNS server directly** (not sitting behind dnsmasq
as a forwarder-only target). DHCP hands out Pi-hole's IP as the DNS
server. This is what gives Pi-hole real per-device query stats/dashboard
and per-client blocking - the main reason to run Pi-hole instead of just
feeding a blocklist into dnsmasq's own `address=` directives.

**Runtime: Podman**, via `virtualisation.oci-containers.backend = "podman"`.
No existing Docker usage in this repo to share a daemon with, and Podman
is the lighter/more NixOS-idiomatic default for a single container.

**Networking: macvlan**, giving the Pi-hole container its own MAC/IP
(`10.0.0.53`, proposed - free at time of writing, sits below the dynamic
pool which starts at `.100`) attached to `br-lan`, rather than host
networking. This avoids a port-53 conflict with dnsmasq entirely (each
gets its own IP:53) and is the standard pattern for running Pi-hole
alongside an existing DHCP server.

Consequence of macvlan: the *host* (router) generally cannot reach a
macvlan container's IP directly (a well-known Linux macvlan-bridge-mode
limitation) - only other hosts on the L2 segment can. This doesn't matter
here because the router's own local DNS resolution (`networking.nameservers
= [ "127.0.0.1" ]`) stays pointed at dnsmasq, not Pi-hole; dnsmasq never
needs to query Pi-hole.

Also as a consequence of macvlan: LAN-client <-> Pi-hole DNS traffic is
pure L2 switching over `br-lan`'s physical segment - it never enters the
router's own IP stack, so `modules/firewall.nix`'s nftables chains don't
see it and need no changes. WAN (a separate physical interface, not part
of `br-lan`) was never reachable regardless.

## DNS resolution chain

- DHCP option 6 (DNS server) changes from `10.0.0.1` to `10.0.0.53`.
- Pi-hole conditionally forwards to dnsmasq at `10.0.0.1` for:
  - `*.callan.local` (the DHCP-derived local domain)
  - `*.srvr.farm` (the split-horizon overrides in `modules/dhcp-dns.nix`)
  - the `10.0.0.0/24` reverse zone (`0.0.10.in-addr.arpa`), so Pi-hole's
    query log/dashboard show real device names instead of raw IPs -
    without this, most of the value of running Pi-hole in direct-resolver
    mode is lost.
- Everything else: Pi-hole applies blocklists, then forwards upstream to
  the same 4 resolvers dnsmasq already uses (1.1.1.1, 1.0.0.1,
  208.67.222.222, 208.67.220.220).
- dnsmasq is otherwise unchanged: still does DHCP, still authoritative for
  local hostnames/overrides, still uses its own upstream servers for the
  router's own local queries.
- Default Pi-hole blocklists (gravity) are used as-is; no custom list
  curation in scope here.

## Resilience / "easily disable"

Two independent, purpose-built on-router scripts (same style/installation
pattern as `dhcp-static`/`dhcp-leases`/`lan-hosts` from
`modules/dhcp-tools.nix`): packaged via `pkgs.writeShellApplication` and
installed onto the router's system PATH so they survive a full reimage.

- **`pihole-toggle {on|off|status} [duration]`** - thin wrapper around
  Pi-hole's own `pihole disable`/`pihole enable` CLI (invoked via `podman
  exec`). Pauses/resumes filtering while Pi-hole keeps serving DNS
  normally - fast, no interruption. For "is this site broken because of a
  block."

- **`dns-failover {status|pihole|bypass}`** - the actual emergency escape
  hatch, for when the Pi-hole container itself is down/unreachable and
  LAN DNS needs to work *now*. `bypass` rewrites a small runtime dnsmasq
  config snippet's `dhcp-option=option:dns-server,...` line from Pi-hole's
  IP back to dnsmasq's own (`10.0.0.1`, which still forwards straight
  upstream, unfiltered, exactly like today), then does a full `systemctl
  restart dnsmasq` to apply it. `pihole` flips it back to `10.0.0.53`.

  dhcp-option values are **not** SIGHUP-reloadable (unlike the
  `dhcp-hostsfile` reservations from the last change) - dnsmasq only
  re-reads specific files (`dhcp-hostsfile`, `/etc/hosts`, the leases
  file, etc.) on SIGHUP, not arbitrary options, so this needs a real
  restart. That's still a sub-second blip, not a redeploy, and it's a
  wholly separate, much smaller Nix-managed file (analogous to the
  `dhcp-static-hosts.seed` -> runtime-file pattern from last time) than
  the full dnsmasq config, so the restart is fast and low-risk.

  Existing clients that already have a Pi-hole-IP lease keep using it
  until they renew (max 12h, per the current `dhcp-range` lease time) -
  `bypass` doesn't force-renew every client. Worth noting as an accepted
  limitation rather than solving it here (e.g. no active lease-renewal
  push).

- Podman restarts the Pi-hole container automatically on failure/reboot
  (same resilience posture as the `Restart=always` fix already made for
  dnsmasq).

## Secrets & persistence

Following the existing `secrets/ddclient.conf` pattern: `secrets/
pihole-webpassword` (gitignored, `.example` template committed) holds the
admin UI password, deployed by hand onto the router (never through the
Nix store, never committed) and loaded into the container via an env
file. Exact env var name(s) depend on the Pi-hole image version in use at
implementation time (Pi-hole v6 changed its config env var conventions
from earlier versions) - to be confirmed against that image's current
documentation during implementation, not guessed here.

Pi-hole's own state (gravity DB/blocklists, query log, settings) persists
across container/image recreation via bind-mounted host directories under
`/var/lib/pihole/` (e.g. `/var/lib/pihole/etc-pihole`,
`/var/lib/pihole/etc-dnsmasq.d`), matching Pi-hole's documented Docker
persistence layout.

## Out of scope

- Custom/curated blocklists beyond Pi-hole's defaults.
- IPv6 DNS (this LAN's DHCP is v4-only today; no v6 client DNS to handle).
- Prometheus/netdata integration for Pi-hole metrics (the exporter found
  in nixpkgs is a possible future addition, not part of this change).
- Automatically forcing existing DHCP leases to renew after `dns-failover
  bypass`/`pihole` - clients pick up the change on their next natural
  renewal.
