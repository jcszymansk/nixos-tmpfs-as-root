/**
  Runtime side of a stateless NixOS host: `/` is a tmpfs rebuilt on every
  boot, everything worth keeping lives under `stateless.persistPath` on disk.

  ```
   disk                                   runtime view
   ────                                   ────────────
   /nix/store ─────────────────────────── /nix/store
   /nix/persist/var  ──bind (initrd)────▶ /var
   /nix/persist/home ──bind─────────────▶ /home
   /nix/persist/etc/machine-id ──bind───▶ /etc/machine-id
   /nix/persist/etc/{passwd,shadow,..}
          │  ▲
          │  └── stateless-persist-account-files (path unit, on change)
          └───── stateless-restore-account-files (boot, before userborn) ─▶ /etc
   /nix/tmp ──────────bind──────────────▶ /tmp
   (tmpfs) ─────────────────────────────▶ / , /etc, ...
  ```

  Account databases are copied rather than linked because neither
  shadow-utils (opens with O_NOFOLLOW) nor pam_unix (renames a temp file
  over /etc/shadow) can write through a symlink, and rename() onto a bind
  mount fails with EBUSY.
*/
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.stateless;

  persistEtc = "${cfg.persistPath}/etc";

  accountFiles = [
    "passwd"
    "group"
    "shadow"
    "gshadow"
    "subuid"
    "subgid"
  ];

  copyAccountFiles = pkgs.writeShellApplication {
    name = "stateless-copy-account-files";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = ''
      ${lib.toShellVar "account_files" accountFiles}
      ${builtins.readFile ../scripts/copy-account-files.sh}
    '';
  };

  copyAccountFilesExe = lib.getExe copyAccountFiles;

  /**
    Longest `fileSystems` mount point that is a prefix of `path`.

    # Arguments
    - `path`: absolute path to resolve.

    # Returns
    The mount point string, `/` when nothing more specific matches.
  */
  mountPointOf =
    path:
    let
      isPrefix = mp: mp == "/" || path == mp || lib.hasPrefix "${mp}/" path;
      candidates = lib.filter isPrefix (lib.attrNames config.fileSystems);
    in
    lib.foldl' (best: mp: if lib.stringLength mp > lib.stringLength best then mp else best) "/" candidates;

  rootFs = config.fileSystems."/" or null;
in
{
  options.stateless = {
    enable = lib.mkEnableOption "a stateless system with a tmpfs root and an on-disk persistence directory";

    persistPath = lib.mkOption {
      type = lib.types.strMatching "/.+[^/]";
      default = "/nix/persist";
      description = ''
        Directory on a disk filesystem holding everything that survives a
        reboot. It must not live on the tmpfs root.
      '';
    };

    persistence.defaultDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/var"
        "/home"
        "/root"
      ]
      ++ lib.optional config.networking.networkmanager.enable "/etc/NetworkManager/system-connections";
      defaultText = lib.literalExpression ''
        [ "/var" "/home" "/root" ]
        ++ lib.optional config.networking.networkmanager.enable "/etc/NetworkManager/system-connections"
      '';
      description = ''
        Directories persisted by default. Override this to persist less than
        the whole of `/var`; add more through
        `environment.persistence.''${config.stateless.persistPath}.directories`.
      '';
    };

    tmp.path = lib.mkOption {
      type = lib.types.strMatching "/.+[^/]";
      default = "/nix/tmp";
      description = ''
        On-disk directory bind-mounted at `/tmp`, so large temporary files
        do not eat RAM. Keep it outside `persistPath` so it never ends up in
        backups. systemd's stock tmpfiles rule ages it out after 10 days; set
        `boot.tmp.cleanOnBoot` to also wipe it on boot.
      '';
    };

    accounts.persist = lib.mkOption {
      type = lib.types.bool;
      default = config.users.mutableUsers;
      defaultText = lib.literalExpression "config.users.mutableUsers";
      description = ''
        Keep imperative account changes (`passwd`, `useradd`, ...) across
        reboots by restoring ${lib.concatStringsSep ", " accountFiles} from
        `''${persistPath}/etc` before userborn runs, and copying them back
        whenever they change.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = rootFs != null && rootFs.fsType == "tmpfs";
            message = "stateless: fileSystems.\"/\" must be a tmpfs.";
          }
          {
            assertion = rootFs != null && lib.elem "mode=755" rootFs.options;
            message = ''
              stateless: fileSystems."/" needs the "mode=755" option. The tmpfs
              default is 1777, which makes OpenSSH refuse logins.
            '';
          }
          {
            assertion = mountPointOf cfg.persistPath != "/";
            message = "stateless: persistPath ${cfg.persistPath} is on the tmpfs root; it must be on a disk filesystem.";
          }
          {
            assertion = mountPointOf cfg.tmp.path != "/";
            message = "stateless: tmp.path ${cfg.tmp.path} is on the tmpfs root; it must be on a disk filesystem.";
          }
          {
            assertion = !lib.hasPrefix "${cfg.persistPath}/" cfg.tmp.path;
            message = "stateless: tmp.path ${cfg.tmp.path} must not be inside persistPath ${cfg.persistPath}.";
          }
          {
            assertion = !config.boot.tmp.useTmpfs;
            message = "stateless: boot.tmp.useTmpfs conflicts with keeping /tmp on disk.";
          }
        ];

        environment.persistence.${cfg.persistPath} = {
          hideMounts = true;
          directories = cfg.persistence.defaultDirectories;
          files = [ "/etc/machine-id" ];
        };

        services.openssh.hostKeys = lib.mkDefault [
          {
            type = "ed25519";
            path = "${persistEtc}/ssh/ssh_host_ed25519_key";
          }
          {
            type = "rsa";
            bits = 4096;
            path = "${persistEtc}/ssh/ssh_host_rsa_key";
          }
        ];

        systemd.services.stateless-tmp-source = {
          description = "Create the on-disk backing directory of /tmp";
          before = [ "tmp.mount" ];
          unitConfig = {
            DefaultDependencies = false;
            RequiresMountsFor = [ cfg.tmp.path ];
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/install -d -m 1777 -o root -g root ${cfg.tmp.path}";
          };
        };

        fileSystems."/tmp" = {
          device = cfg.tmp.path;
          fsType = "none";
          options = [
            "bind"
            "x-systemd.requires=stateless-tmp-source.service"
          ];
        };
      }

      (lib.mkIf cfg.accounts.persist {
        assertions = [
          {
            assertion = config.services.userborn.enable && config.services.userborn.passwordFilesLocation == "/etc";
            message = ''
              stateless.accounts.persist requires services.userborn with
              passwordFilesLocation = "/etc"; the restore unit is ordered
              against userborn.service.
            '';
          }
        ];

        services.userborn.enable = true;

        systemd.services.stateless-restore-account-files = {
          description = "Restore mutable account databases from ${persistEtc}";
          requiredBy = [ "userborn.service" ];
          before = [
            "userborn.service"
            "shutdown.target"
          ];
          conflicts = [ "shutdown.target" ];
          restartIfChanged = false;
          unitConfig = {
            DefaultDependencies = false;
            RequiresMountsFor = [ persistEtc ];
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${copyAccountFilesExe} ${persistEtc} /etc";
          };
        };

        systemd.paths.stateless-persist-account-files = {
          description = "Watch account databases in /etc";
          wantedBy = [ "paths.target" ];
          pathConfig.PathChanged = map (f: "/etc/${f}") accountFiles;
        };

        systemd.services.stateless-persist-account-files = {
          description = "Copy account databases to ${persistEtc}";
          wantedBy = [ "multi-user.target" ];
          after = [ "userborn.service" ];
          unitConfig.RequiresMountsFor = [ persistEtc ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${copyAccountFilesExe} /etc ${persistEtc}";
          };
        };

        # Closes the gap between a last-second change and the path unit
        # firing: stopping happens before /nix is unmounted.
        systemd.services.stateless-persist-account-files-on-shutdown = {
          description = "Copy account databases to ${persistEtc} at shutdown";
          wantedBy = [ "multi-user.target" ];
          after = [ "userborn.service" ];
          unitConfig.RequiresMountsFor = [ persistEtc ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
            ExecStop = "${copyAccountFilesExe} /etc ${persistEtc}";
          };
        };
      })
    ]
  );
}
