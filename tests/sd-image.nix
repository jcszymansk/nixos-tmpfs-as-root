/**
  End-to-end test of the SD card path: a writer VM runs the real flasher
  onto a blank virtual card, then the card boots on its own through U-Boot
  (QEMU's virt machine standing in for the board; board firmware on the
  FAT partition is only exercised on real hardware).

  aarch64 only: the image is an aarch64 system booted by aarch64 U-Boot.
*/
{
  pkgs,
  self,
}:

let
  inherit (pkgs) lib;

  testInstrumentation = "${pkgs.path}/nixos/modules/testing/test-instrumentation.nix";
  qemuCommon = import "${pkgs.path}/nixos/lib/qemu-common.nix" { inherit (pkgs) lib stdenv; };

  target = self.nixosConfigurations.example-rpi3.extendModules {
    modules = [
      testInstrumentation
      "${pkgs.path}/nixos/modules/profiles/qemu-guest.nix"
      {
        # QEMU's virt machine has its UART at ttyAMA0; the last console=
        # becomes /dev/console, which the test driver reads.
        boot.kernelParams = lib.mkAfter [ "console=ttyAMA0,115200n8" ];
        systemd.enableEmergencyMode = false;
        # Without KVM, udev can take longer than test-instrumentation's 300 s
        # to create the serial device the test backdoor waits for.
        systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce "15min";
        users.users.root.hashedPasswordFile = lib.mkForce null;
      }
    ];
  };

  image = target.config.system.build.sdImage;
  imageFile = "${image}/sd-image/${target.config.image.fileName}";
  flasher = self.lib.mkSdFlasher { inherit pkgs target; };
  persist = target.config.stateless.persistPath;
  passphrase = "correct horse battery staple";
in
pkgs.testers.runNixOSTest {
  name = "stateless-sd-image";

  nodes.writer = {
    # See the card's DefaultDeviceTimeoutSec above.
    systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce "15min";
    virtualisation.emptyDiskImages = [ 4096 ];
    virtualisation.memorySize = 1024;
    environment.systemPackages = [ flasher ];
  };

  testScript = ''
    import os

    created = []


    def boot_card(name: str):
        card = os.path.join(writer.state_dir, "empty0.qcow2")
        command = " ".join([
            "${qemuCommon.qemuBinary pkgs.qemu_test}", "-m", "1024",
            "-bios", "${pkgs.ubootQemuAarch64}/u-boot.bin",
            "-drive", f"file={card},if=virtio,format=qcow2",
        ])
        m = create_machine(command, name=name)
        created.append(m)
        m.start()
        m.wait_for_unit("multi-user.target")
        return m


    try:
        with subtest("flash the image onto a blank card"):
            writer.start()
            writer.wait_for_unit("multi-user.target")
            writer.succeed("printf '%s\\n' '${passphrase}' > /run/psk")
            writer.fail("flash-sd --yes ${imageFile} /dev/vdb1")
            writer.fail("flash-sd --yes --wifi-psk-file /run/psk ${imageFile} /dev/vdb")
            # execute, not succeed: the flasher's own output is the only
            # useful diagnostic when it fails.
            status, out = writer.execute(
                "flash-sd --yes --wifi-ssid TestNet --wifi-psk-file /run/psk ${imageFile} /dev/vdb 2>&1"
            )
            print(out)
            assert status == 0, f"flash-sd exited with {status}"
            assert "machine-id: " in out
            writer.succeed("mount /dev/disk/by-label/NIX /mnt")
            assert writer.succeed("stat -c %a /mnt/persist/etc/wpa_supplicant/networks.conf").strip() == "600"
            writer.succeed("grep -q 'ssid=\"TestNet\"' /mnt/persist/etc/wpa_supplicant/networks.conf")
            writer.fail("grep -r -F '${passphrase}' /mnt/persist")
            writer.succeed("test -d /mnt/persist/var -a -d /mnt/store -a -f /mnt/boot/extlinux/extlinux.conf")
            assert writer.succeed("stat -c %a /mnt/tmp").strip() == "1777"
            writer.succeed("umount /mnt")
            writer.shutdown()

        with subtest("the card boots: tmpfs root, card at /nix, grown to the card"):
            card = boot_card("card")
            assert card.succeed("findmnt -n -o FSTYPE /").strip() == "tmpfs"
            assert "size=262144k" in card.succeed("findmnt -n -o OPTIONS /")
            assert card.succeed("findmnt -n -o FSTYPE /nix").strip() == "ext4"
            assert card.succeed("findmnt -n -o SOURCE /boot").strip().endswith("[/boot]")
            card.succeed("test -f /boot/extlinux/extlinux.conf")
            nix_bytes = int(card.succeed("df -B1 --output=size /nix | tail -1").strip())
            assert nix_bytes > 3 * 1024**3, f"/nix was not grown to the 4 GiB card: {nix_bytes}"
            assert card.succeed("findmnt -n -o SOURCE /tmp").strip().endswith("[/tmp]")
            assert card.succeed("systemctl --failed --no-legend --plain").strip() == ""

        with subtest("the store is registered and the system profile exists"):
            card.succeed("nix-store --verify-path /run/current-system")
            card.succeed("test -L /nix/var/nix/profiles/system")
            card.fail("test -e /nix/nix-path-registration")

        with subtest("identity comes from the flasher"):
            machine_id = card.succeed("cat /etc/machine-id").strip()
            assert machine_id in out
            card.wait_for_unit("sshd.service")
            host_key = card.succeed("ssh-keygen -l -f ${persist}/etc/ssh/ssh_host_ed25519_key.pub").strip()
            assert host_key.split()[1] in out

        with subtest("Wi-Fi networks reach wpa_supplicant, readable only by it"):
            assert card.succeed("stat -c '%a %U %G' /run/stateless-wifi/networks.conf").strip() == "640 root wpa_supplicant"
            card.succeed("grep -q 'ssid=\"TestNet\"' /run/stateless-wifi/networks.conf")
            assert "-I /run/stateless-wifi/networks.conf" in card.succeed("systemctl cat wpa_supplicant.service")

        with subtest("state survives a reboot, the rest does not"):
            card.succeed("touch /root/kept /etc/ephemeral")
            card.shutdown()
            card = boot_card("card-again")
            card.succeed("test -e /root/kept")
            card.fail("test -e /etc/ephemeral")
            assert card.succeed("cat /etc/machine-id").strip() == machine_id
            card.shutdown()
    finally:
        for vm in created:
            vm.crash()
  '';
}
