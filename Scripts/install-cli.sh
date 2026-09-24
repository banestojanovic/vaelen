#!/bin/bash
set -euo pipefail

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
candidate="$repo_root/.build/release/val"
build_info="$repo_root/Sources/VaelenIPC/Runtime/BuildInfo.swift"

fail() { printf 'Vaelen CLI install: %s\n' "$*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

[[ -f "$build_info" ]] || fail "missing product build identity: $build_info"
version=$(sed -n 's/^[[:space:]]*public static let productVersion = "\([^"]*\)".*/\1/p' "$build_info" | head -1)
identity=$(sed -n 's/^[[:space:]]*public static let buildIdentity = "\([^"]*\)".*/\1/p' "$build_info" | head -1)
[[ -n "$version" && -n "$identity" ]] || fail "could not read product version/build identity"
[[ -d "$app" && -x "$core" ]] || fail "installed Vaelen app/Core not found at $app"
codesign --verify --deep --strict "$app" >/dev/null || fail "installed app signature verification failed"

printf 'Building Release CLI for Vaelen %s (%s)...\n' "$version" "$identity"
(cd "$repo_root" && swift build --configuration release --product val)
[[ -x "$candidate" ]] || fail "Release CLI was not produced at $candidate"
file "$candidate" | grep -q 'Mach-O' || fail "Release CLI is not a macOS executable"
for artifact in "$candidate" "$core" "$app/Contents/MacOS/Vaelen"; do
  strings "$artifact" | grep -Fx "$version" >/dev/null || fail "product version mismatch in $artifact"
  strings "$artifact" | grep -Fx "$identity" >/dev/null || fail "build identity mismatch in $artifact"
done

mkdir -p "$bin_dir" "$local_bin"

# Accept an existing stable install only when our checksum record proves that
# the installed file is the copy managed here. Modified or unmarked files are
# never silently replaced.
if [[ -e "$installed_cli" || -L "$installed_cli" ]]; then
  [[ -f "$installed_cli" && ! -L "$installed_cli" && -x "$installed_cli" ]] || fail "refusing to replace non-regular installed CLI: $installed_cli"
  [[ -f "$owner_record" ]] || fail "refusing to replace unowned CLI at $installed_cli (missing $owner_record)"
  recorded=$(tr -d '[:space:]' < "$owner_record")
  actual=$(sha256 "$installed_cli")
  [[ "$recorded" == "$actual" ]] || fail "installed CLI checksum differs from ownership record; existing file left untouched"
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

candidate_hash=$(sha256 "$candidate")
if [[ ! -f "$installed_cli" ]] || [[ "$(sha256 "$installed_cli")" != "$candidate_hash" ]]; then
  temp_cli="$bin_dir/.val.install.$$"
  temp_record="$bin_dir/.val.sha256.install.$$"
  trap 'rm -f -- "$temp_cli" "$temp_record"' EXIT
  cp "$candidate" "$temp_cli"
  chmod 755 "$temp_cli"
  [[ "$(sha256 "$temp_cli")" == "$candidate_hash" ]] || fail "copied CLI checksum verification failed"
  printf '%s\n' "$candidate_hash" > "$temp_record"
  chmod 644 "$temp_record"
  mv -f "$temp_cli" "$installed_cli"
  mv -f "$temp_record" "$owner_record"
  trap - EXIT
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
printf 'PATH and shell configuration were not changed.\n'
