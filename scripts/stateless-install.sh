# Installs the stateless NixOS system baked into this ISO.
#
# The variables host_name, device, mount_root, disko_script, toplevel,
# persist_path, tmp_path, encrypted, luks_password_file, require_efi,
# accounts_persist, mutable_users, userborn_config, password_users,
# openssh_enabled and host_key_specs are prepended by modules/installer.nix.
#
# Steps:
#   1. check preconditions and confirm the wipe
#   2. collect the LUKS passphrase and user passwords (before touching disk)
#   3. partition, format and mount with disko
#   4. seed the persistent directory: machine-id, SSH host keys, accounts
#   5. nixos-install the prebuilt closure, unmount

verbose=false

log() {
  echo "stateless-install: $*" >&2
}

debug() {
  if [[ $verbose == true ]]; then
    log "debug: $*"
  fi
}

die() {
  log "error: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage: stateless-install [options]

Installs $host_name onto $device, ERASING it.

Options:
  --yes                       do not ask for confirmation
  --luks-passphrase-file F    read the LUKS passphrase from F
  --passwords-file F          read "user:password" lines from F; users not
                              listed are prompted for (or left locked with
                              --yes)
  --ssh-host-keys DIR         reuse host keys found in DIR (matched by file
                              name, e.g. ssh_host_ed25519_key) instead of
                              generating them; keeps agenix secrets working
  --verbose                   trace every command
  -h, --help                  show this help
EOF
}

assume_yes=false
luks_passphrase_source=""
passwords_source=""
host_keys_source=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --yes) assume_yes=true ;;
    --luks-passphrase-file)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      luks_passphrase_source=$2
      shift
      ;;
    --passwords-file)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      passwords_source=$2
      shift
      ;;
    --ssh-host-keys)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      host_keys_source=$2
      shift
      ;;
    --verbose) verbose=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ $verbose == true ]]; then
  set -x
fi

# ---------------------------------------------------------------- 1. checks

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -b $device ]] || die "target disk $device does not exist or is not a block device"
if [[ $require_efi == true && ! -d /sys/firmware/efi ]]; then
  die "the target uses systemd-boot, but this machine was not booted in UEFI mode"
fi
[[ -z $luks_passphrase_source || -r $luks_passphrase_source ]] || die "cannot read $luks_passphrase_source"
[[ -z $passwords_source || -r $passwords_source ]] || die "cannot read $passwords_source"
[[ -z $host_keys_source || -d $host_keys_source ]] || die "$host_keys_source is not a directory"
if [[ $encrypted != true && -n $luks_passphrase_source ]]; then
  die "--luks-passphrase-file given, but the target is not encrypted"
fi
if [[ $openssh_enabled != true && -n $host_keys_source ]]; then
  die "--ssh-host-keys given, but the target does not enable OpenSSH"
fi
if mountpoint -q "$mount_root"; then
  die "$mount_root is already a mount point; unmount it first (umount -R $mount_root)"
fi

log "target system:  $toplevel"
log "host name:      $host_name"
log "disk:           $device (encrypted: $encrypted)"
log "persistent dir: $persist_path, /tmp backed by $tmp_path"
lsblk --output NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$device" >&2 || die "lsblk $device failed"

if [[ $assume_yes != true ]]; then
  echo
  echo "ALL DATA ON $device WILL BE DESTROYED."
  read -r -p "Type the disk path ($device) to continue: " answer
  [[ $answer == "$device" ]] || die "confirmation did not match, nothing was changed"
fi

# --------------------------------------------------------- 2. collect secrets

secrets_dir=$(dirname "$luks_password_file")

cleanup_secrets() {
  if [[ -e $luks_password_file ]]; then
    shred --remove "$luks_password_file" || log "warning: could not shred $luks_password_file"
  fi
}
trap cleanup_secrets EXIT

if [[ $encrypted == true ]]; then
  install -d -m 0700 "$secrets_dir"
  (
    umask 077
    if [[ -n $luks_passphrase_source ]]; then
      tr -d '\n' <"$luks_passphrase_source" >"$luks_password_file"
    else
      while true; do
        read -r -s -p "LUKS passphrase: " pass1
        echo >&2
        read -r -s -p "Repeat LUKS passphrase: " pass2
        echo >&2
        if [[ -z $pass1 ]]; then
          log "the passphrase must not be empty"
        elif [[ $pass1 != "$pass2" ]]; then
          log "passphrases do not match"
        else
          printf '%s' "$pass1" >"$luks_password_file"
          break
        fi
      done
    fi
  )
  [[ -s $luks_password_file ]] || die "the LUKS passphrase is empty"
fi

declare -A given_passwords=()
if [[ -n $passwords_source ]]; then
  while IFS=: read -r user password || [[ -n $user ]]; do
    if [[ -z $user || $user == \#* ]]; then
      continue
    fi
    given_passwords[$user]=$password
  done <"$passwords_source"
fi

for user in "${!given_passwords[@]}"; do
  found=false
  for wanted in "${password_users[@]}"; do
    if [[ $user == "$wanted" ]]; then
      found=true
    fi
  done
  [[ $found == true ]] || die "$passwords_source sets a password for $user, who is not in the installer's password users (${password_users[*]})"
done

hashed_entries=()
for user in "${password_users[@]}"; do
  if [[ -n ${given_passwords[$user]+set} ]]; then
    password=${given_passwords[$user]}
  elif [[ $assume_yes == true ]]; then
    log "no password given for $user, the account stays locked unless the configuration sets one"
    continue
  else
    while true; do
      read -r -s -p "Password for $user (empty to leave locked): " password
      echo >&2
      if [[ -z $password ]]; then
        break
      fi
      read -r -s -p "Repeat password for $user: " password2
      echo >&2
      if [[ $password == "$password2" ]]; then
        break
      fi
      log "passwords do not match"
    done
    if [[ -z $password ]]; then
      log "leaving $user locked unless the configuration sets a password"
      continue
    fi
  fi
  [[ -n $password ]] || die "empty password for $user in $passwords_source"
  hash=$(printf '%s' "$password" | mkpasswd --method=yescrypt --stdin) || die "hashing the password of $user failed"
  hashed_entries+=("$user:$hash")
  debug "hashed password for $user"
done

# ------------------------------------------------------------- 3. disko

log "partitioning, formatting and mounting $device"
"$disko_script" --yes-wipe-all-disks || die "disko failed"
cleanup_secrets

mountpoint -q "$mount_root" || die "disko did not mount $mount_root"
mountpoint -q "$mount_root/nix" || die "disko did not mount $mount_root/nix"

# --------------------------------------------------- 4. seed persistent dir

persist_root="$mount_root$persist_path"
install -d -m 0755 "$persist_root" "$persist_root/etc"
install -d -m 1777 "$mount_root$tmp_path"

systemd-id128 new >"$persist_root/etc/machine-id"
chmod 0444 "$persist_root/etc/machine-id"
log "machine-id: $(cat "$persist_root/etc/machine-id")"

host_key_fingerprints=()
if [[ $openssh_enabled == true ]]; then
  for spec in "${host_key_specs[@]}"; do
    IFS=: read -r key_type key_bits key_path <<<"$spec"
    dest="$mount_root$key_path"
    install -d -m 0755 "$(dirname "$dest")"
    reused="$host_keys_source/$(basename "$key_path")"
    if [[ -n $host_keys_source && -f $reused ]]; then
      install -m 0600 "$reused" "$dest"
      ssh-keygen -y -f "$dest" >"$dest.pub" || die "$reused is not a valid private key"
      chmod 0644 "$dest.pub"
      log "reused $key_type host key from $reused"
    else
      bits_args=()
      if [[ -n $key_bits ]]; then
        bits_args=(-b "$key_bits")
      fi
      ssh-keygen -q -t "$key_type" "${bits_args[@]}" -N "" -C "root@$host_name" -f "$dest" || die "generating the $key_type host key failed"
      log "generated $key_type host key"
    fi
    host_key_fingerprints+=("$(ssh-keygen -l -f "$dest.pub")") || die "cannot fingerprint $dest.pub"
  done
fi

# nixos-install activates the system in a chroot that needs users and groups
# to chown with; with userborn nothing creates them there. When accounts
# persist, generate them in persistence and copy them in, as
# stateless-restore-account-files does at boot.
if [[ -n $userborn_config ]]; then
  if [[ $accounts_persist == true ]]; then
    accounts_dir="$persist_root/etc"
  else
    accounts_dir="$mount_root/etc"
  fi
  log "creating account databases in ${accounts_dir#"$mount_root"}"
  install -d -m 0755 "$accounts_dir"
  userborn_env=(USERBORN_MUTABLE_USERS="$mutable_users")
  if [[ $mutable_users == true ]]; then
    # A fresh disk has no previous config; userborn falls back to the
    # current one when the file is missing, which disables nothing.
    userborn_env+=(USERBORN_PREVIOUS_CONFIG="$secrets_dir/no-previous-userborn.json")
  fi
  env "${userborn_env[@]}" userborn "$userborn_config" "$accounts_dir" || die "userborn failed"

  if [[ ${#hashed_entries[@]} -gt 0 ]]; then
    printf '%s\n' "${hashed_entries[@]}" | chpasswd --encrypted --prefix "$(dirname "$accounts_dir")" || die "setting passwords failed"
    log "set passwords for: $(printf '%s ' "${hashed_entries[@]%%:*}")"
  fi

  if [[ $accounts_persist == true ]]; then
    install -d -m 0755 "$mount_root/etc"
    for name in passwd group shadow; do
      cp --preserve=mode,ownership,timestamps "$accounts_dir/$name" "$mount_root/etc/$name" ||
        die "copying $name into $mount_root/etc failed"
    done
  fi
fi

# --------------------------------------------------------- 5. nixos-install

log "installing $toplevel"
# Everything is on the ISO; without this, Nix probes the binary cache and
# stalls on machines with no network.
nixos-install --root "$mount_root" --system "$toplevel" --no-root-passwd --no-channel-copy \
  --option substituters "" || die "nixos-install failed"

sync
umount --recursive "$mount_root" || die "unmounting $mount_root failed"
swapoff --all || log "warning: swapoff failed"

log "done. Installed $host_name onto $device."
for fingerprint in "${host_key_fingerprints[@]}"; do
  log "SSH host key: $fingerprint"
done
