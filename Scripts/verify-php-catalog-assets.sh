#!/usr/bin/env bash
set -euo pipefail

catalog=${1:?catalog JSON path is required}
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/private/var/tmp}/vaelen-php-catalog-assets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

jq -e '.schemaVersion == 1 and .module == "php" and (.manifests | length > 0)' "$catalog" >/dev/null
mkdir "$tmp/manifests"
jq -c '.manifests[]' "$catalog" | while IFS= read -r entry; do
  version=$(jq -er '.phpVersion' <<< "$entry")
  jq . <<< "$entry" > "$tmp/manifests/vaelen-php-manifest-$version.json"
done
"$root/Scripts/create-php-catalog.sh" "$tmp/validated.json" "$tmp/manifests"/vaelen-php-manifest-*.json
cmp -s "$catalog" "$tmp/validated.json" || { echo "catalog is not in canonical generator form" >&2; exit 1; }

while IFS= read -r manifest; do
  version=$(jq -er '.phpVersion' <<< "$manifest")
  for kind in cli fpm; do
    file=$(jq -er --arg kind "$kind" '.artifacts[$kind].file' <<< "$manifest")
    url=$(jq -er --arg kind "$kind" '.artifacts[$kind].url' <<< "$manifest")
    expected=$(jq -er --arg kind "$kind" '.artifacts[$kind].sha256' <<< "$manifest")
    [[ "$url" == "https://github.com/banestojanovic/vaelen/releases/download/php-v$version/$file" ]] || { echo "invalid hosted $kind URL for PHP $version" >&2; exit 1; }
    asset="$tmp/$version-$kind.tar.gz"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$url" -o "$asset"
    actual=$(shasum -a 256 "$asset" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || { echo "hosted $kind checksum mismatch for PHP $version" >&2; exit 1; }
  done
done < <(jq -c '.manifests[]' "$catalog")
echo "Validated catalog structure and hosted assets."
