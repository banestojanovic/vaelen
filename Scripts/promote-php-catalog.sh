#!/usr/bin/env bash
set -euo pipefail

# Called only from build-php.yml's serialized, queue:max release workflow.
# The versioned release must already exist; the stable catalog is untouched
# until that release and every retained catalog entry have been verified.
tag=${1:?versioned PHP tag is required}
manifest=${2:?trusted local workflow manifest is required}
repo=${GITHUB_REPOSITORY:-banestojanovic/vaelen}
root=$(cd "$(dirname "$0")/.." && pwd -P)
catalog_url="https://github.com/$repo/releases/download/php-catalog/php-catalog.json"
tmp=$(mktemp -d "${TMPDIR:-/private/var/tmp}/vaelen-php-promote.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

version=$(jq -er '.phpVersion' "$manifest")
[[ "$tag" == "php-v$version" ]] || { echo "release tag does not match manifest version" >&2; exit 1; }
jq -e '.verification.authenticity == "trusted-vaelen-release-manifest" and .verification.algorithm == "sha256"' "$manifest" >/dev/null
cli=$(jq -er '.artifacts.cli.file' "$manifest")
fpm=$(jq -er '.artifacts.fpm.file' "$manifest")
gh release download "$tag" --pattern vaelen-php-manifest.json --pattern "$cli" --pattern "$fpm" --dir "$tmp"
cmp -s "$manifest" "$tmp/vaelen-php-manifest.json" || { echo "hosted trusted manifest differs from workflow output" >&2; exit 1; }

for kind in cli fpm; do
  file=$(jq -er --arg kind "$kind" '.artifacts[$kind].file' "$manifest")
  expected=$(jq -er --arg kind "$kind" '.artifacts[$kind].sha256' "$manifest")
  actual=$(shasum -a 256 "$tmp/$file" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || { echo "hosted $kind package verification failed for PHP $version" >&2; exit 1; }
done

catalog_release_exists=false
gh api --include "repos/$repo/releases/tags/php-catalog" > "$tmp/catalog-release-response.txt" 2>/dev/null || true
http_status=$(sed -nE '1s#^HTTP/[0-9.]+ ([0-9]{3}).*$#\1#p' "$tmp/catalog-release-response.txt")
if [[ "$http_status" == 200 ]]; then
  catalog_release_exists=true
  gh release download php-catalog --pattern php-catalog.json --dir "$tmp/current"
  current="$tmp/current/php-catalog.json"
  # Refuse to replace a catalog if any retained entry is malformed or its
  # hosted CLI/FPM bytes cannot be retrieved and matched to its checksum.
  "$root/Scripts/verify-php-catalog-assets.sh" "$current"
elif [[ "$http_status" == 404 ]]; then
  current="$tmp/empty-catalog.json"
  printf '{"schemaVersion":1,"module":"php","manifests":[]}\n' > "$current"
else
  echo "could not determine stable PHP catalog release state (HTTP ${http_status:-unknown}); refusing promotion" >&2
  exit 1
fi

mkdir -p "$tmp/manifests"
jq -c '.manifests[]' "$current" | while IFS= read -r entry; do
  filename=$(jq -er '.phpVersion' <<< "$entry")
  jq . <<< "$entry" > "$tmp/manifests/vaelen-php-manifest-$filename.json"
done
existing=$(jq -r --arg version "$version" '[.manifests[].phpVersion | select(. == $version)] | length' "$current")
[[ "$existing" == 0 ]] || { echo "catalog already contains PHP $version; refusing to replace a published version" >&2; exit 1; }
cp "$manifest" "$tmp/manifests/vaelen-php-manifest-$version.json"
"$root/Scripts/create-php-catalog.sh" "$tmp/php-catalog.json" "$tmp/manifests"/vaelen-php-manifest-*.json

# Recheck the complete candidate before changing the stable alias. Prior entries
# were already checked above; this also catches merge/schema/URL mistakes.
"$root/Scripts/verify-php-catalog-assets.sh" "$tmp/php-catalog.json"

if [[ "$catalog_release_exists" == true ]]; then
  gh release upload php-catalog "$tmp/php-catalog.json" --clobber
else
  gh release create php-catalog --title "Vaelen PHP catalog" \
    --notes "Stable catalog location; entries reference immutable versioned release assets." \
    "$tmp/php-catalog.json"
fi
bash "$root/Scripts/verify-hosted-php-catalog.sh" "$catalog_url" "$tmp/php-catalog.json"
echo "PHP $version published and catalog promotion verified."
