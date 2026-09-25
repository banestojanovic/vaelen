#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/vaelen-cli-installer-guards.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
script="$repo_root/Scripts/install-cli.sh"
candidate="$repo_root/.build/release/val"

new_home() {
  local home="$1"
  mkdir -p "$home/Library/Application Support/Vaelen/bin" "$home/.local/bin"
}
install_link() {
  local home="$1"
  local installed="$home/Library/Application Support/Vaelen/bin/val"
  ln -s "$installed" "$home/.local/bin/val"
}
run_expect_refusal() {
  local home="$1" label="$2"; shift 2
  if HOME="$home" bash "$script" "$@" > "$fixture/$label.out" 2>&1; then
    echo "expected installer refusal: $label" >&2; cat "$fixture/$label.out" >&2; return 1
  fi
}

# An executable with no owner record remains protected.
home="$fixture/unowned"; new_home "$home"
installed="$home/Library/Application Support/Vaelen/bin/val"
printf '#!/bin/sh\necho user-owned\n' > "$installed"; chmod 755 "$installed"; install_link "$home"
before="$(shasum -a 256 "$installed" | awk '{print $1}')"
run_expect_refusal "$home" unowned
[[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$before" ]]
[[ ! -e "$home/Library/Application Support/Vaelen/bin/.val.sha256" ]]

# A checksum mismatch still refuses by default, without changing either file.
home="$fixture/mismatch"; new_home "$home"
installed="$home/Library/Application Support/Vaelen/bin/val"
owner="$home/Library/Application Support/Vaelen/bin/.val.sha256"
printf '#!/bin/sh\necho known-mismatch\n' > "$installed"; chmod 755 "$installed"
printf '%064d\n' 0 > "$owner"; install_link "$home"
before_cli="$(shasum -a 256 "$installed" | awk '{print $1}')"; before_owner="$(shasum -a 256 "$owner" | awk '{print $1}')"
run_expect_refusal "$home" mismatch
run_expect_refusal "$home" wrong-recovery-pin --recover-known-replacement \
  --expect-installed-sha256 "$before_cli" --expect-record-content "$(printf '%064d' 1)" \
  --reason 'negative test: wrong recorded owner value'
[[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$before_cli" ]]
[[ "$(shasum -a 256 "$owner" | awk '{print $1}')" == "$before_owner" ]]

# A matching owned copy is not enough to retarget an unrelated stable symlink.
home="$fixture/unrelated-link"; new_home "$home"
installed="$home/Library/Application Support/Vaelen/bin/val"
owner="$home/Library/Application Support/Vaelen/bin/.val.sha256"
printf '#!/bin/sh\necho owned-copy\n' > "$installed"; chmod 755 "$installed"
shasum -a 256 "$installed" | awk '{print $1}' > "$owner"
ln -s /bin/echo "$home/.local/bin/val"
before_cli="$(shasum -a 256 "$installed" | awk '{print $1}')"; before_owner="$(shasum -a 256 "$owner" | awk '{print $1}')"
run_expect_refusal "$home" unrelated-link
[[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$before_cli" ]]
[[ "$(shasum -a 256 "$owner" | awk '{print $1}')" == "$before_owner" ]]
[[ "$(readlink "$home/.local/bin/val")" == /bin/echo ]]

# Normal verified update works in a disposable home and retains both old files.
home="$fixture/success"; new_home "$home"
installed="$home/Library/Application Support/Vaelen/bin/val"
owner="$home/Library/Application Support/Vaelen/bin/.val.sha256"
printf '#!/bin/sh\necho old-owned-copy\n' > "$installed"; chmod 755 "$installed"
shasum -a 256 "$installed" | awk '{print $1}' > "$owner"; install_link "$home"
HOME="$home" bash "$script" > "$fixture/success.out" 2>&1
[[ "$(shasum -a 256 "$installed" | awk '{print $1}')" == "$(shasum -a 256 "$candidate" | awk '{print $1}')" ]]
[[ "$(tr -d '[:space:]' < "$owner")" == "$(shasum -a 256 "$installed" | awk '{print $1}')" ]]
recovery_dir="$(find "$home/Library/Application Support/Vaelen/bin" -maxdepth 1 -type d -name '.val-recovery-*' | head -n 1)"
[[ -f "$recovery_dir/installed-val.before" && -f "$recovery_dir/owner-record.before" && -f "$recovery_dir/manifest" ]]

echo 'CLI installer guard tests: PASS (unowned, mismatch, bad recovery pin, unrelated symlink, owned update/retained backups)'
