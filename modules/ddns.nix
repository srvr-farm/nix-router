{ ... }:
{
  # Replaces OPNsense's DynDNS plugin (backend=ddclient). Two Cloudflare
  # accounts were configured there - srvr.farm and crowdcomputing.io - see
  # secrets/ddclient.conf(.example) for the actual account config. Kept
  # out of the Nix store entirely since it holds live Cloudflare API
  # tokens; deploy the real file to /etc/ddclient/ddclient.conf by hand
  # (mode 0600, root-owned) rather than through the Nix store.
  services.ddclient = {
    enable = true;
    configFile = "/etc/ddclient/ddclient.conf";
    interval = "5min"; # OPNsense's daemon_delay was 300s
  };
}
