# nixos-tmpfs-as-root

Builds a NixOS installer ISO that installs a stateless system in one step:
`/` is a tmpfs rebuilt on every boot, `/nix` is on disk, and everything that
should survive a reboot lives in `/nix/persist`. This replaces the manual
migration in [lantian's impermanence article][lantian] (install a normal
NixOS, boot a live CD, move directories around by hand).

## Layout

```
GPT on stateless.disk.device
├─ ESP, vfat, /boot
├─ swap (optional; inside LVM when encrypted)
└─ /nix, ext4 or btrfs (optionally LUKS + LVM)
     ├─ store/            the Nix store
     ├─ persist/          bind-mounted or copied into place at boot
     │   ├─ var, home, root
     │   └─ etc/{machine-id, ssh/ssh_host_*, passwd, group, shadow, ...}
     └─ tmp/              bind-mounted at /tmp
tmpfs (mode=755) on /
```

`/tmp` is on disk so big temporary files don't eat RAM, and it sits outside
`persist` so it never ends up in backups. systemd's stock tmpfiles rule ages
it out after 10 days; set `boot.tmp.cleanOnBoot = true` to wipe it on boot.

## Passwords with `mutableUsers`

`passwd`, `useradd` and friends work and their changes survive reboots.
The account databases (`passwd`, `group`, `shadow`, `gshadow`, `subuid`,
`subgid`) are real files in `/etc`:

1. At boot, `stateless-restore-account-files` copies them from
   `/nix/persist/etc` into `/etc` before userborn runs, so userborn merges
   the declared users into the mutable state.
2. `stateless-persist-account-files` keeps an inotify watch on `/etc` and
   copies any changed database back to `/nix/persist/etc` (write to a temp
   file, fsync, rename), and once more when it stops at shutdown. A
   long-running watcher rather than a systemd path unit: a path unit drops
   a change that arrives while its service is still copying the previous
   one, which `useradd && chpasswd` hits easily.

They cannot be symlinks or bind mounts. shadow-utils opens them with
`O_NOFOLLOW`, so `useradd` fails on a symlink. pam_unix writes a temp file
in `/etc` and renames it over `/etc/shadow`, which silently replaces a
symlink with a tmpfs file (the change is lost at reboot) and fails with
EBUSY on a bind mount. Edit accounts through `/etc`, never directly in
`/nix/persist/etc`: the next change in `/etc` overwrites the persisted copy.

With `users.mutableUsers = false` none of this is set up and passwords come
from the configuration (for example `hashedPasswordFile` pointing into
`/nix/persist`).

## Usage

In your flake:

```nix
inputs.stateless.url = "github:jcszymansk/nixos-tmpfs-as-root";

nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
  modules = [
    inputs.stateless.nixosModules.default
    {
      stateless = {
        enable = true;
        disk = {
          device = "/dev/disk/by-id/nvme-...";
          nixFsType = "btrfs";          # default "ext4"
          encryption.enable = true;     # LUKS + LVM, passphrase asked at boot
          swap.size = "16G";            # default: no swap
        };
      };
      # plus your usual configuration, without fileSystems for /, /nix, /boot
    }
  ];
};

packages.x86_64-linux.myhost-iso =
  (inputs.stateless.lib.mkInstaller { target = self.nixosConfigurations.myhost; })
    .config.system.build.isoImage;
```

`nix build .#myhost-iso`, write it to a USB stick, boot it in UEFI mode
and run `sudo stateless-install`. The installer:

1. asks you to type the disk path to confirm the wipe,
2. asks for the LUKS passphrase and for passwords of root and every normal
   user (empty leaves an account locked),
3. partitions, formats and mounts with disko,
4. writes a machine-id, generates SSH host keys into `/nix/persist/etc/ssh`
   (or copies yours with `--ssh-host-keys DIR`, which keeps agenix secrets
   decryptable), and creates the account databases,
5. runs `nixos-install` with the system closure from the ISO. No network is
   needed.

It prints the machine-id and host key fingerprints at the end. See
`stateless-install --help` for the non-interactive flags.

## Options

| Option | Default | |
|---|---|---|
| `stateless.persistPath` | `/nix/persist` | must be on a disk filesystem |
| `stateless.persistence.defaultDirectories` | `/var /home /root` (+ NetworkManager connections) | add more via `environment.persistence."/nix/persist"` |
| `stateless.tmp.path` | `/nix/tmp` | on disk, outside `persistPath` |
| `stateless.accounts.persist` | `users.mutableUsers` | the restore/copy units above |
| `stateless.disk.enable` | `stateless.enable` | disable to bring your own `disko.devices` |
| `stateless.disk.rootSize` | kernel default (50% RAM) | tmpfs `size=` |
| `stateless.disk.espSize` | `1G` | |
| `stateless.disk.swap.hibernation` | `false` | use swap as resume device |

Assertions reject a non-tmpfs root, a tmpfs root without `mode=755` (OpenSSH
refuses logins otherwise), `persistPath` or `tmp.path` on the tmpfs,
`tmp.path` inside `persistPath` and `boot.tmp.useTmpfs`.

## Tests

```sh
nix flake check -L
```

- `eval`: assertions, defaults and generated layouts (seconds).
- `module`: the module in a test VM without the installer: `chpasswd`,
  `useradd`, a change right before shutdown, restore at boot (about two
  minutes).
- `install-plain-ext4`, `install-luks-btrfs-swap`: boot the real ISO in
  QEMU with OVMF and a blank disk, install, boot the result, then check the
  tmpfs root, `/tmp` on disk, machine-id and host key stability, console
  logins with the installer's passwords, `chpasswd`/`useradd` surviving a
  reboot, and files outside persistence disappearing. Needs KVM, takes
  several minutes each.
- `install-immutable-users`: the same with `mutableUsers = false`;
  passwords come from the configuration and nothing about accounts is
  persisted.
- `format`: `nixfmt --check`; `nix fmt` fixes it.

Checks exist for `x86_64-linux` and `aarch64-linux`. Every check passes on
x86_64 with KVM. On aarch64 (a VM without KVM, so the module test ran
emulated in about 17 minutes) `eval`, `format` and `module` pass and the
example system and installer ISO build; the install tests have not run
there yet, they need an aarch64 machine with KVM to finish in reasonable
time. `mkInstaller` builds an ISO for the target's architecture, so an
aarch64 target needs an aarch64 builder (or binfmt).

[lantian]: https://lantian.pub/en/article/modify-computer/nixos-impermanence.lantian/
