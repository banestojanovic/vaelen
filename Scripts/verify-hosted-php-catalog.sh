#!/bin/bash
set -euo pipefail

catalog_url=${1:?stable HTTPS catalog URL is required}
expected_catalog=${2:?locally generated catalog is required}
[[ "$catalog_url" == https://* ]] || { echo "catalog URL must use HTTPS" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/private/var/tmp}/vaelen-catalog-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT

curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$catalog_url" -o "$work/php-catalog.json"
cmp -s "$expected_catalog" "$work/php-catalog.json" || { echo "hosted catalog differs from the generated catalog" >&2; exit 1; }
jq -e '.schemaVersion == 1 and .module == "php" and (.manifests | length > 0)' "$work/php-catalog.json" >/dev/null

index=0
while IFS= read -r manifest; do
  version=$(jq -r '.phpVersion' <<< "$manifest")
  tag=$(jq -r '.release.tag' <<< "$manifest")
  release_url=$(jq -r '.release.url' <<< "$manifest")
  [[ "$tag" == "php-v$version" && "$release_url" == "https://github.com/banestojanovic/vaelen/releases/download/$tag" ]] || { echo "invalid immutable release identity for PHP $version" >&2; exit 1; }
  for kind in cli fpm; do
    file=$(jq -r --arg kind "$kind" '.artifacts[$kind].file' <<< "$manifest")
    url=$(jq -r --arg kind "$kind" '.artifacts[$kind].url' <<< "$manifest")
    expected=$(jq -r --arg kind "$kind" '.artifacts[$kind].sha256' <<< "$manifest")
    [[ "$file" == "php-$version-$kind-macos-arm64.tar.gz" && "$url" == "$release_url/$file" && "$expected" =~ ^[[:xdigit:]]{64}$ ]] || { echo "invalid $kind asset metadata for PHP $version" >&2; exit 1; }
    destination="$work/$index-$kind.tar.gz"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$url" -o "$destination"
    actual=$(shasum -a 256 "$destination" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || { echo "hosted $kind checksum mismatch for PHP $version" >&2; exit 1; }
  done
  index=$((index + 1))
done < <(jq -c '.manifests[]' "$work/php-catalog.json")

echo "Hosted PHP catalog and $index CLI/FPM release pairs: PASS"
