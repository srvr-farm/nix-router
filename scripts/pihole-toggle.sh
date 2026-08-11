# Pauses/resumes Pi-hole's ad/tracker blocking without touching DHCP or
# restarting anything - Pi-hole keeps serving DNS normally the whole
# time, just without (or with) filtering. Run `pihole-toggle --help` for
# details.
#
# Packaged via modules/pihole.nix (pkgs.writeShellApplication), which
# supplies the shebang, `set -euo pipefail`, and a curated PATH - this
# file is a script *body*, not a standalone executable.

prog="pihole-toggle"

usage() {
  cat <<EOF
Usage:
  $prog status
  $prog on
  $prog off [duration]
  $prog --help

Pauses or resumes Pi-hole's blocklist filtering, via 'podman exec pihole
pihole disable/enable'. Pi-hole keeps answering DNS queries the entire
time either way - this only toggles whether it filters them. Fast, no
service interruption. Good for "is this broken because Pi-hole is
blocking it, or something else."

This is NOT the tool for when Pi-hole itself is down/unreachable - see
dns-failover for that (it reroutes DHCP away from Pi-hole entirely).

Requires root - the container is managed by the system (root) Podman
instance, not a per-user one, so 'podman exec' needs sudo regardless of
which subcommand you run.

Commands:
  status          Show whether blocking is currently on or off.
  on              Resume blocking.
  off [duration]  Pause blocking. Optional duration (Pi-hole's own
                  syntax, e.g. '5m', '30s') auto-resumes after that long;
                  with no duration, stays off until 'on' is run.

Examples:
  sudo $prog off 5m     # quick "is it Pi-hole" check
  sudo $prog off        # pause indefinitely
  sudo $prog on
  sudo $prog status
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

cmd_status() {
  require_root status
  podman exec pihole pihole status
}

cmd_on() {
  require_root on
  podman exec pihole pihole enable
}

cmd_off() {
  require_root off
  local duration="${1:-}"
  if [ -n "$duration" ]; then
    podman exec pihole pihole disable "$duration"
  else
    podman exec pihole pihole disable
  fi
}

cmd="${1:-status}"
case "$cmd" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -gt 0 ] && shift

case "$cmd" in
  status) cmd_status ;;
  on) cmd_on ;;
  off) cmd_off "$@" ;;
  *) usage; exit 1 ;;
esac
