#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$repo_root/Scripts/cli-install-transaction.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/vaelen-cli-install-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
bin="$fixture/bin"
installed="$bin/val"
owner="$bin/.val.sha256"
candidate="$fixture/candidate-val"
printf 'preexisting executable bytes\n' > "$installed"
chmod 755 "$installed"
printf 'f%.0s' {1..64} > "$owner"
printf '\n' >> "$owner"
printf 'verified candidate executable bytes\n' > "$candidate"
chmod 755 "$candidate"
old_cli_hash="$(shasum -a 256 "$installed" | awk '{print $1}')"
old_owner_hash="$(shasum -a 256 "$owner" | awk '{print $1}')"
candidate_hash="$(shasum -a 256 "$candidate" | awk '{print $1}')"

write_incomplete_transaction() {
  local stage="$1" name="$2"
  local recovery="$bin/$name"
  mkdir -m 700 "$recovery"
  cp -p "$installed" "$recovery/installed-val.before"
  cp -p "$owner" "$recovery/owner-record.before"
  printf '%s\n' "$candidate_hash" > "$recovery/owner-record.candidate"
  local new_owner_hash
  new_owner_hash="$(shasum -a 256 "$recovery/owner-record.candidate" | awk '{print $1}')"
  printf 'had_cli=true\nhad_owner=true\nold_cli_sha256=%s\nold_owner_sha256=%s\nnew_cli_sha256=%s\nnew_owner_sha256=%s\nnew_owner_value=%s\nreason=test interrupted rename\n' \
    "$old_cli_hash" "$old_owner_hash" "$candidate_hash" "$new_owner_hash" "$candidate_hash" > "$recovery/manifest"
  cp "$candidate" "$installed"
  printf '%s\n' "$candidate_hash" > "$owner"
  printf 'stage=%s\nrecovery=%s\n' "$stage" "$name" > "$bin/.val-install-transaction"
}

index=0
for stage in prepared binary-replaced record-replaced; do
  index=$((index + 1))
  printf 'preexisting executable bytes\n' > "$installed"
  printf '%s\n' "$(printf 'f%.0s' {1..64})" > "$owner"
  write_incomplete_transaction "$stage" ".val-recovery-20260925T000000Z-$$-$index"
  cli_txn_recover "$bin"
  [[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$old_cli_hash" ]]
  [[ "$(shasum -a 256 "$owner" | awk '{print $1}')" == "$old_owner_hash" ]]
  [[ ! -e "$bin/.val-install-transaction" ]]
done

cli_txn_install "$bin" "$candidate" "$candidate_hash" "unit test transaction"
[[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$candidate_hash" ]]
[[ "$(tr -d '[:space:]' < "$owner")" == "$candidate_hash" ]]
[[ ! -e "$bin/.val-install-transaction" ]]
backup="$(find "$bin" -maxdepth 1 -type d -name '.val-recovery-*' | tail -n 1)"
[[ -f "$backup/installed-val.before" && -f "$backup/owner-record.before" && -f "$backup/manifest" ]]
backup_base="$(basename "$backup")"
cli_txn_write_journal "$bin" committed "$backup_base"
cli_txn_recover "$bin"
[[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$candidate_hash" ]]
[[ ! -e "$bin/.val-install-transaction" ]]
printf 'CLI install transaction tests: PASS (rollback stages, commit, retained binary/record backups)\n'
