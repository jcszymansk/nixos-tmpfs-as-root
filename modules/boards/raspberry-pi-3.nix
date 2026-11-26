/**
  Raspberry Pi 3 (B, B+) board support for `nixosModules.sdImage`:
  GPU firmware, U-Boot and device trees on the FAT partition, and only the
  firmware this board needs (the generic set is about 800 MiB).

  Boot chain: GPU firmware (bootcode.bin, start.elf) reads config.txt and
  starts U-Boot, which reads boot/extlinux/extlinux.conf from the bootable
  NIX partition and boots the NixOS kernel.
*/
{ lib, pkgs, ... }:

let
  configTxt = pkgs.writeText "config.txt" ''
    kernel=u-boot-rpi3.bin

    # Boot in 64-bit mode.
    arm_64bit=1

    # U-Boot needs the UART enabled; a fixed core clock keeps the mini UART
    # baud rate stable, otherwise serial output is garbled.
    enable_uart=1
    core_freq=250

    # Keep the firmware from drawing over the kernel's framebuffer with
    # low-voltage or temperature warnings.
    avoid_warnings=1
  '';

  boot = "${pkgs.raspberrypifw}/share/raspberrypi/boot";
in
{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # sd-image.nix enables all hardware, which includes every redistributable
  # firmware blob; the Pi 3 needs only its Broadcom Wi-Fi/Bluetooth ones.
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  # ttyS1 is the mini UART on the GPIO header with the mainline kernel.
  boot.kernelParams = [
    "console=ttyS1,115200n8"
    "console=tty0"
  ];

  sdImage.populateFirmwareCommands = ''
    cp ${boot}/bootcode.bin ${boot}/fixup*.dat ${boot}/start*.elf firmware/
    cp ${configTxt} firmware/config.txt
    cp ${pkgs.ubootRaspberryPi3_64bit}/u-boot.bin firmware/u-boot-rpi3.bin
    cp ${boot}/bcm2710-rpi-3-b.dtb ${boot}/bcm2710-rpi-3-b-plus.dtb firmware/
  '';
}
