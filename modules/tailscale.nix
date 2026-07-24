{ pkgs, ... }:
{
  # Matches OPNsense's tailscale plugin settings: subnet router for the
  # home LAN, exit node, and accepting routes advertised by other tailnet
  # nodes (that's how 10.0.1.0/24 "Office" and 10.1.1.0/24 "Wifi" traffic
  # showed up as "internal" in OPNsense's firewall floating rules - they're
  # subnet routes accepted from other nodes, not locally attached networks).
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    port = 41641;
  };

  # `tailscale up` is not idempotent-safe to call blindly on every boot with
  # --auth-key once already logged in, so check state first. Populate
  # /etc/tailscale/authkey (mode 0600, not in the nix store) with a fresh
  # pre-auth key from https://login.tailscale.com/admin/settings/keys -
  # the key captured from the live OPNsense config is almost certainly a
  # single-use key already consumed by the existing node, so don't reuse it.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic Tailscale connection (subnet router + exit node)";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.tailscale pkgs.jq ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -eu
      status=$(tailscale status --json | jq -r '.BackendState')
      if [ "$status" = "Running" ]; then
        exit 0
      fi

      authkey_arg=""
      if [ -f /etc/tailscale/authkey ]; then
        authkey_arg="--auth-key=file:/etc/tailscale/authkey"
      fi

      # shellcheck disable=SC2086
      tailscale up \
        --advertise-routes=10.0.0.0/24 \
        --advertise-exit-node \
        --accept-routes \
        --accept-dns=true \
        $authkey_arg
    '';
  };
}
