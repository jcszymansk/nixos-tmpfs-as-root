# seed_identity MOUNT PREFIX
#
# Writes the per-machine identity into the persistent directory of a
# freshly written target: a new machine-id, and SSH host keys (generated,
# or reused from $host_keys_source). Shared by the installer and the SD
# card flasher; must never be baked into an image, or every machine
# written from it would share one identity.
#
# MOUNT is where the target filesystem holding PREFIX is mounted, so a
# target path P is written to MOUNT/${P#PREFIX}: the installer passes
# (/mnt, "") for a whole root tree, the flasher (card mount, /nix) for the
# /nix partition alone.
#
# Uses: persist_path, host_name, openssh_enabled, host_key_specs,
# host_keys_source, log, die. Sets: host_key_fingerprints.

seed_identity() {
  local mount=$1 prefix=$2
  local persist_root="$mount${persist_path#"$prefix"}"

  install -d -m 0755 "$persist_root" "$persist_root/etc"

  systemd-id128 new >"$persist_root/etc/machine-id"
  chmod 0444 "$persist_root/etc/machine-id"
  log "machine-id: $(cat "$persist_root/etc/machine-id")"

  host_key_fingerprints=()
  if [[ $openssh_enabled != true ]]; then
    return 0
  fi

  local spec key_type key_bits key_path dest reused bits_args
  for spec in "${host_key_specs[@]}"; do
    IFS=: read -r key_type key_bits key_path <<<"$spec"
    dest="$mount${key_path#"$prefix"}"
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
      ssh-keygen -q -t "$key_type" "${bits_args[@]}" -N "" -C "root@$host_name" -f "$dest" ||
        die "generating the $key_type host key failed"
      log "generated $key_type host key"
    fi
    host_key_fingerprints+=("$(ssh-keygen -l -f "$dest.pub")") || die "cannot fingerprint $dest.pub"
  done
}
