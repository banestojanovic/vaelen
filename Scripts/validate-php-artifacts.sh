#!/bin/bash
set -euo pipefail

artifact_root=${1:?artifact root is required}
config=${2:?build config is required}
cli="$artifact_root/php"
fpm="$artifact_root/php-fpm"

test -x "$cli"
test -x "$fpm"

for binary in "$cli" "$fpm"; do
  file_output=$(file "$binary")
  case "$file_output" in
    *"Mach-O 64-bit executable arm64"*) ;;
    *) echo "unexpected architecture: $file_output" >&2; exit 1 ;;
  esac
  dependencies=$(otool -L "$binary")
  case "$dependencies" in
    *"/opt/homebrew/"*|*"/usr/local/"*|*"Application Support/Herd"*)
      echo "unexpected external runtime dependency in $binary" >&2
      echo "$dependencies" >&2
      exit 1
      ;;
  esac
done

version=$(jq -r '.phpVersion' "$config")
actual_version=$("$cli" -r 'echo PHP_VERSION;')
test "$actual_version" = "$version"
"$cli" -v
"$fpm" -v

required_extensions=$(jq -r '.requiredExtensions[]' "$config")
loaded_extensions=$("$cli" -m | tr '[:upper:]' '[:lower:]')
while IFS= read -r extension; do
  if ! printf '%s\n' "$loaded_extensions" | grep -Fxq "$extension"; then
    echo "required extension is missing: $extension" >&2
    exit 1
  fi
done <<< "$required_extensions"

if jq -e '.optionalExtensions | index("imagick")' "$config" >/dev/null; then
  "$cli" -r 'class_exists("Imagick") or exit(1); echo "Imagick: ", Imagick::getVersion()["versionString"], PHP_EOL;'
fi

runtime_dir=$(mktemp -d)
cleanup() {
  if [[ -n "${fpm_pid:-}" ]] && kill -0 "$fpm_pid" 2>/dev/null; then
    kill -TERM "$fpm_pid" 2>/dev/null || true
    wait "$fpm_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime_dir"
}
trap cleanup EXIT

cat > "$runtime_dir/fpm.conf" <<EOF
[global]
pid = $runtime_dir/php-fpm.pid
error_log = $runtime_dir/php-fpm.log
daemonize = no

[vaelen-validation]
listen = $runtime_dir/php-fpm.sock
listen.mode = 0600
pm = static
pm.max_children = 1
clear_env = no
EOF

"$fpm" -y "$runtime_dir/fpm.conf" -F >/dev/null 2>&1 &
fpm_pid=$!
for _ in $(jot 80); do
  [[ -S "$runtime_dir/php-fpm.sock" ]] && break
  sleep 0.25
done
test -S "$runtime_dir/php-fpm.sock"
kill -TERM "$fpm_pid"
wait "$fpm_pid" 2>/dev/null || true
test ! -e "$runtime_dir/php-fpm.sock"
