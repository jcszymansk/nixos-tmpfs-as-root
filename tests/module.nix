/**
  Fast runtime test of the stateless module without the installer: a test
  VM with a tmpfs root, persistence and /tmp on two virtual disks. Covers
  account persistence in detail; tests/install.nix covers the whole path.
*/
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "stateless-module";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ self.nixosModules.default ];

      stateless = {
        enable = true;
        disk.enable = false;
        persistPath = "/persist";
        tmp.path = "/scratch/tmp";
      };

      virtualisation.emptyDiskImages = [
        512
        512
      ];
      virtualisation.fileSystems = {
        "/" = lib.mkForce {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "mode=755" ];
        };
        "/persist" = {
          device = "/dev/vdb";
          fsType = "ext4";
          autoFormat = true;
          neededForBoot = true;
        };
        "/scratch" = {
          device = "/dev/vdc";
          fsType = "ext4";
          autoFormat = true;
          neededForBoot = true;
        };
        # qemu-vm replaces fileSystems with these, so restate the module's.
        "/tmp" = {
          device = "/scratch/tmp";
          fsType = "none";
          options = [
            "bind"
            "x-systemd.requires=stateless-tmp-source.service"
          ];
        };
      };

      users.mutableUsers = true;
      users.users.alice = {
        isNormalUser = true;
        initialPassword = "alicepw";
      };
      # test-instrumentation gives root an empty password file, which userborn
      # would re-apply on every boot.
      users.users.root.hashedPasswordFile = lib.mkForce null;
      systemd.enableEmergencyMode = false;
      # Without KVM, udev can take longer than test-instrumentation's 300 s
      # to create the serial device the test backdoor waits for.
      systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce "15min";
    };

  testScript = ''
    def persisted(f: str) -> str:
        return machine.succeed(f"cat /persist/etc/{f}")

    machine.wait_for_unit("multi-user.target")
    print(machine.succeed("systemctl --failed --no-legend --plain"))
    assert machine.succeed("systemctl --failed --no-legend --plain").strip() == ""

    with subtest("tmpfs root, /tmp on disk"):
        assert machine.succeed("findmnt -n -o FSTYPE /").strip() == "tmpfs"
        assert machine.succeed("stat -c %a /").strip() == "755"
        assert machine.succeed("findmnt -n -o SOURCE /tmp").strip().endswith("[/tmp]")
        assert machine.succeed("stat -c %a /tmp").strip() == "1777"

    with subtest("first boot persists the generated databases"):
        machine.wait_until_succeeds("cmp /etc/passwd /persist/etc/passwd", timeout=30)
        machine.succeed("cmp /etc/shadow /persist/etc/shadow")
        machine.succeed("systemctl is-active stateless-persist-account-files.service")

    with subtest("chpasswd reaches the disk"):
        before = persisted("shadow")
        machine.succeed("echo 'alice:alicepw2' | chpasswd")
        machine.wait_until_succeeds("cmp /etc/shadow /persist/etc/shadow", timeout=10)
        assert persisted("shadow") != before

    with subtest("useradd reaches the disk"):
        machine.succeed("useradd -m bob && echo 'bob:bobpw' | chpasswd")
        machine.wait_until_succeeds("grep -q '^bob:' /persist/etc/passwd", timeout=10)
        machine.wait_until_succeeds("grep -q '^bob:' /persist/etc/shadow", timeout=10)

    with subtest("a burst of changes is not partly lost"):
        machine.succeed(
            "for i in $(seq 1 20); do useradd u$i && echo u$i:pw$i | chpasswd; done"
        )
        machine.wait_until_succeeds("cmp /etc/shadow /persist/etc/shadow", timeout=10)
        machine.succeed("cmp /etc/passwd /persist/etc/passwd")
        machine.succeed("grep -q '^u20:' /persist/etc/shadow")

    with subtest("a change right before shutdown is not lost"):
        machine.succeed("useradd carol")
        machine.shutdown()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("getent passwd carol")

    with subtest("after reboot: accounts restored as files, userborn merged"):
        machine.succeed("getent passwd bob")
        machine.succeed("getent passwd alice")
        machine.succeed("test -f /etc/shadow -a ! -L /etc/shadow")
        assert machine.succeed("systemctl --failed --no-legend --plain").strip() == ""
        machine.succeed("cmp /etc/shadow /persist/etc/shadow")
  '';
}
