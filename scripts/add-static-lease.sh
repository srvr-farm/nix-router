#!/usr/bin/env bash
# Adds a static DHCP reservation to modules/dhcp-dns.nix's dhcp-host list.
#
# Usage: scripts/add-static-lease.sh <mac> <hostname> <ip> [comment]
#
# This only edits the Nix source file - it doesn't touch the running
# router. Review the diff it prints, commit, then deploy, e.g.:
#   nixos-rebuild switch --flake .#router --target-host mark@10.0.0.1 --use-remote-sudo
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <mac> <hostname> <ip> [comment]" >&2
  exit 1
fi

mac="$(echo "$1" | tr 'A-Z' 'a-z' | tr '-' ':')"
hostname="$2"
ip="$3"
comment="${4:-}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="$repo_root/modules/dhcp-dns.nix"

if [[ ! "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
  echo "Invalid MAC address: $1" >&2
  exit 1
fi
if [[ ! "$hostname" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "Invalid hostname: $hostname (letters, digits, hyphens only - dnsmasq needs a valid DNS label)" >&2
  exit 1
fi
if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Invalid IPv4 address: $ip" >&2
  exit 1
fi
for octet in ${ip//./ }; do
  if [ "$octet" -gt 255 ]; then
    echo "Invalid IPv4 address: $ip" >&2
    exit 1
  fi
done

if grep -q "\"$mac," "$file"; then
  echo "MAC $mac already has a reservation:" >&2
  grep -n "\"$mac," "$file" >&2
  exit 1
fi
if grep -qE ",${ip}\"" "$file"; then
  echo "IP $ip is already reserved:" >&2
  grep -nE ",${ip}\"" "$file" >&2
  exit 1
fi
if grep -qE ",${hostname}," "$file"; then
  echo "Warning: hostname '$hostname' is already used by another reservation:" >&2
  grep -nE ",${hostname}," "$file" >&2
fi

# dhcp-range in modules/dhcp-dns.nix is 10.0.0.100-10.0.0.200 (dynamic pool)
# - a static reservation inside that range can race a DHCP client that
# grabs it dynamically before this takes effect. Warn, don't block.
last_octet="${ip##*.}"
if [[ "$ip" == 10.0.0.* ]] && [ "$last_octet" -ge 100 ] && [ "$last_octet" -le 200 ]; then
  echo "Warning: $ip falls inside the dynamic pool (10.0.0.100-200) - pick something outside it if possible." >&2
fi

entry="        \"$mac,$hostname,$ip\""
if [ -n "$comment" ]; then
  entry="$entry # $comment"
fi

awk -v entry="$entry" '
  /dhcp-host = \[/ { inblock=1 }
  inblock && /^[ \t]*\];[ \t]*$/ {
    print entry
    inblock=0
  }
  { print }
' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

echo "Added: $entry"
echo
git -C "$repo_root" --no-pager diff -- modules/dhcp-dns.nix
echo
echo "Review the diff above, then commit and deploy, e.g.:"
echo "  nixos-rebuild switch --flake $repo_root#router --target-host mark@10.0.0.1 --use-remote-sudo"
