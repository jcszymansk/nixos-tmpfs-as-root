{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "example";
  system.stateVersion = "26.05";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  stateless = {
    enable = true;
    disk = {
      device = "/dev/vda";
      # nixFsType = "btrfs";
      # encryption.enable = true;
      # swap.size = "8G";
    };
  };

  users.mutableUsers = true;
  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  services.openssh.enable = true;
}
