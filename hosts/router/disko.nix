{
  # The current OPNsense install lives on a single 120GB Samsung 850 EVO
  # SATA SSD (FreeBSD device ada0), GPT-partitioned with an EFI system
  # partition + one big root partition. This mirrors that layout on Linux.
  #
  # IMPORTANT: before running `disko`, confirm the device path:
  #   ls -l /dev/disk/by-id/ | grep -i samsung
  # and replace the path below if it differs. With only one disk in the
  # machine `/dev/sda` should be correct, but by-id is safer against
  # enumeration order changes.
  disko.devices = {
    disk = {
      main = {
        device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_120GB";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
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
