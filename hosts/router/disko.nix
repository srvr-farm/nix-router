{
  # Target: the *second* 120GB Samsung 850 EVO SATA SSD in the Supermicro
  # X10SLH-N6-ST031 box (mcallan@10.0.0.129) - serial S21TNXAGB11943E, not
  # the one Ubuntu currently boots from (S21TNSAFC16808W). Confirmed via
  # `ls -l /dev/disk/by-id/ | grep -i samsung` and `findmnt -no SOURCE /`
  # on the live box. Both disks report the identical exact byte size
  # (120034123776 bytes = 111.79 GiB) - imageSize below is set just under
  # that so the built image can be `dd`'d straight onto the real disk with
  # no post-dd partition-growing step.
  #
  # This board is legacy BIOS (no UEFI) - see hosts/router/configuration.nix
  # for why GRUB is used instead of systemd-boot. The GPT "boot" partition
  # below is GRUB's BIOS-boot partition (raw, no filesystem - holds
  # core.img), not an EFI System Partition.
  disko.devices = {
    disk = {
      main = {
        device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_120GB_S21TNXAGB11943E";
        type = "disk";
        imageName = "nixos-router";
        imageSize = "111G";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02";
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
