# Prints a merged view of every hostname record this router's dnsmasq
# knows about: static DHCP reservations, active dynamic leases, and pure
# DNS split-horizon overrides (the *.srvr.farm address= entries). Run
# `lan-hosts --help` for details.
#
# Packaged via modules/dhcp-tools.nix (pkgs.writeShellApplication), which
# supplies the shebang, `set -euo pipefail`, and a curated PATH (including
# `dhcp-static`, which this script shells out to) - this file is a script
# *body*, not a standalone executable.

LEASES_FILE="/var/lib/dnsmasq/dnsmasq.leases"
prog="lan-hosts"

usage() {
  cat <<EOF
Usage:
  $prog [--source static|dynamic|dns|all] [--sort hostname|ip]
  $prog --help

Prints every hostname record this router's dnsmasq knows about, merged
from three sources:
  static    Static DHCP reservations (see dhcp-static). Always has both
            a hostname and (usually) a fixed IP.
  dynamic   Devices with an active DHCP lease but no static reservation.
            Hostname is whatever the client itself reported - shows as
            '*' if it didn't report one. Excludes MACs already covered
            by a static entry, to avoid double-listing.
  dns       Pure DNS overrides with no DHCP/MAC involvement at all (the
            *.srvr.farm split-horizon entries in modules/dhcp-dns.nix) -
            typically service/container names pointing at a host that
            itself has its own DHCP/static entry elsewhere in this list.

Flags:
  --source   Restrict to one source. Default: all.
  --sort     Sort by hostname (default) or ip.

Examples:
  $prog
  $prog --source static --sort ip
  $prog --source dns
EOF
}

die() {
  echo "$prog: $*" >&2
  exit 1
}

dnsmasq_conf_path() {
  systemctl show dnsmasq.service -p ExecStart --value 2>/dev/null \
    | grep -oE -- '-C [^[:space:]]+' | awk '{print $2}'
}

cmd_main() {
  local source="all" sort_key="hostname"
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source="${2:?--source needs static|dynamic|dns|all}"; shift 2 ;;
      --sort) sort_key="${2:?--sort needs hostname|ip}"; shift 2 ;;
      *) die "unrecognized argument: $1" ;;
    esac
  done
  case "$source" in static|dynamic|dns|all) ;; *) die "--source must be static, dynamic, dns, or all" ;; esac

  local rows=""

  if [ "$source" = "static" ] || [ "$source" = "all" ]; then
    local statics; statics="$(dhcp-static list --tsv 2>/dev/null || true)"
    if [ -n "$statics" ]; then
      rows+="$(echo "$statics" | awk -F'\t' '{printf "static\t%s\t%s\t%s\t%s\n", $2, $3, $1, $4}')"$'\n'
    fi
  fi

  if [ "$source" = "dynamic" ] || [ "$source" = "all" ]; then
    if [ -f "$LEASES_FILE" ]; then
      local statics_macs; statics_macs="$(dhcp-static list --tsv 2>/dev/null | cut -f1 || true)"
      local now; now="$(date +%s)"
      local dyn
      dyn="$(
        while read -r exp mac ip hostname _; do
          [ -z "${mac:-}" ] && continue
          [ "$exp" -lt "$now" ] && continue
          echo "$statics_macs" | grep -qix "$mac" && continue
          printf 'dynamic\t%s\t%s\t%s\t(dynamic lease)\n' "${hostname:-*}" "$ip" "$mac"
        done < "$LEASES_FILE"
      )"
      [ -n "$dyn" ] && rows+="$dyn"$'\n'
    fi
  fi

  if [ "$source" = "dns" ] || [ "$source" = "all" ]; then
    local conf; conf="$(dnsmasq_conf_path)" || true
    if [ -n "$conf" ] && [ -r "$conf" ]; then
      local dns
      dns="$(grep '^address=/' "$conf" | sed -E 's#^address=/([^/]+)/(.+)$#dns\t\1\t\2\t-\t(DNS override, no MAC)#')"
      [ -n "$dns" ] && rows+="$dns"$'\n'
    fi
  fi

  rows="$(echo "$rows" | grep -v '^$' || true)"
  if [ -z "$rows" ]; then
    echo "No records found for --source $source."
    return
  fi

  case "$sort_key" in
    ip) rows="$(echo "$rows" | sort -t $'\t' -k3,3V)" ;;
    hostname|*) rows="$(echo "$rows" | sort -t $'\t' -k2,2f)" ;;
  esac

  { printf 'SOURCE\tHOSTNAME\tIP\tMAC\tNOTE\n'; echo "$rows"; } | column -t -s $'\t'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cmd_main "$@"
