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

      testedSystem = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${testedSystem};
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
      };

      nixosConfigurations.example = lib.nixosSystem {
        modules = [
          self.nixosModules.default
          ./examples/host.nix
        ];
      };

      packages.${testedSystem} = {
        example-iso = (self.lib.mkInstaller { target = self.nixosConfigurations.example; }).config.system.build.isoImage;
        default = self.packages.${testedSystem}.example-iso;
      };

      checks.${testedSystem} =
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
          eval = import ./tests/eval.nix { inherit pkgs self; };
          format = pkgs.runCommand "check-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${lib.concatStringsSep " " (map (f: "${self}/${f}") [ "flake.nix" "modules" "examples" "tests" ])}
            touch $out
          '';
        };

      formatter.${testedSystem} = pkgs.nixfmt-tree;
    };
}
