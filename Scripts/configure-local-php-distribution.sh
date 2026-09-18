#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
build_root=${1:-${VAELEN_BUILD_ROOT:-$repo_root/.build/php}}
release_root="$build_root/release"
manifest="$release_root/vaelen-php-manifest.json"
config_root="$HOME/Library/Application Support/Vaelen/config"
configuration="$config_root/php-distribution.json"

test -f "$manifest"
test -d "$release_root"

trust=$(jq -r '.verification.authenticity' "$manifest")
test "$trust" = "bootstrap-local-machine"
cli_name=$(jq -r '.artifacts.cli.file' "$manifest")
fpm_name=$(jq -r '.artifacts.fpm.file' "$manifest")
cli_hash=$(jq -r '.artifacts.cli.sha256' "$manifest")
fpm_hash=$(jq -r '.artifacts.fpm.sha256' "$manifest")
test -f "$release_root/$cli_name"
test -f "$release_root/$fpm_name"
test "$(shasum -a 256 "$release_root/$cli_name" | cut -d ' ' -f 1)" = "$cli_hash"
test "$(shasum -a 256 "$release_root/$fpm_name" | cut -d ' ' -f 1)" = "$fpm_hash"

mkdir -p "$config_root"
temporary="$configuration.$$.tmp"
trap 'rm -f "$temporary"' EXIT
jq -n \
  --arg manifestPath "$manifest" \
  --arg artifactBasePath "$release_root" \
  '{manifestPath: $manifestPath, artifactBasePath: $artifactBasePath}' > "$temporary"
mv "$temporary" "$configuration"
chmod 600 "$configuration"

version=$(jq -r '.phpVersion' "$manifest")
printf 'Configured local Vaelen PHP distribution\n'
printf 'Manifest: %s\n' "$manifest"
printf 'Artifacts: %s\n' "$release_root"
printf 'Version: %s\n' "$version"
printf 'Daemon: run `swift run vaelend` without PHP environment overrides\n'
