{
  description = "Installer ISO builder for stateless (tmpfs-as-root) NixOS systems";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      /**
        The example host for one architecture.

        # Arguments
        - `system`: the target platform, e.g. "aarch64-linux".
      */
      mkExample =
        system:
        lib.nixosSystem {
          modules = [
            self.nixosModules.default
            ./examples/host.nix
            { nixpkgs.hostPlatform = system; }
          ];
        };
    in
    {
      nixosModules = {
        default = {
          imports = [
            impermanence.nixosModules.impermanence
            disko.nixosModules.disko
            ./modules/stateless.nix
            ./modules/disk.nix
          ];
        };

        installer = ./modules/installer.nix;

        sdImage = {
          imports = [
            self.nixosModules.default
            ./modules/sd-image.nix
          ];
        };

        raspberryPi3 = ./modules/boards/raspberry-pi-3.nix;
      };

      lib = {
        /**
          Build the installer for a stateless target system.

          # Arguments
          - `target`: a `nixosSystem` importing `nixosModules.default` with
            `stateless.enable = true`.
          - `modules`: extra modules for the installer system itself.

          # Returns
          The installer `nixosSystem`; the ISO is at
          `.config.system.build.isoImage`.
        */
        mkInstaller =
          {
            target,
            modules ? [ ],
          }:
          lib.nixosSystem {
            modules = [
              "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
              self.nixosModules.installer
              {
                nixpkgs.hostPlatform = target.config.nixpkgs.hostPlatform;
                stateless.installer.target = target;
              }
            ]
            ++ modules;
          };

        /**
          Build the flasher for an SD card image: a script that writes the
          image to a card and seeds the per-card machine-id, SSH host keys
          and Wi-Fi networks.

          # Arguments
          - `pkgs`: packages of the machine the card is written on.
          - `target`: a `nixosSystem` importing `nixosModules.sdImage`.

          # Returns
          A package with `bin/flash-sd`; its image is
          `target.config.system.build.sdImage`.
        */
        mkSdFlasher =
          { pkgs, target }:
          let
            cfg = target.config;
          in
          pkgs.writeShellApplication {
            name = "flash-sd";
            runtimeInputs = with pkgs; [
              coreutils
              util-linux
              gawk
              gnugrep
              findutils
              systemd
              openssh
              zstd
              wpa_supplicant
            ];
            text = ''
              ${lib.toShellVars {
                host_name = cfg.networking.hostName;
                persist_path = cfg.stateless.persistPath;
                label = cfg.sdImage.rootVolumeLabel;
                wifi_enabled = lib.boolToString cfg.stateless.sdImage.wifi.enable;
                openssh_enabled = lib.boolToString cfg.services.openssh.enable;
                host_key_specs = map (
                  key: "${key.type}:${toString (key.bits or "")}:${key.path}"
                ) cfg.services.openssh.hostKeys;
              }}
              ${builtins.readFile ./scripts/seed-identity.sh}
              ${builtins.readFile ./scripts/flash-sd.sh}
            '';
          };
      };

      nixosConfigurations = {
        example = mkExample "x86_64-linux";
        example-aarch64 = mkExample "aarch64-linux";
        example-rpi3 = lib.nixosSystem {
          modules = [
            self.nixosModules.sdImage
            self.nixosModules.raspberryPi3
            ./examples/rpi3.nix
          ];
        };
      };

      packages = forAllSystems (
        system: pkgs: rec {
          example = (mkExample system).config.system.build.toplevel;
          example-iso = (self.lib.mkInstaller { target = mkExample system; }).config.system.build.isoImage;
          example-rpi3-flasher = self.lib.mkSdFlasher {
            inherit pkgs;
            target = self.nixosConfigurations.example-rpi3;
          };
          default = example-iso;
        }
      );

      checks = forAllSystems (
        system: pkgs:
        let
          installTest = import ./tests/install.nix { inherit pkgs lib self; };
        in
        {
          install-plain-ext4 = installTest {
            name = "plain-ext4";
            disk = { };
          };
          install-luks-btrfs-swap = installTest {
            name = "luks-btrfs-swap";
            disk = {
              nixFsType = "btrfs";
              swap.size = "512M";
              encryption.enable = true;
            };
          };
          install-immutable-users = installTest {
            name = "immutable-users";
            disk = { };
            mutableUsers = false;
          };
          module = import ./tests/module.nix { inherit pkgs self; };
          eval = import ./tests/eval.nix {
            inherit pkgs lib self;
            example = mkExample system;
          };
          format = pkgs.runCommand "check-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -name '*.nix' -exec nixfmt --check {} +
            touch $out
          '';
        }
      );

      formatter = forAllSystems (_: pkgs: pkgs.nixfmt-tree);
    };
}
