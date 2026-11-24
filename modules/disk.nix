/**
  Disk layout of a stateless host, expressed as a disko config.

  ```
  plain                          encrypted
  ─────                          ─────────
  GPT                            GPT
  ├─ ESP  (vfat, /boot)          ├─ ESP  (vfat, /boot)
  ├─ swap (optional)             └─ LUKS "cryptnix"
  └─ nix  (ext4|btrfs, /nix)        └─ LVM VG "stateless"
                                       ├─ swap (optional)
  tmpfs on /                           └─ nix (ext4|btrfs, /nix)
  ```
*/
{ config, lib, ... }:

let
  cfg = config.stateless.disk;

  nixFilesystem =
    {
      ext4 = {
        type = "filesystem";
        format = "ext4";
        mountpoint = "/nix";
        mountOptions = [ "noatime" ];
      };
      btrfs = {
        type = "filesystem";
        format = "btrfs";
        extraArgs = [ "-f" ];
        mountpoint = "/nix";
        mountOptions = [
          "compress-force=zstd"
          "noatime"
        ];
      };
    }
    .${cfg.nixFsType};

  swapContent = {
    type = "swap";
    resumeDevice = cfg.swap.hibernation;
  };

  esp = {
    priority = 1;
    size = cfg.espSize;
    type = "EF00";
    content = {
      type = "filesystem";
      format = "vfat";
      mountpoint = "/boot";
      mountOptions = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
  };

  plainPartitions = {
    ESP = esp;
    nix = {
      priority = 3;
      size = "100%";
      content = nixFilesystem;
    };
  }
  // lib.optionalAttrs (cfg.swap.size != null) {
    swap = {
      priority = 2;
      inherit (cfg.swap) size;
      content = swapContent;
    };
  };

  encryptedPartitions = {
    ESP = esp;
    luks = {
      priority = 2;
      size = "100%";
      content = {
        type = "luks";
        name = "cryptnix";
        inherit (cfg.encryption) passwordFile;
        settings.allowDiscards = cfg.encryption.allowDiscards;
        content = {
          type = "lvm_pv";
          vg = "stateless";
        };
      };
    };
  };
in
{
  options.stateless.disk = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.stateless.enable;
      defaultText = lib.literalExpression "config.stateless.enable";
      description = ''
        Generate the disko layout below. Disable it to bring your own
        `disko.devices`; the root must still be a `mode=755` tmpfs.
      '';
    };

    device = lib.mkOption {
      type = lib.types.strMatching "/dev/.+";
      example = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0R000000X";
      description = ''
        Whole disk to install to. It is wiped by the installer. Prefer a
        stable `/dev/disk/by-id/` path; the installed system mounts by
        partition label, so this path only matters at install time.
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "Size of the EFI system partition, mounted at /boot.";
    };

    nixFsType = lib.mkOption {
      type = lib.types.enum [
        "ext4"
        "btrfs"
      ];
      default = "ext4";
      description = "Filesystem for /nix, which also holds the persistent data and /tmp.";
    };

    rootSize = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "25%";
      description = "tmpfs `size=` for /. null keeps the kernel default of half the RAM.";
    };

    swap = {
      size = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "16G";
        description = "Swap size; null for no swap.";
      };

      hibernation = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use the swap device as the hibernation resume device.";
      };
    };

    encryption = {
      enable = lib.mkEnableOption "LUKS encryption of everything except the ESP, with LVM inside";

      passwordFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/stateless-install/luks-passphrase";
        description = ''
          Where the installer leaves the passphrase for disko while
          formatting. Only read at install time; the installed system asks
          for the passphrase at boot.
        '';
      };

      allowDiscards = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Pass TRIM through LUKS. Leaks which blocks are in use, which is usually fine on SSDs.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.swap.hibernation -> cfg.swap.size != null;
        message = "stateless.disk.swap.hibernation needs stateless.disk.swap.size.";
      }
    ];

    disko.devices = {
      disk.main = {
        type = "disk";
        inherit (cfg) device;
        content = {
          type = "gpt";
          partitions = if cfg.encryption.enable then encryptedPartitions else plainPartitions;
        };
      };

      lvm_vg = lib.mkIf cfg.encryption.enable {
        stateless = {
          type = "lvm_vg";
          lvs = {
            nix = {
              size = "100%FREE";
              content = nixFilesystem;
            };
          }
          // lib.optionalAttrs (cfg.swap.size != null) {
            swap = {
              inherit (cfg.swap) size;
              content = swapContent;
            };
          };
        };
      };

      nodev."/" = {
        fsType = "tmpfs";
        mountOptions = [ "mode=755" ] ++ lib.optional (cfg.rootSize != null) "size=${cfg.rootSize}";
      };
    };
  };
}
