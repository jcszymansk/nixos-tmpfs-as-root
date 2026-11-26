{ ... }:

# A Raspberry Pi 3 on Wi-Fi with SSH key login only. Build the image with
#   nix build .#nixosConfigurations.example-rpi3.config.system.build.sdImage
# (on an aarch64 machine or with an aarch64 remote builder) and write it with
#   sudo nix run .#example-rpi3-flasher -- --wifi-ssid MyNet result/sd-image/*.img.zst /dev/sdX

{
  networking.hostName = "example-rpi3";
  system.stateVersion = "26.05";

  stateless.sdImage.wifi.enable = true;

  # Nothing to build on a 1 GB board; updates are built elsewhere and
  # pushed with nixos-rebuild --target-host.
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;
  documentation.enable = false;

  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=32M
  '';

  zramSwap.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  users.mutableUsers = false;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyReplaceMeExampleKeyReplaceMe00 you@example"
  ];
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
}
