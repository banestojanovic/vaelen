#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
config=${1:-${PHP_BUILD_CONFIG:-$repo_root/Distribution/PHP/php-8.4.23.json}}
build_root=${VAELEN_BUILD_ROOT:-$repo_root/.build/php}
static_root="$build_root/static-php-cli"
validated_root="$build_root/validated"
release_root="$build_root/release"
final_root="$build_root/final"
release_tag=${VAELEN_RELEASE_TAG:-php-v$(jq -r '.phpVersion' "$config")}
release_base_url=${VAELEN_RELEASE_BASE_URL:-https://localhost/releases/download/$release_tag}

test "$(uname -m)" = "arm64"
command -v git >/dev/null
command -v jq >/dev/null
command -v composer >/dev/null
command -v tar >/dev/null
command -v gzip >/dev/null

repository=$(jq -r '.staticPhpCli.repository' "$config")
revision=$(jq -r '.staticPhpCli.commit' "$config")
php_version=$(jq -r '.phpVersion' "$config")
extensions=$(jq -r '.buildExtensions | join(",")' "$config")
cli_name=$(jq -r '.artifactNames.cli' "$config")
fpm_name=$(jq -r '.artifactNames.fpm' "$config")

rm -rf "$build_root"
mkdir -p "$build_root"

git clone "$repository" "$static_root"
git -C "$static_root" checkout --detach "$revision"

(
  cd "$static_root"
  composer install --no-interaction --prefer-dist
  composer build:phar
  chmod +x bin/spc
  ./bin/spc doctor --auto-fix
  ./bin/spc download \
    --with-php="$php_version" \
    --for-extensions="$extensions" \
    --ignore-cache-sources=php-src \
    --prefer-pre-built
  ./bin/spc build --build-cli --build-fpm "$extensions"
)

mkdir -p "$validated_root"
cp "$static_root/buildroot/bin/php" "$validated_root/php"
cp "$static_root/buildroot/bin/php-fpm" "$validated_root/php-fpm"
chmod +x "$validated_root/php" "$validated_root/php-fpm"
"$repo_root/Scripts/validate-php-artifacts.sh" "$validated_root" "$config"

test -d "$static_root/buildroot/license"
cp -R "$static_root/buildroot/license" "$validated_root/license"

mkdir -p "$release_root"
tar -cf - -C "$validated_root" php license | gzip -n > "$release_root/$cli_name"
tar -cf - -C "$validated_root" php-fpm license | gzip -n > "$release_root/$fpm_name"

mkdir -p "$final_root"
tar -xzf "$release_root/$cli_name" -C "$final_root"
tar -xzf "$release_root/$fpm_name" -C "$final_root"
"$repo_root/Scripts/validate-php-artifacts.sh" "$final_root" "$config"

VAELEN_RELEASE_BASE_URL="$release_base_url" \
  VAELEN_MANIFEST_TRUST="${VAELEN_MANIFEST_TRUST:-bootstrap-local-machine}" \
  "$repo_root/Scripts/create-php-manifest.sh" \
  "$release_root" \
  "$config" \
  "$release_root/vaelen-php-manifest.json" \
  "$release_tag"

jq . "$release_root/vaelen-php-manifest.json"
printf 'release artifacts: %s\n' "$release_root"
