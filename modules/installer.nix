/**
  Installer ISO side: puts `stateless-install` on the live system, with the
  target system's closure and disko script baked in so the install runs
  offline.
*/
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.stateless.installer;
  target = cfg.target.config;

  /**
    Path of the userborn JSON config of the target, taken from its unit.
    The nixpkgs module keeps it in a `let`, the unit is the only way out.
  */
  userbornConfig =
    let
      words = lib.splitString " " target.systemd.services.userborn.serviceConfig.ExecStart;
      json = lib.elemAt words 1;
    in
    if lib.length words == 3 && lib.hasSuffix "-userborn.json" json then
      json
    else
      throw "stateless installer: cannot parse the userborn ExecStart of the target; the nixpkgs userborn module changed shape";

  hostKeySpecs = map (
    key: "${key.type}:${toString (key.bits or "")}:${key.path}"
  ) target.services.openssh.hostKeys;

  installer = pkgs.writeShellApplication {
    name = "stateless-install";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
      openssh
      mkpasswd
      shadow
      systemd
      nixos-install
      userborn
    ];
    text = ''
      ${lib.toShellVars {
        host_name = target.networking.hostName;
        device = target.stateless.disk.device;
        mount_root = target.disko.rootMountPoint;
        disko_script = target.system.build.diskoScript;
        toplevel = target.system.build.toplevel;
        persist_path = target.stateless.persistPath;
        tmp_path = target.stateless.tmp.path;
        encrypted = lib.boolToString target.stateless.disk.encryption.enable;
        luks_password_file = target.stateless.disk.encryption.passwordFile;
        require_efi = lib.boolToString target.boot.loader.systemd-boot.enable;
        accounts_persist = lib.boolToString target.stateless.accounts.persist;
        userborn_config = if target.stateless.accounts.persist then userbornConfig else "";
        password_users = cfg.passwordUsers;
        openssh_enabled = lib.boolToString target.services.openssh.enable;
        host_key_specs = hostKeySpecs;
      }}
      ${builtins.readFile ../scripts/stateless-install.sh}
    '';
  };
in
{
  options.stateless.installer = {
    target = lib.mkOption {
      type = lib.types.unspecified;
      description = ''
        The `nixosSystem` to install. It must enable `stateless` and
        `stateless.disk`.
      '';
    };

    passwordUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        if target.stateless.accounts.persist then
          [ "root" ]
          ++ lib.attrNames (lib.filterAttrs (_: u: u.enable && u.isNormalUser) target.users.users)
        else
          [ ];
      defaultText = lib.literalExpression ''
        [ "root" ] ++ normal users of the target, when the target persists
        mutable accounts; [ ] otherwise
      '';
      description = ''
        Users whose password the installer asks for. Only meaningful with
        `stateless.accounts.persist` on the target; immutable users get their
        passwords from the target configuration.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = target.stateless.enable && target.stateless.disk.enable;
        message = "stateless.installer.target must enable stateless and stateless.disk.";
      }
      {
        assertion = target.nixpkgs.hostPlatform.system == pkgs.stdenv.hostPlatform.system;
        message = "stateless.installer: the ISO (${pkgs.stdenv.hostPlatform.system}) and the target (${target.nixpkgs.hostPlatform.system}) must share an architecture.";
      }
      {
        assertion = cfg.passwordUsers != [ ] -> target.stateless.accounts.persist;
        message = "stateless.installer.passwordUsers needs stateless.accounts.persist on the target.";
      }
    ];

    environment.systemPackages = [ installer ];

    # Nothing here needs ZFS, and it drags in an out-of-tree kernel module.
    boot.supportedFilesystems.zfs = lib.mkForce false;

    services.getty.helpLine = ''

      To install ${target.networking.hostName} onto ${target.stateless.disk.device}
      (this ERASES that disk), run:  sudo stateless-install
    '';
  };
}
