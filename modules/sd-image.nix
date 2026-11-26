/**
  A stateless system as a ready-to-write SD card image (MBR, so boards
  without GPT boot support such as the Raspberry Pi 3 can boot it).

  ```
  MBR
  ├─ 1  FAT32 FIRMWARE   board firmware + U-Boot (stateless.sdImage board module)
  └─ 2  ext4  NIX        bootable flag, mounted at /nix, grown to the card on first boot
         ├─ store/            Nix store
         ├─ boot/extlinux/    read by U-Boot; bind-mounted at /boot
         ├─ persist/          state, see modules/stateless.nix
         └─ tmp/              bind-mounted at /tmp
  tmpfs (mode=755) on /
  ```

  Built on nixpkgs' sd-image.nix (MBR layout, firmware partition, store
  registration on first boot) with a filesystem creator that lays the store
  out for mounting at /nix instead of /.

  Per-card state (machine-id, SSH host keys, Wi-Fi networks) is not in the
  image; `lib.mkSdFlasher` writes it onto the card after flashing.
*/
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  cfg = config.stateless.sdImage;
  stateless = config.stateless;

  label = "NIX";

  /**
    Path of `path` inside the /nix filesystem, e.g. "/nix/persist" -> "persist".
  */
  inNixFs = path: lib.removePrefix "/nix/" path;

  persistence = config.environment.persistence.${stateless.persistPath};

  wifiSource = "${stateless.persistPath}/etc/wpa_supplicant/networks.conf";
  wifiRuntime = "/run/stateless-wifi/networks.conf";

  populatePersistence = lib.concatMapStrings (
    dir:
    let
      target = "./files/${inNixFs stateless.persistPath}${dir.dirPath}";
    in
    ''
      mkdir -p ${lib.escapeShellArg target}
      chmod ${dir.mode} ${lib.escapeShellArg target}
    ''
  ) persistence.directories;
in
{
  imports = [ "${modulesPath}/installer/sd-card/sd-image.nix" ];

  options.stateless.sdImage = {
    rootSize = lib.mkOption {
      type = lib.types.str;
      default = "256M";
      description = ''
        tmpfs `size=` for /. Small boards have little RAM, and with logs
        shipped elsewhere / only holds /etc and runtime files.
      '';
    };

    wifi.enable = lib.mkEnableOption ''
      Wi-Fi through wpa_supplicant with networks from
      `''${persistPath}/etc/wpa_supplicant/networks.conf`, which the flasher
      writes onto the card. The file stays root-only on the card; a copy
      readable by the wpa_supplicant group is made in /run at boot'';
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.hasPrefix "/nix/" stateless.persistPath;
          message = "stateless.sdImage: persistPath must be under /nix, the only filesystem on the card.";
        }
        {
          assertion = lib.hasPrefix "/nix/" stateless.tmp.path;
          message = "stateless.sdImage: tmp.path must be under /nix, the only filesystem on the card.";
        }
      ];

      stateless = {
        enable = true;
        disk.enable = false;
      };

      boot.loader.grub.enable = false;
      boot.loader.generic-extlinux-compatible.enable = true;

      fileSystems = {
        "/" = lib.mkForce {
          device = "none";
          fsType = "tmpfs";
          options = [
            "mode=755"
            "size=${cfg.rootSize}"
          ];
        };
        "/nix" = {
          device = "/dev/disk/by-label/${label}";
          fsType = "ext4";
          options = [ "noatime" ];
        };
        # U-Boot reads boot/extlinux from the bootable partition, so the
        # files nixos-rebuild installs into /boot must land there.
        "/boot" = {
          device = "/nix/boot";
          fsType = "none";
          options = [
            "bind"
            "x-systemd.requires-mounts-for=/nix"
          ];
        };
      };

      sdImage = {
        rootVolumeLabel = label;
        rootFilesystemCreator = ../lib/make-nix-fs.nix;
        nixPathRegistrationFile = "/nix/nix-path-registration";
        populateRootCommands = ''
          mkdir -p ./files/boot
          ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot

          # The initrd bind-mounts persisted directories and does not create
          # their sources, so they must exist before the first boot.
          ${populatePersistence}
          mkdir -p ./files/${inNixFs stateless.persistPath}/etc
          mkdir -p ./files/${inNixFs stateless.tmp.path}
          chmod 1777 ./files/${inNixFs stateless.tmp.path}
        '';
      };

      # sd-image.nix grows the partition mounted at /; here that is a tmpfs.
      systemd.services.expand-root-partition.script = lib.mkForce ''
        nixPart=$(${lib.getExe' pkgs.util-linux "findmnt"} -n -o SOURCE /nix)
        bootDevice=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo PKNAME "$nixPart")
        partNum=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo MAJ:MIN "$nixPart" | ${lib.getExe pkgs.gawk} -F: '{print $2}')
        echo "growing partition $partNum of $bootDevice ($nixPart)"
        echo ",+," | ${lib.getExe' pkgs.util-linux "sfdisk"} -N"$partNum" --no-reread "$bootDevice"
        ${lib.getExe' pkgs.parted "partprobe"}
        ${lib.getExe' pkgs.e2fsprogs "resize2fs"} "$nixPart"
      '';
    }

    (lib.mkIf cfg.wifi.enable {
      networking.wireless.enable = true;
      networking.wireless.extraConfigFiles = [ wifiRuntime ];

      systemd.services.stateless-wifi-networks = {
        description = "Make the Wi-Fi networks from ${wifiSource} readable by wpa_supplicant";
        wantedBy = [ "network-pre.target" ];
        before = [ "network-pre.target" ];
        unitConfig.RequiresMountsFor = [ wifiSource ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0750 -o root -g wpa_supplicant ${dirOf wifiRuntime}
          if [[ -f ${wifiSource} ]]; then
            install -m 0640 -o root -g wpa_supplicant ${wifiSource} ${wifiRuntime}
            echo "installed $(grep -c 'network={' ${wifiSource}) network(s) from ${wifiSource}"
          else
            echo "${wifiSource} does not exist; no Wi-Fi networks configured" >&2
            install -m 0640 -o root -g wpa_supplicant /dev/null ${wifiRuntime}
          fi
        '';
      };

      systemd.services."wpa_supplicant" = {
        requires = [ "stateless-wifi-networks.service" ];
        after = [ "stateless-wifi-networks.service" ];
      };
    })
  ];
}
