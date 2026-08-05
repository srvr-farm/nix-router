#!/usr/bin/env bash
# Sets this Supermicro board's BMC fan mode or a custom fan duty-cycle
# percentage, via ipmitool OEM raw commands. Run `set-fan.sh --help` for
# the full rundown of presets and raw commands used.
set -euo pipefail

prog="$(basename "$0")"

usage() {
  cat <<EOF
Usage:
  $prog mode <standard|optimal|full>
  $prog speed <0-100>
  $prog status
  $prog --help

Sets the Supermicro BMC's fan control mode, or a custom fan duty-cycle
percentage, via IPMI OEM raw commands.

By default this talks to the BMC in-band (ipmitool's local "open"
interface) - run it directly on the router itself, where the
ipmi_si/ipmi_devintf/ipmi_msghandler kernel modules give local BMC access
with no credentials needed. To drive it out-of-band instead (e.g. from
your workstation, or whenever the OS is down/unreachable), set:
  IPMI_HOST=<bmc-ip> IPMI_USER=<user> IPMI_PASS=<pass> $prog mode full

--- Fan mode presets (Supermicro X9/X10-era boards) --------------------
  standard  Balances CPU and peripheral zones at moderate speed (~50%).
            This is the BMC's power-on default.
  optimal   Quieter profile: CPU zone ~30%, peripheral zones low.
  full      Locks every fan zone to 100% max speed. NOT what to use
            before a custom percentage (see '$prog speed' below).

  "Heavy IO" (CPU zone at standard, peripheral/HDD zones locked to 75%)
  is a documented preset on some Supermicro generations, but its raw
  4th-byte value wasn't confirmed for this specific board, so it's
  deliberately left unimplemented here rather than guessed at against
  real fan control hardware. Confirm the correct byte for
  '0x30 0x45 0x01 <byte>' via Supermicro's IPMI raw command reference or
  IPMICFG before wiring it in.

Raw commands used:
  mode <preset>   ipmitool raw 0x30 0x45 0x01 <byte>
                    standard=0x00  full=0x01  optimal=0x02
  speed <pct>     ipmitool raw 0x30 0x70 0x66 0x01 0x00 <hex duty cycle>
                    duty cycle byte 0x00 (0%) .. 0x64 (100%), same
                    numeric value as the decimal percentage written in
                    hex (e.g. 50 -> 0x32). Only sets the CPU/system fan
                    zone (FAN1-4) - the peripheral zone (FANA...) isn't
                    addressed by this command.
                  Commonly-cited docs claim "full" mode must be set
                  first for a custom percentage to stick; on this board
                  that's backwards and was confirmed by testing on real
                  hardware (2026-08-05): in "full" mode the duty-cycle
                  write is accepted (reads back correctly) but ignored -
                  fans stay pinned near 100% regardless. In "standard"
                  mode the same write takes effect immediately and
                  scales fan RPM proportionally. So '$prog speed' sets
                  standard mode first, then applies the percentage.
  status          ipmitool sdr type Fan   (read-only - current fan RPMs)

Examples:
  $prog mode optimal              # quiet preset, in-band (run on router)
  $prog speed 50                  # ~50% duty cycle, in-band
  IPMI_HOST=10.0.0.1 IPMI_USER=ADMIN IPMI_PASS=secret $prog mode full
EOF
}

cmd="${1:-}"
case "$cmd" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage
    exit 1
    ;;
esac

ipmi=(ipmitool)
if [ -n "${IPMI_HOST:-}" ]; then
  : "${IPMI_USER:?IPMI_USER must be set when IPMI_HOST is set}"
  : "${IPMI_PASS:?IPMI_PASS must be set when IPMI_HOST is set}"
  ipmi=(ipmitool -I lanplus -H "$IPMI_HOST" -U "$IPMI_USER" -P "$IPMI_PASS")
fi

case "$cmd" in
  mode)
    mode="${2:-}"
    case "$mode" in
      standard) byte=0x00 ;;
      full)     byte=0x01 ;;
      optimal)  byte=0x02 ;;
      heavyio|heavy-io)
        echo "heavyio mode isn't wired up - its raw byte value wasn't confirmed for this board. See '$prog --help'." >&2
        exit 1
        ;;
      *)
        echo "Usage: $prog mode <standard|optimal|full>" >&2
        exit 1
        ;;
    esac
    echo "Setting fan mode: $mode"
    "${ipmi[@]}" raw 0x30 0x45 0x01 "$byte"
    ;;

  speed)
    pct="${2:-}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -gt 100 ]; then
      echo "Usage: $prog speed <0-100>" >&2
      exit 1
    fi
    hex=$(printf '0x%02x' "$pct")
    echo "Setting fan mode: standard (custom duty cycle only takes effect from this mode, not full - see --help)"
    "${ipmi[@]}" raw 0x30 0x45 0x01 0x00
    echo "Setting fan duty cycle: ${pct}% ($hex)"
    "${ipmi[@]}" raw 0x30 0x70 0x66 0x01 0x00 "$hex"
    ;;

  status)
    "${ipmi[@]}" sdr type Fan
    ;;

  *)
    usage
    exit 1
    ;;
esac
