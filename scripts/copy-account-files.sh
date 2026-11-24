# Copies the account databases named in $account_files from SRC_DIR to
# DST_DIR. Each file is written to a temporary name inside DST_DIR, fsynced
# and renamed, so a crash leaves either the old or the new version, never a
# torn one. Files missing from SRC_DIR are left alone in DST_DIR: an absent
# gshadow must not delete a persisted one.
#
# Usage: stateless-copy-account-files SRC_DIR DST_DIR

log() {
  echo "stateless-copy-account-files: $*" >&2
}

if [[ $# -ne 2 ]]; then
  log "usage: stateless-copy-account-files SRC_DIR DST_DIR"
  exit 64
fi

src_dir=$1
dst_dir=$2

if [[ ! -d $src_dir ]]; then
  log "source directory $src_dir does not exist, nothing to copy"
  exit 0
fi

install -d -m 0755 "$dst_dir"

status=0
copied=()
unchanged=()
absent=()
for name in "${account_files[@]}"; do
  src="$src_dir/$name"
  dst="$dst_dir/$name"

  if [[ -L $src ]]; then
    log "refusing to copy symlink $src"
    status=1
    continue
  fi
  if [[ ! -e $src ]]; then
    absent+=("$name")
    continue
  fi
  if [[ ! -f $src || ! -s $src ]]; then
    log "refusing to copy $src: not a non-empty regular file"
    status=1
    continue
  fi
  if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
    unchanged+=("$name")
    continue
  fi

  tmp="$dst_dir/.$name.stateless-tmp"
  rm -f "$tmp"
  if cp --preserve=mode,ownership,timestamps "$src" "$tmp" && sync "$tmp" && mv -f "$tmp" "$dst"; then
    copied+=("$name")
  else
    log "failed to copy $src -> $dst"
    rm -f "$tmp"
    status=1
  fi
done

sync "$dst_dir"
log "$src_dir -> $dst_dir: copied [${copied[*]}] unchanged [${unchanged[*]}] absent [${absent[*]}]"
exit "$status"
