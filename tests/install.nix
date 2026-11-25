/**
  End-to-end test: boot the real installer ISO (UEFI) with a blank disk,
  run `stateless-install`, boot the installed disk and check the stateless
  invariants, including across a reboot.

  # Arguments
  - `name`: test name suffix.
  - `disk`: overrides for `stateless.disk` of the target.
  - `mutableUsers`: with false, users and passwords come from the
    configuration (through userborn) and nothing about them is persisted.
*/
{
  pkgs,
  lib,
  self,
}:
{
  name,
  disk,
  mutableUsers ? true,
}:

let

  luksPassphrase = "correct horse battery staple";
  encrypted = disk.encryption.enable or false;
  nixFsType = disk.nixFsType or "ext4";
  hasSwap = (disk.swap.size or null) != null;
  pyBool = b: if b then "True" else "False";

  # yescrypt of "alicepw" and "rootpw", for the immutable variant.
  aliceHash = "$y$j9T$BKr7XFqxq0jf5rnAtJIQe1$riKhHLw8HbC9NiFrufvwu8Y9TXOQFzW1uR133srib4/";
  rootHash = "$y$j9T$25wDNvyuYKDbf8NLj2EF..$yC.yi7qVmY4b42nPXU7jYMEsET0wMiAAvkmWipxUbg2";

  testInstrumentation = "${pkgs.path}/nixos/modules/testing/test-instrumentation.nix";
  qemuCommon = import "${pkgs.path}/nixos/lib/qemu-common.nix" { inherit (pkgs) lib stdenv; };
  serial = qemuCommon.qemuSerialDevice;

  target = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      ../examples/host.nix
      testInstrumentation
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        stateless.disk = disk;
        # The last console= becomes /dev/console. test-instrumentation ends
        # with tty0, which would hide initrd output and the LUKS prompt.
        boot.kernelParams = lib.mkAfter [ "console=${serial}" ];
        # A failed unit must fail the test, not park the VM in emergency
        # mode where the driver waits for its backdoor until the timeout.
        systemd.enableEmergencyMode = false;
        # Without KVM, udev can take longer than test-instrumentation's 300 s
        # to create the serial device the test backdoor waits for.
        systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce "15min";
        # test-instrumentation gives root an empty password file, which would
        # override both the installer's password and hashedPassword below.
        users.users.root.hashedPasswordFile = lib.mkForce null;
        # A cheap KDF keeps the test fast; real installs use the default.
        disko.devices.disk.main.content.partitions = lib.mkIf encrypted {
          luks.content.extraFormatArgs = [
            "--pbkdf"
            "pbkdf2"
            "--pbkdf-force-iterations"
            "1000"
          ];
        };
      }
      (lib.mkIf (!mutableUsers) {
        users.mutableUsers = lib.mkForce false;
        services.userborn.enable = true;
        users.users.alice.hashedPassword = aliceHash;
        users.users.root.hashedPassword = rootHash;
      })
    ];
  };

  installer = self.lib.mkInstaller {
    inherit target;
    modules = [
      testInstrumentation
      # Level 19 takes minutes to compress and gains nothing in a test.
      { isoImage.squashfsCompression = "zstd -Xcompression-level 3"; }
    ];
  };

  iso = installer.config.system.build.isoImage;
  isoPath = "${iso}/iso/${iso.isoName}";
  persist = target.config.stateless.persistPath;
  qemu = qemuCommon.qemuBinary pkgs.qemu_test;
in
pkgs.testers.runNixOSTest {
  name = "stateless-install-${name}";
  nodes = { };

  testScript = ''
    import os
    import shutil
    import subprocess
    import tempfile

    ENCRYPTED = ${pyBool encrypted}
    NIX_FS_TYPE = "${nixFsType}"
    HAS_SWAP = ${pyBool hasSwap}
    LUKS_PASSPHRASE = "${luksPassphrase}"
    MUTABLE_USERS = ${pyBool mutableUsers}
    state = tempfile.mkdtemp()
    disk_image = os.path.join(state, "disk.qcow2")
    efi_vars = os.path.join(state, "OVMF_VARS.fd")
    subprocess.run(["${pkgs.qemu_test}/bin/qemu-img", "create", "-f", "qcow2", disk_image, "8G"], check=True)
    shutil.copy("${pkgs.OVMF.variables}", efi_vars)
    os.chmod(efi_vars, 0o644)


    def start_command(with_iso: bool) -> str:
        flags = [
            "${qemu}", "-m", "3072", "-smp", "2",
            "-drive", f"file={disk_image},if=virtio,format=qcow2",
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.firmware}",
            "-drive", f"if=pflash,format=raw,unit=1,file={efi_vars}",
        ]
        # A read-only virtio disk rather than -cdrom: aarch64's virt machine
        # has no IDE controller. Listed after the target, so that stays vda.
        if with_iso:
            flags += ["-drive", "file=${isoPath},if=virtio,format=raw,readonly=on"]
        return " ".join(flags)


    # The driver only cleans up machines declared in `nodes`; one made with
    # create_machine and left running after a failure keeps the driver
    # waiting forever, so the body below stops them in a finally.
    created = []


    def start_vm(command: str, name: str):
        m = create_machine(command, name=name)
        created.append(m)
        return m


    def boot_installed(name: str):
        m = start_vm(start_command(False), name=name)
        m.start()
        if ENCRYPTED:
            m.wait_for_console_text("Please enter passphrase")
            m.send_console(f"{LUKS_PASSPHRASE}\n")
        m.wait_for_unit("multi-user.target")
        failed = m.succeed("systemctl --failed --no-legend --plain").strip()
        assert failed == "", f"failed units:\n{failed}"
        return m


    def login(m, tty: int, user: str, password: str) -> None:
        """Log in on a fresh tty, so prompts left on screen cannot match."""
        m.send_key(f"alt-f{tty}")
        m.wait_until_succeeds(f"[ $(fgconsole) = {tty} ]")
        m.wait_for_unit(f"getty@tty{tty}.service")
        m.wait_until_tty_matches(str(tty), "login: ")
        m.send_chars(f"{user}\n")
        m.wait_until_tty_matches(str(tty), "Password: ")
        m.send_chars(f"{password}\n")
        m.wait_until_succeeds(f"pgrep -u {user} -t tty{tty} bash")
        m.send_chars("exit\n")
        m.wait_until_fails(f"pgrep -u {user} -t tty{tty} bash")


    try:
        with subtest("install from the ISO"):
            installer = start_vm(start_command(True), name="installer")
            installer.start()
            installer.wait_for_unit("multi-user.target")
            install_command = "stateless-install --yes"
            if MUTABLE_USERS:
                installer.succeed("printf 'root:rootpw\\nalice:alicepw\\n' > /run/passwords")
                install_command += " --passwords-file /run/passwords"
            else:
                installer.succeed("printf 'alice:alicepw\\n' > /run/passwords")
                installer.fail("stateless-install --yes --passwords-file /run/passwords")
            if ENCRYPTED:
                installer.succeed(f"printf '%s\\n' '{LUKS_PASSPHRASE}' > /run/luks")
                install_command += " --luks-passphrase-file /run/luks"
            installer.fail("stateless-install --yes --bogus")
            out = installer.succeed(f"{install_command} 2>&1")
            print(out)
            assert "machine-id: " in out
            assert "Activation script snippet" not in out, "activation failed in the chroot"
            assert "chown: invalid user" not in out, "the chroot had no account databases"
            installer.fail("test -e ${target.config.stateless.disk.encryption.passwordFile}")
            installer.shutdown()

        with subtest("first boot: the root is a tmpfs, state comes from disk"):
            machine = boot_installed("installed")
            root = machine.succeed("findmnt -n -o FSTYPE,OPTIONS /").split()
            assert root[0] == "tmpfs", root
            assert machine.succeed("stat -c %a /").strip() == "755"
            assert machine.succeed("findmnt -n -o FSTYPE /nix").strip() == NIX_FS_TYPE
            if NIX_FS_TYPE == "btrfs":
                assert "compress-force=zstd" in machine.succeed("findmnt -n -o OPTIONS /nix")
            if ENCRYPTED:
                machine.succeed("cryptsetup status cryptnix")
                machine.succeed("lvs stateless/nix")
            swaps = machine.succeed("swapon --show=NAME --noheadings").strip()
            assert (swaps != "") == HAS_SWAP, f"swap expected: {HAS_SWAP}, active: {swaps!r}"

        with subtest("/tmp is a bind mount of an on-disk directory outside persistence"):
            source = machine.succeed("findmnt -n -o SOURCE /tmp").strip()
            assert source.endswith("[/tmp]"), f"/tmp should be /nix/tmp on the /nix device, got {source}"
            assert machine.succeed("stat -c %a /tmp").strip() == "1777"
            assert machine.succeed("stat -c %d /tmp").strip() == machine.succeed("stat -c %d /nix").strip()
            machine.succeed("dd if=/dev/zero of=/tmp/big bs=1M count=64")
            machine.succeed("test -s /nix/tmp/big")
            machine.succeed("rm /tmp/big")

        with subtest("machine-id and host keys come from persistence"):
            machine_id = machine.succeed("cat /etc/machine-id").strip()
            assert machine_id == machine.succeed("cat ${persist}/etc/machine-id").strip()
            assert machine_id in out, "installer printed a different machine-id"
            machine.wait_for_unit("sshd.service")
            host_key = machine.succeed("ssh-keygen -l -f ${persist}/etc/ssh/ssh_host_ed25519_key.pub").strip()
            assert host_key.split()[1] in out, "installer printed a different host key"
            machine.succeed("test ! -e /etc/ssh/ssh_host_ed25519_key")

        with subtest("passwords set by the installer or the configuration work"):
            login(machine, 2, "alice", "alicepw")
            login(machine, 3, "root", "rootpw")

        with subtest("account databases are plain files in /etc"):
            for f in ["passwd", "group", "shadow"]:
                machine.succeed(f"test -f /etc/{f} -a ! -L /etc/{f}")
                if MUTABLE_USERS:
                    machine.succeed(f"cmp /etc/{f} ${persist}/etc/{f}")
                else:
                    machine.fail(f"test -e ${persist}/etc/{f}")
            if MUTABLE_USERS:
                machine.succeed("systemctl is-active stateless-persist-account-files.service")
            else:
                machine.fail("systemctl cat stateless-persist-account-files.service")

        if MUTABLE_USERS:
            with subtest("imperative account changes reach the disk promptly"):
                machine.succeed("echo 'alice:alicepw2' | chpasswd")
                machine.succeed("useradd -m bob && echo 'bob:bobpw' | chpasswd")
                machine.wait_until_succeeds("grep -q '^bob:' ${persist}/etc/passwd", timeout=10)
                machine.wait_until_succeeds("cmp /etc/shadow ${persist}/etc/shadow", timeout=10)

        machine.succeed("touch /etc/ephemeral /root/kept /tmp/kept-tmp")

        machine.shutdown()

        with subtest("second boot: changes survive, ephemeral files do not"):
            machine = boot_installed("installed-again")
            assert machine.succeed("cat /etc/machine-id").strip() == machine_id
            assert machine.succeed("ssh-keygen -l -f ${persist}/etc/ssh/ssh_host_ed25519_key.pub").strip() == host_key
            machine.fail("test -e /etc/ephemeral")
            machine.succeed("test -e /root/kept")
            machine.succeed("test -e /tmp/kept-tmp")
            machine.succeed("test -f /etc/shadow -a ! -L /etc/shadow")
            if MUTABLE_USERS:
                machine.succeed("getent passwd bob")
                machine.succeed("test -d /home/bob")
                login(machine, 2, "alice", "alicepw2")
                login(machine, 3, "bob", "bobpw")
                machine.fail("journalctl -b -u stateless-restore-account-files -u stateless-persist-account-files | grep -E 'refusing|failed'")
            else:
                login(machine, 2, "alice", "alicepw")

        machine.shutdown()
    finally:
        for vm in created:
            vm.crash()
  '';
}
