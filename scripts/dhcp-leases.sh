# Lists this router's active/recent dynamic DHCP leases, and can promote
# one into a static reservation via dhcp-static. Run `dhcp-leases --help`
# for details.
#
# Packaged via modules/dhcp-tools.nix (pkgs.writeShellApplication), which
# supplies the shebang, `set -euo pipefail`, and a curated PATH (including
# `dhcp-static`, which this script shells out to) - this file is a script
# *body*, not a standalone executable.

LEASES_FILE="/var/lib/dnsmasq/dnsmasq.leases"
prog="dhcp-leases"

usage() {
  cat <<EOF
Usage:
  $prog [list] [--expired] [--sort ip|hostname|expiry|mac]
  $prog promote <mac|ip|hostname> [--ip NEW_IP] [--hostname NAME] [--comment TEXT] [--force] [--no-reload]
  $prog --help

Lists dnsmasq's dynamic DHCP leases ($LEASES_FILE), and can turn one into
a permanent static reservation.

Commands:
  list      List current leases (default if no command given): hostname,
            IP, MAC, expiry, and whether that MAC already has a static
            reservation. Expired-but-not-yet-reaped entries are hidden
            unless --expired is given (dnsmasq prunes these lazily, so
            stale entries can briefly linger after expiry).
  promote   Turn a lease into a static reservation via 'dhcp-static add'.
            By default keeps the currently-leased IP and reported
            hostname - override either with --ip/--hostname. If the
            client never reported a hostname (shows as '*' in the
            listing), --hostname is required.

Identifiers: <mac|ip|hostname> matches whichever you have on hand
(hostname match is case-insensitive). If more than one lease matches,
you're asked to use the MAC instead.

Examples:
  $prog
  $prog list --sort expiry
  sudo $prog promote 10.0.0.147                    # reserve at its current IP
  sudo $prog promote ws-25 --ip 10.0.0.60           # reserve at a different IP
  sudo $prog promote dc:2e:97:a1:81:15 --hostname nas-03   # lease has no reported hostname
EOF
}

die() {
  echo "$prog: $*" >&2
  exit 1
}

human_expiry() {
  local exp="$1" now delta
  now="$(date +%s)"
  delta=$(( exp - now ))
  if [ "$delta" -lt 0 ]; then
    echo "expired $(date -d "@$exp" '+%Y-%m-%d %H:%M')"
  else
    local h=$(( delta / 3600 )) m=$(( (delta % 3600) / 60 ))
    echo "in ${h}h${m}m ($(date -d "@$exp" '+%Y-%m-%d %H:%M'))"
  fi
}

static_macs_tsv() {
  dhcp-static list --tsv 2>/dev/null || true
}

cmd_list() {
  [ -f "$LEASES_FILE" ] || { echo "No leases file yet ($LEASES_FILE) - dnsmasq hasn't handed out any leases."; return; }

  local show_expired=0 sort_key="expiry"
  while [ $# -gt 0 ]; do
    case "$1" in
      --expired) show_expired=1; shift ;;
      --sort) sort_key="${2:?--sort needs ip|hostname|expiry|mac}"; shift 2 ;;
      *) die "unrecognized argument: $1" ;;
    esac
  done

  local statics; statics="$(static_macs_tsv)"
  local now; now="$(date +%s)"

  local rows reserved
  rows="$(
    while read -r exp mac ip hostname _; do
      [ -z "${mac:-}" ] && continue
      if [ "$show_expired" -eq 0 ] && [ "$exp" -lt "$now" ]; then continue; fi
      reserved="no"
      echo "$statics" | grep -qi $'^'"$mac"$'\t' && reserved="yes"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$exp" "${hostname:-*}" "$ip" "$mac" "$(human_expiry "$exp")" "$reserved"
    done < "$LEASES_FILE"
  )"

  case "$sort_key" in
    ip) rows="$(echo "$rows" | sort -t $'\t' -k3,3V)" ;;
    hostname) rows="$(echo "$rows" | sort -t $'\t' -k2,2f)" ;;
    mac) rows="$(echo "$rows" | sort -t $'\t' -k4,4)" ;;
    expiry|*) rows="$(echo "$rows" | sort -t $'\t' -k1,1n)" ;;
  esac

  { printf 'HOSTNAME\tIP\tMAC\tEXPIRES\tRESERVED\n'; echo "$rows" | cut -f2-6; } | column -t -s $'\t'
}

cmd_promote() {
  [ $# -ge 1 ] || die "Usage: $prog promote <mac|ip|hostname> [--ip NEW_IP] [--hostname NAME] [--comment TEXT] [--force] [--no-reload]"
  [ -f "$LEASES_FILE" ] || die "no leases file yet ($LEASES_FILE)."

  local id="$1"; shift
  local new_ip="" new_hostname="" comment="" force=0 no_reload=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ip) new_ip="${2:?--ip needs a value}"; shift 2 ;;
      --hostname) new_hostname="${2:?--hostname needs a value}"; shift 2 ;;
      --comment) comment="${2:?--comment needs a value}"; shift 2 ;;
      --force) force=1; shift ;;
      --no-reload) no_reload=1; shift ;;
      *) die "unrecognized argument: $1" ;;
    esac
  done

  local idmac; idmac="$(echo "${id,,}" | tr '-' ':')"
  local matches; matches="$(awk -v id="$id" -v idmac="$idmac" -v idlow="${id,,}" \
    '$2 == idmac || $3 == id || tolower($4) == idlow' "$LEASES_FILE")"
  local count; count="$(echo -n "$matches" | grep -c . || true)"
  [ -z "$matches" ] && die "no lease matches '$id'."
  if [ "$count" -gt 1 ]; then
    echo "Multiple leases match '$id' - use the MAC to disambiguate:" >&2
    echo "$matches" | awk '{printf "%s\t%s\t%s\n",$2,$3,$4}' | column -t -s $'\t' >&2
    exit 1
  fi

  local exp mac ip hostname
  read -r exp mac ip hostname _ <<<"$matches"

  local hostname_to_use="${new_hostname:-$hostname}"
  if [ "$hostname_to_use" = "*" ]; then
    die "lease for $mac has no reported hostname - supply one with --hostname NAME."
  fi
  local ip_to_use="${new_ip:-$ip}"

  echo "Promoting lease: $mac currently on $ip (expires $(human_expiry "$exp")) -> static $hostname_to_use,$ip_to_use"
  local extra=()
  [ -n "$comment" ] && extra+=(--comment "$comment")
  [ "$force" -eq 1 ] && extra+=(--force)
  [ "$no_reload" -eq 1 ] && extra+=(--no-reload)
  dhcp-static add "$mac" "$hostname_to_use" "$ip_to_use" "${extra[@]}"
}

cmd="${1:-list}"
case "$cmd" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -gt 0 ] && shift

case "$cmd" in
  list) cmd_list "$@" ;;
  promote) cmd_promote "$@" ;;
  *) usage; exit 1 ;;
esac
