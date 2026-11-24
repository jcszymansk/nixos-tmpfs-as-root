/**
  End-to-end test: boot the real installer ISO (UEFI) with a blank disk,
  run `stateless-install`, boot the installed disk and check the stateless
  invariants, including across a reboot.

  # Arguments
  - `name`: test name suffix.
  - `disk`: overrides for `stateless.disk` of the target.
*/
{
  pkgs,
  lib,
  self,
}:
{ name, disk }:

let

  luksPassphrase = "correct horse battery staple";
  encrypted = disk.encryption.enable or false;
  nixFsType = disk.nixFsType or "ext4";
  hasSwap = (disk.swap.size or null) != null;
  pyBool = b: if b then "True" else "False";

  testInstrumentation = "${pkgs.path}/nixos/modules/testing/test-instrumentation.nix";

  target = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      ../examples/host.nix
      testInstrumentation
      {
        stateless.disk = disk;
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
    ];
  };

  installer = self.lib.mkInstaller {
    inherit target;
    modules = [ testInstrumentation ];
  };

  iso = installer.config.system.build.isoImage;
  isoPath = "${iso}/iso/${iso.isoName}";
  persist = target.config.stateless.persistPath;
  qemu = "${pkgs.qemu_test}/bin/qemu-system-x86_64";
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
        if with_iso:
            flags += ["-cdrom", "${isoPath}"]
        return " ".join(flags)


    def boot_installed(name: str):
        m = create_machine(start_command(False), name=name)
        m.start()
        if ENCRYPTED:
            m.wait_for_console_text("Please enter passphrase")
            m.send_console(f"{LUKS_PASSPHRASE}\n")
        m.wait_for_unit("multi-user.target")
        return m


    def login(m, user: str, password: str) -> None:
        m.send_key("alt-f2")
        m.wait_until_succeeds("[ $(fgconsole) = 2 ]")
        m.wait_for_unit("getty@tty2.service")
        m.wait_until_tty_matches("2", "login: ")
        m.send_chars(f"{user}\n")
        m.wait_until_tty_matches("2", "Password: ")
        m.send_chars(f"{password}\n")
        m.wait_until_succeeds(f"pgrep -u {user} -t tty2 bash")
        m.send_chars("exit\n")
        m.wait_until_fails(f"pgrep -u {user} -t tty2 bash")


    with subtest("install from the ISO"):
        installer = create_machine(start_command(True), name="installer")
        installer.start()
        installer.wait_for_unit("multi-user.target")
        installer.succeed("printf 'root:rootpw\\nalice:alicepw\\n' > /run/passwords")
        install_command = "stateless-install --yes --passwords-file /run/passwords"
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

    with subtest("passwords set by the installer work"):
        login(machine, "alice", "alicepw")
        login(machine, "root", "rootpw")

    with subtest("account databases are restored files, not symlinks"):
        for f in ["passwd", "group", "shadow"]:
            machine.succeed(f"test -f /etc/{f} -a ! -L /etc/{f}")
            machine.succeed(f"cmp /etc/{f} ${persist}/etc/{f}")
        machine.succeed("systemctl is-active stateless-persist-account-files.path")

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
        machine.succeed("getent passwd bob")
        machine.succeed("test -d /home/bob")
        login(machine, "alice", "alicepw2")
        login(machine, "bob", "bobpw")
        machine.succeed("test -f /etc/shadow -a ! -L /etc/shadow")
        machine.fail("journalctl -b -u stateless-restore-account-files -u stateless-persist-account-files | grep -E 'refusing|failed'")

    machine.shutdown()
  '';
}
