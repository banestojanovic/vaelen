#!/bin/bash
# Sourced by install-cli.sh. A journaled two-file replacement that can roll
# back after process termination, including a crash between the executable and
# ownership-record renames. Backups are retained beside the stable CLI.

cli_txn_write_journal() {
  local bin_dir="$1" stage="$2" recovery_base="$3"
  local temp="$bin_dir/.val-journal.$$"
  [[ ! -e "$temp" && ! -L "$temp" ]] || return 1
  printf 'stage=%s\nrecovery=%s\n' "$stage" "$recovery_base" > "$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$bin_dir/.val-install-transaction"
  sync
}

cli_txn_recover() {
  local bin_dir="$1" stage recovery_base recovery_dir value
  local journal="$bin_dir/.val-install-transaction"
  [[ -e "$journal" || -L "$journal" ]] || return 0
  [[ -f "$journal" && ! -L "$journal" ]] || {
    printf 'Vaelen CLI install: refusing non-regular transaction journal: %s\n' "$journal" >&2
    return 1
  }
  stage="$(sed -n 's/^stage=//p' "$journal")"
  recovery_base="$(sed -n 's/^recovery=//p' "$journal")"
  [[ "$recovery_base" =~ ^\.val-recovery-[0-9TZ-]+-[0-9]+$ ]] || {
    printf 'Vaelen CLI install: invalid recovery journal; left all files untouched: %s\n' "$journal" >&2
    return 1
  }
  recovery_dir="$bin_dir/$recovery_base"
  [[ -d "$recovery_dir" && ! -L "$recovery_dir" && -f "$recovery_dir/manifest" && ! -L "$recovery_dir/manifest" ]] || {
    printf 'Vaelen CLI install: recovery backup is missing; left journal for manual recovery: %s\n' "$recovery_dir" >&2
    return 1
  }
  local installed="$bin_dir/val" owner="$bin_dir/.val.sha256" had_cli had_owner old_cli_hash old_owner_hash new_cli_hash new_owner_hash new_owner_value tmp current_hash
  had_cli="$(sed -n 's/^had_cli=//p' "$recovery_dir/manifest")"
  had_owner="$(sed -n 's/^had_owner=//p' "$recovery_dir/manifest")"
  old_cli_hash="$(sed -n 's/^old_cli_sha256=//p' "$recovery_dir/manifest")"
  old_owner_hash="$(sed -n 's/^old_owner_sha256=//p' "$recovery_dir/manifest")"
  new_cli_hash="$(sed -n 's/^new_cli_sha256=//p' "$recovery_dir/manifest")"
  new_owner_hash="$(sed -n 's/^new_owner_sha256=//p' "$recovery_dir/manifest")"
  new_owner_value="$(sed -n 's/^new_owner_value=//p' "$recovery_dir/manifest")"
  if [[ "$stage" == committed ]]; then
    if [[ -f "$installed" && ! -L "$installed" && -f "$owner" && ! -L "$owner" \
          && "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$new_cli_hash" \
          && "$(tr -d '[:space:]' < "$owner")" == "$new_owner_value" ]]; then
      rm -f "$journal"
      sync
      printf 'Verified completed Vaelen CLI installation record. Backup retained: %s\n' "$recovery_dir"
      return 0
    fi
    # Treat a damaged post-commit pair as incomplete; the retained exact backup
    # remains the safe source of truth for restoring the previously owned CLI.
  fi
  for value in "$had_cli" "$had_owner"; do [[ "$value" == true || "$value" == false ]] || return 1; done
  # Only restore over the original or candidate bytes from this transaction.
  # An unrelated replacement after interruption is preserved for review.
  if [[ -e "$installed" || -L "$installed" ]]; then
    [[ -f "$installed" && ! -L "$installed" ]] || { printf 'Vaelen CLI install: refusing non-regular CLI during recovery.\n' >&2; return 1; }
    current_hash="$(shasum -a 256 "$installed" | awk '{print $1}')"
    [[ "$current_hash" == "$old_cli_hash" || "$current_hash" == "$new_cli_hash" ]] || { printf 'Vaelen CLI install: CLI changed outside transaction; left it untouched.\n' >&2; return 1; }
  elif [[ "$had_cli" == true ]]; then
    return 1
  fi
  if [[ -e "$owner" || -L "$owner" ]]; then
    [[ -f "$owner" && ! -L "$owner" ]] || { printf 'Vaelen CLI install: refusing non-regular owner record during recovery.\n' >&2; return 1; }
    current_hash="$(shasum -a 256 "$owner" | awk '{print $1}')"
    [[ "$current_hash" == "$old_owner_hash" || "$current_hash" == "$new_owner_hash" ]] || { printf 'Vaelen CLI install: owner record changed outside transaction; left it untouched.\n' >&2; return 1; }
  elif [[ "$had_owner" == true ]]; then
    return 1
  fi
  if [[ "$had_cli" == true ]]; then
    [[ -f "$recovery_dir/installed-val.before" ]] || return 1
    tmp="$bin_dir/.val.restore.$$"
    cp -p "$recovery_dir/installed-val.before" "$tmp"
    mv -f "$tmp" "$installed"
    [[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$old_cli_hash" ]] || return 1
  else
    rm -f "$installed"
  fi
  if [[ "$had_owner" == true ]]; then
    [[ -f "$recovery_dir/owner-record.before" ]] || return 1
    tmp="$bin_dir/.val-owner.restore.$$"
    cp -p "$recovery_dir/owner-record.before" "$tmp"
    mv -f "$tmp" "$owner"
    [[ "$(shasum -a 256 "$owner" | awk '{print $1}')" == "$old_owner_hash" ]] || return 1
  else
    rm -f "$owner"
  fi
  sync
  rm -f "$journal"
  sync
  printf 'Rolled back incomplete Vaelen CLI installation. Original files restored; backup retained: %s\n' "$recovery_dir"
}

cli_txn_install() {
  local bin_dir="$1" candidate="$2" candidate_hash="$3" reason="$4"
  local installed owner stamp recovery_base recovery_dir
  installed="$bin_dir/val"
  owner="$bin_dir/.val.sha256"
  local had_cli=false had_owner=false old_cli_hash=none old_owner_hash=none
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  recovery_base=".val-recovery-$stamp-$$"
  recovery_dir="$bin_dir/$recovery_base"
  mkdir -m 700 "$recovery_dir" || { printf 'Vaelen CLI install: recovery path already exists: %s\n' "$recovery_dir" >&2; return 1; }
  if [[ -f "$installed" && ! -L "$installed" ]]; then
    had_cli=true
    cp -p "$installed" "$recovery_dir/installed-val.before"
    old_cli_hash="$(shasum -a 256 "$recovery_dir/installed-val.before" | awk '{print $1}')"
  fi
  if [[ -f "$owner" && ! -L "$owner" ]]; then
    had_owner=true
    cp -p "$owner" "$recovery_dir/owner-record.before"
    old_owner_hash="$(shasum -a 256 "$recovery_dir/owner-record.before" | awk '{print $1}')"
  fi
  cp -p "$candidate" "$recovery_dir/installed-val.candidate"
  [[ "$(shasum -a 256 "$recovery_dir/installed-val.candidate" | awk '{print $1}')" == "$candidate_hash" ]] || return 1
  printf '%s\n' "$candidate_hash" > "$recovery_dir/owner-record.candidate"
  chmod 644 "$recovery_dir/owner-record.candidate"
  local new_owner_hash
  new_owner_hash="$(shasum -a 256 "$recovery_dir/owner-record.candidate" | awk '{print $1}')"
  printf 'had_cli=%s\nhad_owner=%s\nold_cli_sha256=%s\nold_owner_sha256=%s\nnew_cli_sha256=%s\nnew_owner_sha256=%s\nnew_owner_value=%s\nreason=%s\n' \
    "$had_cli" "$had_owner" "$old_cli_hash" "$old_owner_hash" "$candidate_hash" "$new_owner_hash" "$candidate_hash" "$reason" > "$recovery_dir/manifest"
  chmod 600 "$recovery_dir/manifest"
  sync

  local new_cli="$bin_dir/.val.install.$$" new_owner="$bin_dir/.val.sha256.install.$$"
  [[ ! -e "$new_cli" && ! -L "$new_cli" && ! -e "$new_owner" && ! -L "$new_owner" ]] || return 1
  cp -p "$candidate" "$new_cli"
  chmod 755 "$new_cli"
  printf '%s\n' "$candidate_hash" > "$new_owner"
  chmod 644 "$new_owner"
  [[ "$(shasum -a 256 "$new_cli" | awk '{print $1}')" == "$candidate_hash" ]] || return 1

  cli_txn_write_journal "$bin_dir" prepared "$recovery_base"
  mv -f "$new_cli" "$installed"
  sync
  cli_txn_write_journal "$bin_dir" binary-replaced "$recovery_base"
  mv -f "$new_owner" "$owner"
  sync
  cli_txn_write_journal "$bin_dir" record-replaced "$recovery_base"
  [[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$candidate_hash" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$owner")" == "$candidate_hash" ]] || return 1
  cli_txn_write_journal "$bin_dir" committed "$recovery_base"
  rm -f "$bin_dir/.val-install-transaction"
  sync
  printf 'Recovery copy and transaction manifest: %s\n' "$recovery_dir"
}
