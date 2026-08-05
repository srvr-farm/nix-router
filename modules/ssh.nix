{ ... }:
{
  # Carried over from OPNsense's <ssh> settings (permitrootlogin=1,
  # passwordauth=1) and the three authorized_keys already on the box, so
  # existing clients (bastion-01 etc.) keep working without changes.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  # Primary admin user for the new box (mcallan@10.0.0.129, Ubuntu-hosted
  # before this migration) - same authorized_keys as root below (which
  # match what's on the live Ubuntu box's ~mcallan/.ssh/authorized_keys),
  # and passwordless sudo by explicit request.
  users.users.mark = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDsnDTVy4kydjvbJ67El05M5VQbaQFhWkOt8hd2yUs7eljJTHTkU2M3HIgCxYZpplABwaji4Tc2JD1YL9fapiuf3vmu7PqXKYhBavX6MQB0GvUG1NEsANiU75d5CLpfYlpMOAjYRko3LrqMmbjZEn1Xc4YqCWPUPtFdTS/JnAjGxud0Or8znoj7Dwm50yVD2H5IDq7zukKxXG2aN+8q7p085E8w+0/aTZuk2U/2T2p968W8VRDsKx4+2NaaVm2bmi7BRmEjnMV7Un/3/9BNpSLoEWlA6cU8ITYTEBWUNvQuDTSQ49U1WQIOanEvj+iF7L/laRhhLts+XM+hvJTU/hi5 /home/mcallan/.ssh/id_rsa"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDcTQmo4NOgNrFdMclQm/DhTQMnXlWSBEaSMMM8sh1K31zoQZpIRWmJOvoa0hZ03SNG/kcUXafB31RYNqs3rIKr59ahofKWoQxqxQAQW/59ycZSsTDP4XEh2I4lyBcoIY3yVLgnca+cS1qjw+L1h/pOw0Na9KeznWwnt7SQysxuE5XHMnH8C5nVzZFMpjFhfv43zfHYzsc+hS9O0GfCbVo4RRkOjO2t8LVxlL7j+ytbHLt64nJzOj8u2HqA9xtbbHUwWSlWWdn7zztMYRkQLRGVgeoeLk61D1xeLygFVRjr5qj8NOB5iDkkRCSfBniHDDEsfQeNM+PB/8c2MAFa3yPb /home/mcallan/source/cccp/vmi-imaging-keys/imaging_test_rsa"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDQc9F2bwNIndMmHql9avYmFQxYQYqjHGxrSCyVqFmVnK4qY72AMXjJeoNpgBsaGspFs+VTeIsyN131/HtOEQUF/Qmlb76cH5+vhq5r8QOffI7s+dVZcK5FV5JPQHsD4X7GtyLGjBbMMVPmamxAPJ/rsu0H7k04FZ/F7jq0GhsHNr4TFdZtd5ec/UtM3EyfF5sR6GcZ740/tLoWC/duc86dxRcH6M/hgEHkYSFhky2VpODsK6WGjd0Y0d7yjHx3B8oMA9y8vQ1EocbruV4HaIynrdrm65zkbFVodojDySfwkSZYUnXItAIRAEN7l9oRVPkFI3KeQ+rCEoD3X92IHo1t opc_rsa"
    ];
  };

  # Passwordless sudo for the wheel group (mark), by explicit request.
  security.sudo.wheelNeedsPassword = false;

  users.users.root = {
    # bcrypt hash straight from OPNsense's config.xml. libxcrypt (what NixOS
    # uses) understands $2y$ bcrypt hashes, but if root password login
    # doesn't work after cutover, just set a new one with `passwd`.
    hashedPassword = "$2y$10$Mz3NShGeUhAx3O7tB9VKpeVyay0U1zCAKoVyuU08yQNVaEw0Qvd6a";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDsnDTVy4kydjvbJ67El05M5VQbaQFhWkOt8hd2yUs7eljJTHTkU2M3HIgCxYZpplABwaji4Tc2JD1YL9fapiuf3vmu7PqXKYhBavX6MQB0GvUG1NEsANiU75d5CLpfYlpMOAjYRko3LrqMmbjZEn1Xc4YqCWPUPtFdTS/JnAjGxud0Or8znoj7Dwm50yVD2H5IDq7zukKxXG2aN+8q7p085E8w+0/aTZuk2U/2T2p968W8VRDsKx4+2NaaVm2bmi7BRmEjnMV7Un/3/9BNpSLoEWlA6cU8ITYTEBWUNvQuDTSQ49U1WQIOanEvj+iF7L/laRhhLts+XM+hvJTU/hi5 /home/mcallan/.ssh/id_rsa"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDcTQmo4NOgNrFdMclQm/DhTQMnXlWSBEaSMMM8sh1K31zoQZpIRWmJOvoa0hZ03SNG/kcUXafB31RYNqs3rIKr59ahofKWoQxqxQAQW/59ycZSsTDP4XEh2I4lyBcoIY3yVLgnca+cS1qjw+L1h/pOw0Na9KeznWwnt7SQysxuE5XHMnH8C5nVzZFMpjFhfv43zfHYzsc+hS9O0GfCbVo4RRkOjO2t8LVxlL7j+ytbHLt64nJzOj8u2HqA9xtbbHUwWSlWWdn7zztMYRkQLRGVgeoeLk61D1xeLygFVRjr5qj8NOB5iDkkRCSfBniHDDEsfQeNM+PB/8c2MAFa3yPb"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDQc9F2bwNIndMmHql9avYmFQxYQYqjHGxrSCyVqFmVnK4qY72AMXjJeoNpgBsaGspFs+VTeIsyN131/HtOEQUF/Qmlb76cH5+vhq5r8QOffI7s+dVZcK5FV5JPQHsD4X7GtyLGjBbMMVPmamxAPJ/rsu0H7k04FZ/F7jq0GhsHNr4TFdZtd5ec/UtM3EyfF5sR6GcZ740/tLoWC/duc86dxRcH6M/hgEHkYSFhky2VpODsK6WGjd0Y0d7yjHx3B8oMA9y8vQ1EocbruV4HaIynrdrm65zkbFVodojDySfwkSZYUnXItAIRAEN7l9oRVPkFI3KeQ+rCEoD3X92IHo1t opc_rsa"
    ];
  };
}
