{ pkgs, lib, ... }:
{
  imports = [
    ../../modules/network.nix
    ../../modules/firewall.nix
    ../../modules/dhcp-dns.nix
    ../../modules/tailscale.nix
    ../../modules/ddns.nix
    ../../modules/ssh.nix
    ../../modules/srvr-farm-tools.nix
    ../../modules/monitoring.nix
    ../../modules/dhcp-tools.nix
  ];

  # --- Boot / hardware ---------------------------------------------------
  # This board is legacy BIOS only (no /sys/firmware/efi) - systemd-boot
  # requires UEFI and would silently produce an unbootable image here.
  # GRUB in legacy/MBR mode against the whole disk (with a GPT "BIOS boot"
  # partition for its core.img, see hosts/router/disko.nix) is the correct
  # loader, matching how the existing Ubuntu install on this same board is
  # set up.
  # `device` is deliberately not set here - disko auto-wires GRUB's target
  # device(s) from the GPT "EF02" (BIOS boot) partition in disko.nix;
  # setting it manually here duplicates that entry and trips NixOS's
  # "duplicated devices in mirroredBoots" assertion.
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };

  # Supermicro X10SLH-N6-ST031, Xeon E3-1281 v3 (4c/8t), 32GB RAM, two
  # 120GB Samsung 850 EVO SATA SSDs (the second, non-boot one is the
  # target - see hosts/router/disko.nix). Legacy (non-UEFI) BIOS.
  nixpkgs.hostPlatform = "x86_64-linux";

  # This board's legacy BIOS exposes no SR-IOV toggle and can't fit the
  # SR-IOV "VF BAR" reservations all 6 onboard X540 ports advertise (each
  # reserves address space for 64 potential VFs we'll never use) into its
  # PCI MMIO window - confirmed via dmesg ("VF BAR ... can't assign; no
  # space") and tried-and-failed against `intremap=no_x2apic_optout`,
  # `pci=realloc`, and BIOS "Above 4G Decoding". Only 1 of 6 X540 ports
  # probes successfully as a result. Since a router has no use for
  # SR-IOV/VFs anyway, compile the capability out of the kernel entirely
  # so Linux never requests that space in the first place. This forces a
  # local kernel build (no Hydra binary cache hit) - confirmed fixed on
  # first real boot (2026-08-03): all 6 X540 ports came up.
  boot.kernelPatches = [{
    name = "disable-pci-iov";
    patch = null;
    extraStructuredConfig = {
      PCI_IOV = lib.kernel.no;
      # Each of these unconditionally `select PCI_IOV` in their Kconfig,
      # which otherwise silently forces it back to 'y' regardless of the
      # setting above. None are relevant to this box (VF drivers for
      # Intel QAT crypto accelerators meant for use inside VMs, and a
      # Cisco VIC Infiniband driver).
      CRYPTO_DEV_QAT_DH895xCCVF = lib.kernel.no;
      CRYPTO_DEV_QAT_C3XXXVF = lib.kernel.no;
      CRYPTO_DEV_QAT_C62XVF = lib.kernel.no;
      INFINIBAND_USNIC = lib.kernel.no;
    };
  }];
  boot.kernelParams = [ "intremap=no_x2apic_optout" "pci=realloc" ];

  # --- Base system, carried over from OPNsense's <system> settings -------
  time.timeZone = "America/Los_Angeles";
  services.timesyncd.enable = true;
  services.timesyncd.servers = [
    "0.opnsense.pool.ntp.org"
    "1.opnsense.pool.ntp.org"
    "2.opnsense.pool.ntp.org"
    "3.opnsense.pool.ntp.org"
  ];

  environment.systemPackages = with pkgs; [
    vim
    tcpdump
    ethtool
    conntrack-tools
    mtr
    lm_sensors # `sensors` - CPU/board temps via coretemp + Super I/O below
    bridge-utils # `brctl` - br-lan is also fully inspectable via `bridge`/`ip -d link`
    ipmitool # BMC sensors/SEL/power control - see hardware.ipmi.enable below
    iperf3 # also gives the `iperf3` client binary for ad hoc tests, on top of the server below
  ];

  # Throughput testing server, always on - handy for validating the NIC
  # offload/flowtable setup in modules/network.nix and modules/firewall.nix
  # from any LAN/Tailscale client without having to start one manually.
  # No firewall changes needed: modules/firewall.nix's input chain already
  # fully trusts br-lan and tailscale0; WAN never gets a rule for this
  # port, so it stays unreachable from the internet either way.
  services.iperf3 = {
    enable = true;
    bind = "10.0.0.1";
  };

  # coretemp = CPU core temps. nct6775 covers the Nuvoton Super I/O chip
  # family common on Supermicro X9/X10 boards - confirmed on this board as
  # an nct6776 (board/fan/voltage sensors). IPMI's own sensors (`ipmitool
  # sensor list`) don't depend on either and cover more ground still
  # (per-NIC temps, DIMM temps, VRM) - it's the more complete source here.
  #
  # ipmi_si/ipmi_devintf/ipmi_msghandler give in-band IPMI access to the
  # BMC (creates /dev/ipmi0), so `ipmitool` works locally without needing
  # the BMC's own LAN credentials - nixos-24.11 has no dedicated
  # `hardware.ipmi` module (just a Prometheus exporter), so these are
  # loaded directly.
  boot.kernelModules = [ "coretemp" "nct6775" "ipmi_si" "ipmi_devintf" "ipmi_msghandler" ];

  # Bumping this on upgrade is your job, not an automated one - this just
  # pins the state format this config was written against.
  system.stateVersion = "24.11";

  # Lets `mark` (not just root) run `nixos-rebuild switch --target-host`
  # deploys directly - without this, the nix-daemon refuses to accept
  # locally-built (unsigned) store paths pushed by a non-trusted user
  # ("lacks a signature by a trusted key"), and only root works.
  nix.settings.trusted-users = [ "root" "mark" ];

  # By default, using flakes pulls the *entire* nixpkgs source tree into
  # /etc/nix/registry.json (for on-box `nix run nixpkgs#...` convenience),
  # which drags one enormous single-store-path blob into the system
  # closure. Not needed on a router, and it was large enough to cause the
  # disko image builder's copy-into-VM step to OOM and silently drop a
  # couple of files (`cp: cannot access ... Cannot allocate memory` for
  # unrelated by-name package directories) while still exiting 0. Clearing
  # the registry avoids that blob entirely.
  nix.registry = lib.mkForce { };
}
