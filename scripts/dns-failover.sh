# Switches the LAN's DHCP-advertised DNS server between Pi-hole and a
# direct/unfiltered path (dnsmasq itself, forwarding straight upstream),
# for when the Pi-hole container is down/unreachable and LAN DNS needs to
# work right now. Run `dns-failover --help` for details.
#
# Packaged via modules/dhcp-tools.nix (pkgs.writeShellApplication), which
# supplies the shebang, `set -euo pipefail`, and a curated PATH - this
# file is a script *body*, not a standalone executable.

DNS_SERVER_CONF="/var/lib/dnsmasq/dns-server.conf"
PIHOLE_IP="10.0.0.53"
DIRECT_IP="10.0.0.1"
prog="dns-failover"

usage() {
  cat <<EOF
Usage:
  $prog status
  $prog pihole
  $prog bypass
  $prog --help

Switches which IP address DHCP hands out to LAN clients as their DNS
server, by rewriting $DNS_SERVER_CONF and restarting dnsmasq. This is the
emergency escape hatch for when the Pi-hole container itself is down or
unreachable - NOT the same as pausing ad-blocking (see pihole-toggle for
that, which is faster and doesn't touch DHCP at all).

Commands:
  status   Show which IP is currently being handed out.
  pihole   Hand out $PIHOLE_IP (Pi-hole) - the normal/steady state.
  bypass   Hand out $DIRECT_IP (dnsmasq itself, forwarding straight
           upstream, unfiltered) - use when Pi-hole is broken/down.

Both pihole/bypass restart dnsmasq (a sub-second blip) to apply the
change - dhcp-option values aren't SIGHUP-reloadable, unlike static DHCP
reservations (see dhcp-static). Devices that already hold a lease keep
using whatever DNS server they were handed until their lease renews (up
to 12h) - this doesn't force clients to pick up the change early.

Requires root (restarts a system service) - run with sudo.

Examples:
  $prog status
  sudo $prog bypass    # Pi-hole down - get LAN DNS working again now
  sudo $prog pihole    # Pi-hole's back - switch back
EOF
}

die() {
  echo "$prog: $*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "'$1' requires root - re-run with sudo."
  fi
}

current_ip() {
  [ -f "$DNS_SERVER_CONF" ] || { echo ""; return; }
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$DNS_SERVER_CONF" | head -n1
}

cmd_status() {
  local ip; ip="$(current_ip)"
  case "$ip" in
    "$PIHOLE_IP") echo "Currently handing out: $PIHOLE_IP (Pi-hole)" ;;
    "$DIRECT_IP") echo "Currently handing out: $DIRECT_IP (direct/bypass - dnsmasq, unfiltered)" ;;
    "") echo "No DNS server configured yet ($DNS_SERVER_CONF missing or empty)." ;;
    *) echo "Currently handing out: $ip (unrecognized - neither the known Pi-hole nor direct IP)" ;;
  esac
}

set_ip() {
  local ip="$1" who="$2"
  require_root "$who"
  printf 'dhcp-option=option:dns-server,%s\n' "$ip" > "$DNS_SERVER_CONF"
  chmod 0644 "$DNS_SERVER_CONF"
  systemctl restart dnsmasq
  echo "Now handing out: $ip"
}

cmd_pihole() {
  if ! timeout 2 bash -c "echo > /dev/tcp/$PIHOLE_IP/53" 2>/dev/null; then
    echo "Warning: $PIHOLE_IP:53 doesn't seem reachable right now - switching anyway, but double check Pi-hole is actually up." >&2
  fi
  set_ip "$PIHOLE_IP" pihole
}

cmd_bypass() {
  set_ip "$DIRECT_IP" bypass
}

cmd="${1:-status}"
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  status) cmd_status ;;
  pihole) cmd_pihole ;;
  bypass) cmd_bypass ;;
  *) usage; exit 1 ;;
esac
