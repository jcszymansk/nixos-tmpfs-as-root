/**
  Evaluation-only tests: assertions fire on broken configurations, option
  defaults and the generated layout are what the docs promise.

  # Returns
  A derivation that fails, listing every failed case, if any case fails.
*/
{
  pkgs,
  lib,
  self,
}:

let
  mkSystem =
    extra:
    lib.nixosSystem {
      modules = [
        self.nixosModules.default
        ../examples/host.nix
        extra
      ];
    };

  failedAssertions =
    system: map (a: a.message) (lib.filter (a: !a.assertion) system.config.assertions);

  /**
    True when exactly the assertions matching `pattern` fail. Assertions of
    the stateless modules only; unrelated nixpkgs ones must not fire.
  */
  failsWith =
    pattern: system:
    let
      failed = failedAssertions system;
    in
    failed != [ ] && lib.all (m: lib.hasInfix pattern m) failed;

  example = mkSystem { };
  cfg = example.config;

  noDisko = extra: mkSystem ({ stateless.disk.enable = false; } // extra);

  encrypted = mkSystem {
    stateless.disk = {
      encryption.enable = true;
      swap.size = "1G";
      nixFsType = "btrfs";
    };
  };

  immutable = mkSystem {
    users.mutableUsers = lib.mkForce false;
    users.allowNoPasswordLogin = true;
  };

  installerFor = target: (self.lib.mkInstaller { inherit target; }).config;

  cases = {
    example-has-no-failed-assertions = failedAssertions example == [ ];

    root-is-mode-755-tmpfs =
      cfg.fileSystems."/".fsType == "tmpfs" && lib.elem "mode=755" cfg.fileSystems."/".options;

    root-size-is-passed-to-tmpfs =
      lib.elem "size=25%"
        (mkSystem {
          stateless.disk.rootSize = "25%";
        }).config.fileSystems."/".options;

    tmp-is-bind-mount-of-nix-tmp =
      cfg.fileSystems."/tmp".device == "/nix/tmp" && lib.elem "bind" cfg.fileSystems."/tmp".options;

    tmp-path-is-configurable =
      (mkSystem { stateless.tmp.path = "/nix/scratch"; }).config.fileSystems."/tmp".device
      == "/nix/scratch";

    machine-id-is-persisted = lib.elem "/etc/machine-id" (
      map (f: f.filePath) cfg.environment.persistence."/nix/persist".files
    );

    default-directories-are-persisted =
      lib.sort lib.lessThan (map (d: d.dirPath) cfg.environment.persistence."/nix/persist".directories)
      == [
        "/home"
        "/root"
        "/var"
      ];

    networkmanager-connections-are-persisted-with-networkmanager =
      lib.elem "/etc/NetworkManager/system-connections"
        (
          map (d: d.dirPath)
            (mkSystem { networking.networkmanager.enable = true; })
            .config.environment.persistence."/nix/persist".directories
        );

    ssh-host-keys-live-in-persistence = lib.all (
      k: lib.hasPrefix "/nix/persist/etc/ssh/" k.path
    ) cfg.services.openssh.hostKeys;

    mutable-users-enable-account-persistence =
      cfg.stateless.accounts.persist
      && cfg.services.userborn.enable
      && cfg.systemd.services ? stateless-restore-account-files
      && lib.elem "userborn.service" cfg.systemd.services.stateless-restore-account-files.requiredBy
      && lib.elem "userborn.service" cfg.systemd.services.stateless-restore-account-files.before;

    immutable-users-skip-account-persistence =
      !immutable.config.stateless.accounts.persist
      && !(immutable.config.systemd.services ? stateless-restore-account-files)
      && failedAssertions immutable == [ ];

    plain-layout-has-no-lvm = cfg.disko.devices.lvm_vg == { };

    encrypted-layout-uses-luks-and-lvm =
      let
        d = encrypted.config.disko.devices;
      in
      d.disk.main.content.partitions.luks.content.type == "luks"
      && d.lvm_vg.stateless.lvs ? nix
      && d.lvm_vg.stateless.lvs ? swap
      && encrypted.config.boot.initrd.luks.devices ? cryptnix
      && encrypted.config.fileSystems."/nix".fsType == "btrfs"
      && failedAssertions encrypted == [ ];

    luks-passphrase-file-is-not-in-boot-config =
      !(encrypted.config.boot.initrd.luks.devices.cryptnix ? keyFile)
      || encrypted.config.boot.initrd.luks.devices.cryptnix.keyFile == null;

    swap-partition-only-when-requested =
      !(cfg.disko.devices.disk.main.content.partitions ? swap)
      && (mkSystem { stateless.disk.swap.size = "1G"; }).config.disko.devices.disk.main.content.partitions
        ? swap;

    hibernation-needs-swap = failsWith "hibernation needs" (mkSystem {
      stateless.disk.swap.hibernation = true;
    });

    non-tmpfs-root-is-rejected = failsWith "must be a tmpfs" (noDisko {
      fileSystems."/" = {
        device = "/dev/sda1";
        fsType = "ext4";
      };
      fileSystems."/nix" = {
        device = "/dev/sda2";
        fsType = "ext4";
      };
    });

    tmpfs-root-without-mode-755-is-rejected = failsWith "mode=755" (noDisko {
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      fileSystems."/nix" = {
        device = "/dev/sda2";
        fsType = "ext4";
      };
    });

    persist-path-on-root-is-rejected = failsWith "is on the tmpfs root" (mkSystem {
      stateless.persistPath = "/persist";
    });

    tmp-path-on-root-is-rejected = failsWith "is on the tmpfs root" (mkSystem {
      stateless.tmp.path = "/scratch";
    });

    tmp-path-inside-persistence-is-rejected = failsWith "must not be inside persistPath" (mkSystem {
      stateless.tmp.path = "/nix/persist/tmp";
    });

    tmp-on-tmpfs-is-rejected = failsWith "boot.tmp.useTmpfs" (mkSystem {
      boot.tmp.useTmpfs = true;
    });

    account-persistence-needs-userborn-in-etc = failsWith "requires services.userborn" (mkSystem {
      services.userborn.passwordFilesLocation = "/var/lib/nixos";
    });

    installer-asks-root-and-normal-users =
      (installerFor example).stateless.installer.passwordUsers == [
        "root"
        "alice"
      ];

    installer-asks-nobody-for-immutable-users =
      (installerFor immutable).stateless.installer.passwordUsers == [ ];

    installer-follows-target-architecture =
      (installerFor (mkSystem {
        nixpkgs.hostPlatform = lib.mkForce "aarch64-linux";
      })).nixpkgs.hostPlatform.system == "aarch64-linux";

    installer-rejects-foreign-architecture = failsWith "must share an architecture" (
      self.lib.mkInstaller {
        target = mkSystem { nixpkgs.hostPlatform = lib.mkForce "aarch64-linux"; };
        modules = [ { nixpkgs.hostPlatform = lib.mkForce "x86_64-linux"; } ];
      }
    );

    installer-has-no-zfs = !((installerFor example).boot.supportedFilesystems.zfs or false);
  };

  failures = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
in
pkgs.runCommand "stateless-eval-tests" { } (
  if failures == [ ] then
    ''
      echo "${toString (lib.length (lib.attrNames cases))} eval cases passed"
      touch $out
    ''
  else
    ''
      echo "failed eval cases:" >&2
      ${lib.concatMapStrings (f: "echo '  ${f}' >&2\n") failures}
      exit 1
    ''
)
