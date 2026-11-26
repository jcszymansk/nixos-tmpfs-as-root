# Writes a stateless SD card image to a card and seeds the per-card state
# that must not be in the image: machine-id, SSH host keys, Wi-Fi networks.
#
# The variables host_name, persist_path, label, wifi_enabled,
# openssh_enabled and host_key_specs are prepended by lib.mkSdFlasher.
#
#   image ──dd──▶ card ──mount NIX partition──▶ seed persist/ ──▶ umount

verbose=false

log() {
  echo "flash-sd: $*" >&2
}

die() {
  log "error: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage: flash-sd [options] IMAGE DEVICE

Writes the $host_name SD card image IMAGE (.img or .img.zst) to DEVICE,
ERASING it, then writes a fresh machine-id and SSH host keys onto the card.

Options:
  --yes                    do not ask for confirmation
  --wifi-ssid SSID         add a Wi-Fi network (repeatable); the passphrase is
                           prompted for, or read from --wifi-psk-file
  --wifi-psk-file F        passphrase for the preceding --wifi-ssid
  --ssh-host-keys DIR      reuse host keys found in DIR instead of generating
  --verbose                trace every command
  -h, --help               show this help
EOF
}

assume_yes=false
host_keys_source=""
wifi_ssids=()
wifi_psk_files=()
positional=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --yes) assume_yes=true ;;
    --wifi-ssid)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      wifi_ssids+=("$2")
      wifi_psk_files+=("")
      shift
      ;;
    --wifi-psk-file)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      [[ ${#wifi_ssids[@]} -gt 0 ]] || die "--wifi-psk-file must follow a --wifi-ssid"
      wifi_psk_files[${#wifi_ssids[@]} - 1]=$2
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
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
    *) positional+=("$1") ;;
  esac
  shift
done

if [[ $verbose == true ]]; then
  set -x
fi

[[ ${#positional[@]} -eq 2 ]] || {
  usage >&2
  die "expected IMAGE and DEVICE"
}
image=${positional[0]}
device=${positional[1]}

# ---------------------------------------------------------------- checks

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -f $image && -r $image ]] || die "cannot read image $image"
[[ -b $device ]] || die "$device is not a block device"
[[ $(lsblk -dno TYPE "$device") == disk ]] || die "$device is not a whole disk (pass /dev/sdX, not a partition)"
if lsblk -lno MOUNTPOINTS "$device" | grep -q .; then
  die "$device or one of its partitions is mounted; unmount it first"
fi
[[ -z $host_keys_source || -d $host_keys_source ]] || die "$host_keys_source is not a directory"
if [[ $wifi_enabled != true && ${#wifi_ssids[@]} -gt 0 ]]; then
  die "--wifi-ssid given, but the image does not enable stateless.sdImage.wifi"
fi
for psk_file in "${wifi_psk_files[@]}"; do
  [[ -z $psk_file || -r $psk_file ]] || die "cannot read $psk_file"
done

log "image:  $image"
log "device: $device ($(lsblk -dno SIZE,MODEL "$device" | xargs))"
if [[ $assume_yes != true ]]; then
  echo "ALL DATA ON $device WILL BE DESTROYED."
  read -r -p "Type the device path ($device) to continue: " answer
  [[ $answer == "$device" ]] || die "confirmation did not match, nothing was changed"
fi

# ------------------------------------------- Wi-Fi, before touching the card

wifi_conf=$(mktemp)
mount_dir=""
cleanup() {
  shred --remove "$wifi_conf" 2>/dev/null || rm -f "$wifi_conf"
  if [[ -n $mount_dir ]]; then
    if mountpoint -q "$mount_dir"; then
      umount "$mount_dir" || log "warning: could not unmount $mount_dir"
    fi
    rmdir "$mount_dir" || log "warning: could not remove $mount_dir"
  fi
}
trap cleanup EXIT

for i in "${!wifi_ssids[@]}"; do
  ssid=${wifi_ssids[$i]}
  if [[ -n ${wifi_psk_files[$i]} ]]; then
    psk=$(tr -d '\n' <"${wifi_psk_files[$i]}")
  else
    read -r -s -p "Passphrase for Wi-Fi network '$ssid': " psk
    echo >&2
    read -r -s -p "Repeat passphrase: " psk2
    echo >&2
    [[ $psk == "$psk2" ]] || die "passphrases do not match"
  fi
  [[ ${#psk} -ge 8 && ${#psk} -le 63 ]] || die "a WPA passphrase has 8 to 63 characters"
  # wpa_passphrase echoes the plaintext as a #psk= comment; keep only the
  # derived key.
  printf '%s\n' "$psk" | wpa_passphrase "$ssid" | grep -v '^[[:space:]]*#psk=' >>"$wifi_conf" ||
    die "wpa_passphrase failed for '$ssid'"
  log "prepared Wi-Fi network '$ssid'"
done

# --------------------------------------------------------- write the image

log "writing $image to $device"
if [[ $image == *.zst ]]; then
  zstd -dc "$image" | dd of="$device" bs=4M conv=fsync status=progress || die "writing the image failed"
else
  dd if="$image" of="$device" bs=4M conv=fsync status=progress || die "writing the image failed"
fi
blockdev --rereadpt "$device" || die "the kernel did not re-read the partition table of $device"
udevadm settle

nix_part=$(lsblk -lnpo NAME,LABEL "$device" | awk -v l="$label" '$2 == l { print $1 }')
[[ -n $nix_part ]] || die "no partition labelled $label on $device after writing; is this the right image?"
[[ $(wc -l <<<"$nix_part") -eq 1 ]] || die "more than one partition labelled $label on $device"

# ------------------------------------------------------------ seed the card

mount_dir=$(mktemp -d)
mount "$nix_part" "$mount_dir" || die "mounting $nix_part failed"
[[ -d $mount_dir/store ]] || die "$nix_part has no store/; is this the right image?"

seed_identity "$mount_dir" /nix

if [[ ${#wifi_ssids[@]} -gt 0 ]]; then
  wifi_dir="$mount_dir${persist_path#/nix}/etc/wpa_supplicant"
  install -d -m 0700 "$wifi_dir"
  install -m 0600 "$wifi_conf" "$wifi_dir/networks.conf"
  log "wrote ${#wifi_ssids[@]} Wi-Fi network(s)"
fi

sync
umount "$mount_dir" || die "unmounting $nix_part failed"
rmdir "$mount_dir"
mount_dir=""

log "done; the card can be removed."
for fingerprint in "${host_key_fingerprints[@]}"; do
  log "SSH host key: $fingerprint"
done
