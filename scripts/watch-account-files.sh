# Keeps the account databases in $persist_etc in sync with /etc.
#
# One inotify watch on /etc lives for the whole run, so changes made while
# a copy is in progress queue up in the kernel instead of being dropped
# (a systemd path unit merges a trigger that arrives while its oneshot
# service is still running, which loses that change).
#
#   inotifywait --monitor /etc ──▶ fd ──▶ read name ──▶ drain burst ──▶ copy
#        established before the first copy, so nothing slips in between
#
# $account_files, $persist_etc and $copy_account_files are prepended by
# modules/stateless.nix.

log() {
  echo "stateless-watch-account-files: $*" >&2
}

is_account_file() {
  local candidate=$1 name
  for name in "${account_files[@]}"; do
    if [[ $candidate == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

coproc watcher {
  exec inotifywait --monitor --event close_write,moved_to,create,attrib,delete --format '%f' /etc 2>&1
}

# inotifywait reports "Watches established." on stderr before any event.
while IFS= read -r line <&"${watcher[0]}"; do
  if [[ $line == "Watches established." ]]; then
    break
  fi
  log "inotifywait: $line"
done
if [[ -z ${watcher_PID:-} ]] || ! kill -0 "$watcher_PID" 2>/dev/null; then
  log "inotifywait did not start"
  exit 1
fi
log "watching /etc for ${account_files[*]}"

"$copy_account_files" /etc "$persist_etc" || log "initial copy failed"

while IFS= read -r name <&"${watcher[0]}"; do
  if ! is_account_file "$name"; then
    continue
  fi
  # passwd, useradd etc. touch several files in a row; copy once per burst.
  while IFS= read -r -t 0.2 _ <&"${watcher[0]}"; do :; done
  "$copy_account_files" /etc "$persist_etc" || log "copy failed, retrying on the next change"
done

log "inotifywait exited"
exit 1
