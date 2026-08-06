# Lists and edits this router's static DHCP reservations (dnsmasq's
# dhcp-hostsfile). Run `dhcp-static --help` for the full rundown.
#
# Packaged via modules/dhcp-tools.nix (pkgs.writeShellApplication), which
# supplies the shebang, `set -euo pipefail`, and a curated PATH - this
# file is a script *body*, not a standalone executable.

STATIC_FILE="/var/lib/dnsmasq/static-hosts.conf"
LEASES_FILE="/var/lib/dnsmasq/dnsmasq.leases"
LOCK_FILE="${STATIC_FILE}.lock"

# Internal field separator for the mac/hostname/ip/comment/lineno rows
# passed between the functions below. NOT a tab: bash's `read` treats
# tab as "IFS whitespace" no matter what IFS is set to, which collapses
# runs of empty fields (e.g. a hostname-only entry with no ip AND no
# comment) instead of preserving them - silently corrupting field
# alignment. \x1f (ASCII unit separator) has no such special-cased
# behavior. The public `list --tsv` output still uses real tabs (see
# cmd_list) - only the internal bookkeeping format below uses this.
SEP=$'\x1f'
prog="dhcp-static"

usage() {
  cat <<EOF
Usage:
  $prog [list] [--tsv]
  $prog show <mac|hostname|ip>
  $prog add <mac> <hostname> [ip] [--comment TEXT] [--force] [--no-reload]
  $prog set-ip <mac|hostname|ip> <new-ip> [--force] [--no-reload]
  $prog rename <mac|hostname|ip> <new-hostname> [--force] [--no-reload]
  $prog set-comment <mac|hostname|ip> <text> [--no-reload]
  $prog remove <mac|hostname|ip> [--no-reload]
  $prog --help

Lists and edits static DHCP reservations for this router's dnsmasq
instance, stored in $STATIC_FILE (dnsmasq's "dhcp-hostsfile" - a plain
file of "MAC,hostname[,IP]" lines, one reservation per line, re-read by
dnsmasq on SIGHUP - no restart or redeploy needed). See
modules/dhcp-static-hosts.seed in the nix-router repo for the baseline
this file is seeded from on a fresh reimage, and modules/dhcp-dns.nix for
how it's wired up.

Commands:
  list          List all reservations (default if no command given).
                  --tsv   Machine-readable: mac<TAB>hostname<TAB>ip<TAB>comment,
                          one line per reservation, no header. Used by
                          dhcp-leases and lan-hosts; stable for scripting.
  show          Print full detail for one reservation, including its
                current DHCP lease state if it has one.
  add           Add a new reservation. <hostname> is required; <ip> is
                optional (a hostname-only entry just pins the DNS name/
                answers to inventory questions, without reserving an
                address). MAC accepts ':' or '-' separators and either
                case.
  set-ip        Change (or add) the IP on an existing reservation, found
                by MAC, current hostname, or current IP.
  rename        Change the hostname on an existing reservation.
  set-comment   Replace the note attached to a reservation.
  remove        Delete a reservation, found by MAC, hostname, or IP.

Identifiers: anywhere <mac|hostname|ip> is accepted, you can pass the
MAC address, the current hostname (case-insensitive), or the current
reserved IP - whichever is on hand. If more than one reservation matches
(shouldn't happen, but the file is hand-editable), the command lists the
matches and asks you to use the MAC instead.

Flags:
  --comment TEXT  Attach a note, stored as a '# TEXT' line directly above
                  the entry.
  --force         Skip conflict checks (duplicate MAC/IP/hostname) and
                  overwrite in place instead of erroring.
  --no-reload     Don't send SIGHUP to dnsmasq after a change. Useful
                  when scripting several edits back to back - reload once
                  yourself afterwards with: systemctl reload dnsmasq

Conflict checks on add/set-ip (non-fatal ones print a warning, fatal ones
require --force to proceed):
  - MAC already reserved                    -> fatal
  - IP already reserved by a different MAC  -> fatal
  - hostname already used by a different MAC -> fatal (dnsmasq mishandles
    duplicate hostnames - this bit us during the original OPNsense
    migration, see modules/dhcp-static-hosts.seed)
  - IP falls inside the active dhcp-range (the dynamic pool) -> warning
  - IP is currently an active *dynamic* lease held by a different MAC
    -> warning (will self-resolve once that lease expires/is renewed,
    but can cause a brief address collision until then)

add/set-ip/rename/set-comment/remove all require root (the file is
owned dnsmasq:root, mode 0644) - run with sudo.

Examples:
  $prog                                          # list everything
  $prog show ws-19
  sudo $prog add 9c:7b:ef:00:11:22 printer-02 10.0.0.91 --comment "2nd floor printer"
  sudo $prog set-ip ws-19 10.0.0.85
  sudo $prog rename 10.0.0.85 ws-19-new
  sudo $prog remove printer-02
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

normalize_mac() {
  echo "${1,,}" | tr '-' ':'
}

valid_mac() {
  [[ "$1" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]
}

valid_hostname() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

valid_ip() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  for octet in ${ip//./ }; do
    [ "$octet" -le 255 ] || return 1
  done
  return 0
}

ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Emits mac<TAB>hostname<TAB>ip<TAB>comment<TAB>comment_start_line<TAB>data_line
# for every reservation in $STATIC_FILE. A comment directly (no blank line
# between) above an entry is that entry's note; anything else (orphaned
# comments, blank-line-separated blocks) is left alone by every command
# below.
parse_entries() {
  [ -f "$STATIC_FILE" ] || return 0
  awk -v OFS="$SEP" '
    function reset() { comment = ""; cstart = 0; clines = 0 }
    BEGIN { reset() }
    /^[ \t]*#/ {
      if (clines == 0) cstart = NR
      txt = $0
      sub(/^[ \t]*#[ \t]?/, "", txt)
      comment = (clines == 0) ? txt : comment "; " txt
      clines++
      next
    }
    /^[ \t]*$/ { reset(); next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      n = split(line, f, ",")
      mac = tolower(f[1]); hostname = ""; ip = ""
      for (i = 2; i <= n; i++) {
        v = f[i]
        if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip = v; else hostname = v
      }
      print mac, hostname, ip, comment, (clines > 0 ? cstart : NR), NR
      reset()
    }
  ' "$STATIC_FILE"
}

# Prints matching rows (same TSV shape as parse_entries) for an identifier
# that may be a MAC, hostname (case-insensitive), or IP.
find_entries() {
  local id="$1" idmac
  idmac="$(normalize_mac "$id")"
  parse_entries | awk -F"$SEP" -v id="$id" -v idmac="$idmac" -v idlow="${id,,}" '
    $1 == idmac || $3 == id || tolower($2) == idlow
  '
}

dnsmasq_conf_path() {
  systemctl show dnsmasq.service -p ExecStart --value 2>/dev/null \
    | grep -oE -- '-C [^[:space:]]+' | awk '{print $2}'
}

# Prints "<pool-start> <pool-end>" from the live dhcp-range, or nothing
# (and a non-zero exit) if it can't be determined - callers must treat
# that as "skip this check", not an error.
pool_range() {
  local conf range
  conf="$(dnsmasq_conf_path)" || return 1
  [ -n "$conf" ] && [ -r "$conf" ] || return 1
  range="$(grep -m1 '^dhcp-range=' "$conf")" || return 1
  range="${range#dhcp-range=}"
  IFS=',' read -r start end _ <<<"$range"
  [[ "$start" =~ ^[0-9.]+$ && "$end" =~ ^[0-9.]+$ ]] || return 1
  echo "$start $end"
}

ip_in_pool() {
  local ip="$1" range start end
  range="$(pool_range)" || return 1
  read -r start end <<<"$range"
  local ipn sn en
  ipn="$(ip_to_int "$ip")"; sn="$(ip_to_int "$start")"; en="$(ip_to_int "$end")"
  [ "$ipn" -ge "$sn" ] && [ "$ipn" -le "$en" ]
}

# Prints the MAC currently holding an *active* dynamic lease on $1, if any.
lease_holder_for_ip() {
  [ -f "$LEASES_FILE" ] || return 1
  awk -v ip="$1" -v now="$(date +%s)" '$3 == ip && $1 > now {print $2; found=1} END{exit !found}' "$LEASES_FILE"
}

# check_conflicts <mac> <hostname> <ip> <exclude_mac>
# <exclude_mac> (may be empty) is skipped when checking for collisions -
# used by set-ip/rename to not conflict with the entry being edited.
check_conflicts() {
  local mac="$1" hostname="$2" ip="$3" exclude="$4"
  local row emac ehost eip fatal=0 range

  while IFS="$SEP" read -r emac ehost eip _ _ _; do
    [ -z "$emac" ] && continue
    [ -n "$exclude" ] && [ "$emac" = "$exclude" ] && continue
    if [ "$emac" = "$mac" ]; then
      echo "MAC $mac is already reserved (hostname=$ehost ip=${eip:-none})." >&2
      fatal=1
    fi
    if [ -n "$ip" ] && [ -n "$eip" ] && [ "$eip" = "$ip" ]; then
      echo "IP $ip is already reserved to $emac (hostname=$ehost)." >&2
      fatal=1
    fi
    if [ -n "$hostname" ] && [ "${ehost,,}" = "${hostname,,}" ]; then
      echo "Hostname '$hostname' is already used by $emac (ip=${eip:-none}) - dnsmasq doesn't handle duplicate hostnames well." >&2
      fatal=1
    fi
  done < <(parse_entries)

  if [ "$fatal" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
    die "conflict(s) above - pass --force to proceed anyway."
  fi

  if [ -n "$ip" ] && row="$(lease_holder_for_ip "$ip")" && [ "$row" != "$mac" ]; then
    echo "Warning: $ip is currently an active dynamic lease held by $row - may briefly collide until that lease expires." >&2
  fi
  if [ -n "$ip" ] && ip_in_pool "$ip"; then
    range="$(pool_range)" || range=""
    echo "Warning: $ip falls inside the dynamic pool ($(echo "$range" | tr ' ' '-')) - a DHCP client could grab it first." >&2
  fi
}

reload_dnsmasq() {
  if [ "$NO_RELOAD" -eq 1 ]; then
    echo "Skipped dnsmasq reload (--no-reload) - remember: systemctl reload dnsmasq"
    return 0
  fi
  systemctl reload dnsmasq
  echo "Reloaded dnsmasq (SIGHUP)."
}

# delete_lines <first> <last> - removes an inclusive line range from
# $STATIC_FILE, atomically. Caller must hold $LOCK_FILE.
delete_lines() {
  local first="$1" last="$2" tmp
  tmp="$(mktemp "${STATIC_FILE}.XXXXXX")"
  awk -v first="$first" -v last="$last" 'NR < first || NR > last' "$STATIC_FILE" > "$tmp"
  install -m 0644 -o dnsmasq -g dnsmasq "$tmp" "$STATIC_FILE" 2>/dev/null || {
    cat "$tmp" > "$STATIC_FILE"
  }
  rm -f "$tmp"
}

append_entry() {
  local mac="$1" hostname="$2" ip="$3" comment="$4"
  {
    [ -n "$comment" ] && printf '# %s\n' "$comment"
    if [ -n "$ip" ]; then
      printf '%s,%s,%s\n' "$mac" "$hostname" "$ip"
    else
      printf '%s,%s\n' "$mac" "$hostname"
    fi
  } >> "$STATIC_FILE"
}

print_table() {
  { printf 'HOSTNAME\tIP\tMAC\tCOMMENT\n'; parse_entries | cut -d"$SEP" -f1-4 | awk -F"$SEP" '{printf "%s\t%s\t%s\t%s\n", $2, $3, $1, $4}'; } \
    | column -t -s $'\t'
}

cmd_list() {
  if [ "${1:-}" = "--tsv" ]; then
    parse_entries | cut -d"$SEP" -f1-4 | tr "$SEP" '\t'
    return
  fi
  [ -f "$STATIC_FILE" ] || { echo "No static reservations yet ($STATIC_FILE doesn't exist)."; return; }
  print_table
}

cmd_show() {
  local id="${1:?Usage: $prog show <mac|hostname|ip>}"
  local matches count
  matches="$(find_entries "$id")"
  count="$(echo -n "$matches" | grep -c . || true)"
  [ -z "$matches" ] && die "no reservation matches '$id'."
  if [ "$count" -gt 1 ]; then
    echo "Multiple reservations match '$id' - use the MAC to disambiguate:" >&2
    echo "$matches" | cut -d"$SEP" -f1-4 | tr "$SEP" '\t' | column -t -s $'\t' >&2
    exit 1
  fi
  local mac hostname ip comment
  IFS="$SEP" read -r mac hostname ip comment _ _ <<<"$matches"
  echo "MAC:      $mac"
  echo "Hostname: ${hostname:-<none>}"
  echo "IP:       ${ip:-<none - hostname-only reservation>}"
  echo "Comment:  ${comment:-<none>}"
  if [ -f "$LEASES_FILE" ]; then
    local lease
    lease="$(awk -v mac="$mac" '$2 == mac' "$LEASES_FILE")"
    if [ -n "$lease" ]; then
      local exp lip lhost
      read -r exp _ lip lhost _ <<<"$lease"
      echo "Current lease: $lip (hostname reported: $lhost), expires $(date -d "@$exp" '+%Y-%m-%d %H:%M:%S')"
      if [ -n "$ip" ] && [ "$lip" != "$ip" ]; then
        echo "  Note: leased IP differs from the reservation - client hasn't picked up the reservation yet (renews on next DHCP request)."
      fi
    else
      echo "Current lease: none (hasn't requested DHCP since this reservation was set, or is offline)"
    fi
  fi
}

cmd_add() {
  [ $# -ge 2 ] || die "Usage: $prog add <mac> <hostname> [ip] [--comment TEXT] [--force] [--no-reload]"
  local mac hostname ip="" comment=""
  mac="$(normalize_mac "$1")"; shift
  hostname="$1"; shift
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    ip="$1"; shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --comment) comment="${2:?--comment needs a value}"; shift 2 ;;
      *) die "unrecognized argument: $1" ;;
    esac
  done

  valid_mac "$mac" || die "invalid MAC address: $mac"
  valid_hostname "$hostname" || die "invalid hostname: $hostname (letters, digits, hyphens only, no leading/trailing hyphen)"
  [ -n "$ip" ] && { valid_ip "$ip" || die "invalid IPv4 address: $ip"; }

  require_root add
  exec 9>"$LOCK_FILE"
  flock 9

  check_conflicts "$mac" "$hostname" "$ip" ""
  append_entry "$mac" "$hostname" "$ip" "$comment"
  echo "Added: $mac,$hostname${ip:+,$ip}${comment:+  # $comment}"
  reload_dnsmasq
}

# _edit <identifier> <new_hostname_or_empty> <new_ip_or_empty> - shared by
# set-ip/rename/set-comment: find the entry, then remove+re-add it with
# the requested field(s) overridden and everything else preserved.
_edit() {
  local id="$1" new_hostname="$2" new_ip="$3" new_comment="$4" comment_given="$5"
  local matches count
  matches="$(find_entries "$id")"
  count="$(echo -n "$matches" | grep -c . || true)"
  [ -z "$matches" ] && die "no reservation matches '$id'."
  if [ "$count" -gt 1 ]; then
    echo "Multiple reservations match '$id' - use the MAC to disambiguate:" >&2
    echo "$matches" | cut -d"$SEP" -f1-4 | tr "$SEP" '\t' | column -t -s $'\t' >&2
    exit 1
  fi

  local mac hostname ip comment cstart dline
  IFS="$SEP" read -r mac hostname ip comment cstart dline <<<"$matches"
  [ -n "$new_hostname" ] && hostname="$new_hostname"
  [ -n "$new_ip" ] && ip="$new_ip"
  [ "$comment_given" -eq 1 ] && comment="$new_comment"

  check_conflicts "$mac" "$hostname" "$ip" "$mac"
  delete_lines "$cstart" "$dline"
  append_entry "$mac" "$hostname" "$ip" "$comment"
  echo "Updated: $mac,$hostname${ip:+,$ip}${comment:+  # $comment}"
  reload_dnsmasq
}

cmd_set_ip() {
  [ $# -ge 2 ] || die "Usage: $prog set-ip <mac|hostname|ip> <new-ip> [--force] [--no-reload]"
  local id="$1" new_ip="$2"
  valid_ip "$new_ip" || die "invalid IPv4 address: $new_ip"
  require_root set-ip
  exec 9>"$LOCK_FILE"
  flock 9
  _edit "$id" "" "$new_ip" "" 0
}

cmd_rename() {
  [ $# -ge 2 ] || die "Usage: $prog rename <mac|hostname|ip> <new-hostname> [--force] [--no-reload]"
  local id="$1" new_hostname="$2"
  valid_hostname "$new_hostname" || die "invalid hostname: $new_hostname"
  require_root rename
  exec 9>"$LOCK_FILE"
  flock 9
  _edit "$id" "$new_hostname" "" "" 0
}

cmd_set_comment() {
  [ $# -ge 2 ] || die "Usage: $prog set-comment <mac|hostname|ip> <text> [--no-reload]"
  local id="$1" text="$2"
  require_root set-comment
  exec 9>"$LOCK_FILE"
  flock 9
  _edit "$id" "" "" "$text" 1
}

cmd_remove() {
  [ $# -ge 1 ] || die "Usage: $prog remove <mac|hostname|ip> [--no-reload]"
  local id="$1"
  require_root remove
  exec 9>"$LOCK_FILE"
  flock 9

  local matches count
  matches="$(find_entries "$id")"
  count="$(echo -n "$matches" | grep -c . || true)"
  [ -z "$matches" ] && die "no reservation matches '$id'."
  if [ "$count" -gt 1 ]; then
    echo "Multiple reservations match '$id' - use the MAC to disambiguate:" >&2
    echo "$matches" | cut -d"$SEP" -f1-4 | tr "$SEP" '\t' | column -t -s $'\t' >&2
    exit 1
  fi

  local mac hostname ip comment cstart dline
  IFS="$SEP" read -r mac hostname ip comment cstart dline <<<"$matches"
  delete_lines "$cstart" "$dline"
  echo "Removed: $mac,$hostname${ip:+,$ip}${comment:+  # $comment}"
  reload_dnsmasq
}

# --- Argument parsing: pull --force/--no-reload out from anywhere so
# subcommands don't each have to. ---
FORCE=0
NO_RELOAD=0
args=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --no-reload) NO_RELOAD=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"

cmd="${1:-list}"
case "$cmd" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -gt 0 ] && shift

case "$cmd" in
  list) cmd_list "$@" ;;
  show) cmd_show "$@" ;;
  add) cmd_add "$@" ;;
  set-ip) cmd_set_ip "$@" ;;
  rename) cmd_rename "$@" ;;
  set-comment) cmd_set_comment "$@" ;;
  remove) cmd_remove "$@" ;;
  *) usage; exit 1 ;;
esac
