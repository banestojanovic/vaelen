#!/bin/bash
set -euo pipefail

mode=normal
expected_installed_sha256=""
expected_record_content=""
recovery_reason=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recover-known-replacement) mode=recover; shift ;;
    --expect-installed-sha256) [[ $# -ge 2 ]] || { echo 'Missing value for --expect-installed-sha256' >&2; exit 2; }; expected_installed_sha256="$2"; shift 2 ;;
    --expect-record-content) [[ $# -ge 2 ]] || { echo 'Missing value for --expect-record-content' >&2; exit 2; }; expected_record_content="$2"; shift 2 ;;
    --reason) [[ $# -ge 2 ]] || { echo 'Missing value for --reason' >&2; exit 2; }; recovery_reason="$2"; shift 2 ;;
    *) echo "Unknown installer option: $1" >&2; exit 2 ;;
  esac
done

# Install a stable, user-owned copy of the Release CLI beside the PHP
# resolver, then point ~/.local/bin/val at that copy. This is intentionally
# separate from install-dev-cli.sh: routine builds cannot retarget this CLI.
repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
bin_dir="$HOME/Library/Application Support/Vaelen/bin"
local_bin="$HOME/.local/bin"
command_link="$local_bin/val"
installed_cli="$bin_dir/val"
owner_record="$bin_dir/.val.sha256"
app="/Applications/Vaelen.app"
core="$app/Contents/Resources/vaelend"
gui="$app/Contents/MacOS/Vaelen"
candidate="$repo_root/.build/release/val"
build_info="$repo_root/Sources/VaelenIPC/Runtime/BuildInfo.swift"
team="TFKZJV643G"
bundle_id="dev.vaelen.app"
lock_dir=""
cli_txn_recovery_active=false

. "$repo_root/Scripts/cli-install-transaction.sh"

fail() { printf 'Vaelen CLI install: %s\n' "$*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
team_of() { codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1; }

release_lock() {
  [[ -n "$lock_dir" && -d "$lock_dir" ]] || return 0
  local owner
  owner="$(cat "$lock_dir/owner" 2>/dev/null || true)"
  [[ "$owner" == "pid=$$" ]] || return 0
  rm -f "$lock_dir/owner"
  rmdir "$lock_dir" 2>/dev/null || true
}

finish() {
  local status=$?
  if [[ -n "$lock_dir" && -f "$bin_dir/.val-install-transaction" ]]; then
    if ! cli_txn_recover "$bin_dir"; then
      printf 'Vaelen CLI install: automatic rollback failed; journal/backups retained for recovery.\n' >&2
      status=1
    fi
  fi
  rm -f "$bin_dir/.val.install.$$" "$bin_dir/.val.sha256.install.$$" \
    "$bin_dir/.val.restore.$$" "$bin_dir/.val-owner.restore.$$" "$bin_dir/.val-journal.$$"
  release_lock
  exit "$status"
}

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    printf 'pid=%s\n' "$$" > "$lock_dir/owner"
    chmod 600 "$lock_dir/owner"
    sync
    return 0
  fi
  [[ -d "$lock_dir" && -f "$lock_dir/owner" ]] || fail "installer lock exists without a verifiable owner: $lock_dir"
  local owner_pid
  owner_pid="$(sed -n 's/^pid=//p' "$lock_dir/owner")"
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || fail "installer lock owner record is invalid: $lock_dir"
  if kill -0 "$owner_pid" 2>/dev/null; then fail "another Vaelen CLI installation may be active (pid $owner_pid)"; fi
  rm -f "$lock_dir/owner"
  rmdir "$lock_dir" 2>/dev/null || fail "stale installer lock could not be cleared safely: $lock_dir"
  mkdir "$lock_dir" || fail "unable to acquire CLI installer lock"
  printf 'pid=%s\n' "$$" > "$lock_dir/owner"
  chmod 600 "$lock_dir/owner"
  sync
}

[[ -f "$build_info" ]] || fail "missing product build identity: $build_info"
version=$(sed -n 's/^[[:space:]]*public static let productVersion = "\([^"]*\)".*/\1/p' "$build_info" | head -1)
identity=$(sed -n 's/^[[:space:]]*public static let buildIdentity = "\([^"]*\)".*/\1/p' "$build_info" | head -1)
[[ -n "$version" && -n "$identity" ]] || fail "could not read product version/build identity"
[[ -d "$app" && -x "$core" ]] || fail "installed Vaelen app/Core not found at $app"
[[ -x "$gui" ]] || fail "installed Vaelen GUI is missing"
codesign --verify --deep --strict "$app" >/dev/null || fail "installed app signature verification failed"
[[ "$(team_of "$app")" == "$team" ]] || fail "installed app Team ID is not $team"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] || fail "installed app bundle identifier is not $bundle_id"

mkdir -p "$bin_dir" "$local_bin"
lock_dir="$bin_dir/.val-install-lock"
acquire_lock
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Recover only our own journaled two-file transaction. Backups are kept for
# review; recovery restores the prior pair before a new candidate is considered.
cli_txn_recover "$bin_dir" || fail "could not recover a previous incomplete CLI installation"

printf 'Building Release CLI for Vaelen %s (%s)...\n' "$version" "$identity"
(cd "$repo_root" && swift build --configuration release --product val)
[[ -x "$candidate" ]] || fail "Release CLI was not produced at $candidate"
file "$candidate" | grep -q 'Mach-O' || fail "Release CLI is not a macOS executable"
for artifact in "$candidate" "$core" "$app/Contents/MacOS/Vaelen"; do
  strings "$artifact" | grep -Fx "$version" >/dev/null || fail "product version mismatch in $artifact"
  strings "$artifact" | grep -Fx "$identity" >/dev/null || fail "build identity mismatch in $artifact"
done

file "$candidate" | grep -q 'Mach-O' || fail "Release CLI is not a macOS executable"
[[ "$(uname -m)" == arm64 ]] || fail "candidate architecture does not match this supported installation path"

# Accept an existing stable install only when our checksum record proves that
# the installed file is the copy managed here. Modified or unmarked files are
# never silently replaced.
installed_cli_exists=false
owner_exists=false
recorded=""
actual=""
if [[ -e "$installed_cli" || -L "$installed_cli" ]]; then
  [[ -f "$installed_cli" && ! -L "$installed_cli" && -x "$installed_cli" ]] || fail "refusing to replace non-regular installed CLI: $installed_cli"
  installed_cli_exists=true
fi
if [[ -e "$owner_record" || -L "$owner_record" ]]; then
  [[ -f "$owner_record" && ! -L "$owner_record" ]] || fail "refusing to replace non-regular ownership record: $owner_record"
  owner_exists=true
  recorded="$(tr -d '[:space:]' < "$owner_record")"
  [[ "$recorded" =~ ^[0-9a-f]{64}$ ]] || fail "ownership record is malformed; existing files left untouched"
fi
if [[ "$installed_cli_exists" == true && "$owner_exists" != true ]]; then
  fail "refusing to replace unowned CLI at $installed_cli (missing $owner_record)"
fi
if [[ "$installed_cli_exists" != true && "$owner_exists" == true ]]; then
  fail "ownership record exists but installed CLI is missing; existing record left untouched"
fi

candidate_hash="$(sha256 "$candidate")"
if [[ "$installed_cli_exists" == true ]]; then
  actual="$(sha256 "$installed_cli")"
  if [[ "$recorded" != "$actual" ]]; then
    [[ "$mode" == recover ]] || fail "installed CLI checksum differs from ownership record; existing file left untouched"
    [[ "$expected_installed_sha256" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected_installed_sha256" ]] || fail "recovery refused: installed binary does not match the explicitly reviewed SHA-256"
    [[ "$expected_record_content" =~ ^[0-9a-f]{64}$ && "$recorded" == "$expected_record_content" ]] || fail "recovery refused: ownership record does not match the explicitly reviewed content"
    [[ -n "$recovery_reason" ]] || fail "recovery requires a recorded provenance reason"
    strings "$installed_cli" | grep -Fx "$version" >/dev/null || fail "recovery refused: existing executable is not the installed Vaelen version"
    strings "$installed_cli" | grep -Fx "$identity" >/dev/null || fail "recovery refused: existing executable build identity does not match the installed app"
    [[ "$(readlink "$command_link" 2>/dev/null || true)" == "$installed_cli" ]] || fail "recovery refused: stable val symlink does not point to the reviewed installed binary"
    printf 'Recovering reviewed Vaelen CLI replacement: installed=%s owner-record=%s\n' "$actual" "$recorded"
  elif [[ "$mode" == recover ]]; then
    fail "recovery was requested, but the installed CLI has no ownership mismatch"
  fi
elif [[ "$mode" == recover ]]; then
  fail "recovery requires the previously reviewed installed Vaelen CLI and its ownership record"
fi

backup_link() {
  local old_target="$1" stamp backup
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup="$local_bin/val.vaelen-dev-backup-$stamp"
  local suffix=1
  while [[ -e "$backup" || -L "$backup" ]]; do
    backup="$local_bin/val.vaelen-dev-backup-$stamp-$suffix"
    suffix=$((suffix + 1))
  done
  ln -s "$old_target" "$backup"
  printf '%s\n' "$backup"
}

old_link_backup=""
if [[ -L "$command_link" ]]; then
  current_target=$(readlink "$command_link")
  if [[ "$current_target" != "$installed_cli" ]]; then
    # The one accepted legacy migration is the existing sibling-checkout
    # development link. Prove both the target shape and that checkout's
    # tracked Vaelen installer created links to its .build/debug/val.
    legacy_repo="$HOME/Code/apps/vaelen"
    expected_legacy="$legacy_repo/.build/debug/val"
    if [[ "$current_target" != "$expected_legacy" || ! -x "$current_target" || -L "$current_target" ]]; then
      fail "refusing to replace unrelated val symlink: $command_link -> $current_target"
    fi
    git -C "$legacy_repo" rev-parse --show-toplevel >/dev/null 2>&1 || fail "legacy target checkout cannot be verified"
    git -C "$legacy_repo" ls-tree -r --name-only HEAD -- Scripts/install-dev-cli.sh | grep -Fx Scripts/install-dev-cli.sh >/dev/null || fail "legacy checkout has no tracked development CLI installer"
    git -C "$legacy_repo" show HEAD:Scripts/install-dev-cli.sh | grep -Fx 'target="$repo_root/.build/debug/val"' >/dev/null || fail "legacy installer does not establish ownership of the existing link target"
    git -C "$legacy_repo" show HEAD:Scripts/install-dev-cli.sh | grep -F 'ln -s "$target" "$link"' >/dev/null || fail "legacy installer does not establish ownership of the existing link"
    file "$current_target" | grep -q 'Mach-O' || fail "legacy link target is not a Vaelen macOS CLI executable"
    old_link_backup=$(backup_link "$current_target")
    printf 'Preserved previous Vaelen development link: %s -> %s\n' "$old_link_backup" "$current_target"
  fi
elif [[ -e "$command_link" ]]; then
  fail "refusing to replace non-symlink command: $command_link"
fi

if [[ ! -f "$installed_cli" ]] || [[ "$(sha256 "$installed_cli")" != "$candidate_hash" ]]; then
  cli_txn_install "$bin_dir" "$candidate" "$candidate_hash" "${recovery_reason:-normal owned CLI update}"
fi

if [[ ! -L "$command_link" ]] || [[ "$(readlink "$command_link")" != "$installed_cli" ]]; then
  temp_link="$local_bin/.val.link.$$"
  ln -s "$installed_cli" "$temp_link"
  mv -f "$temp_link" "$command_link"
fi

[[ "$(realpath "$command_link")" == "$(realpath "$installed_cli")" ]] || fail "command link does not resolve to installed CLI"
[[ "$(sha256 "$installed_cli")" == "$(tr -d '[:space:]' < "$owner_record")" ]] || fail "installed CLI verification failed"

printf 'Installed CLI: %s\n' "$installed_cli"
printf 'Command link:  %s -> %s\n' "$command_link" "$(readlink "$command_link")"
printf 'SHA-256:       %s\n' "$candidate_hash"
printf 'Ownership record SHA-256: %s\n' "$(sha256 "$owner_record")"
printf 'PATH and shell configuration were not changed.\n'
