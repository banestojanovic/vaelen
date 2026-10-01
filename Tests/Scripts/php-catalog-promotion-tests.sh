#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/private/var/tmp}/vaelen-catalog-promotion-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
MOCK="$TMP/mock"
mkdir -p "$MOCK/bin" "$MOCK/releases"
cat > "$MOCK/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
op=$1; shift
if [[ "$op" == api ]]; then
  [[ "$1" == --include ]] && shift
  if [[ -d "$MOCK_ROOT/releases/php-catalog" ]]; then printf 'HTTP/2 200 OK\n\n{}\n'; else printf 'HTTP/2 404 Not Found\n\n{}\n'; fi
elif [[ "$op" == release && "$1" == download ]]; then
  tag=$2; shift 2; patterns=(); dest=.
  while (($#)); do
    case "$1" in
      --pattern) patterns+=("$2"); shift 2 ;;
      --dir) dest=$2; shift 2 ;;
      *) echo "unexpected gh download arg $1" >&2; exit 2 ;;
    esac
  done
  [[ -d "$MOCK_ROOT/releases/$tag" ]] || exit 1
  mkdir -p "$dest"
  for pattern in "${patterns[@]}"; do
    [[ -f "$MOCK_ROOT/releases/$tag/$pattern" ]] || exit 1
    cp "$MOCK_ROOT/releases/$tag/$pattern" "$dest/"
    if [[ "${MOCK_CORRUPT_TAG:-}" == "$tag" && "$pattern" == *-cli-macos-arm64.tar.gz ]]; then printf corrupted >> "$dest/$pattern"; fi
  done
elif [[ "$op" == release && "$1" == view ]]; then
  [[ -d "$MOCK_ROOT/releases/$2" ]]
elif [[ "$op" == release && "$1" == upload ]]; then
  tag=$2; shift 2; files=()
  while (($#)); do
    if [[ "$1" == --* ]]; then shift; else files+=("$1"); shift; fi
  done
  mkdir -p "$MOCK_ROOT/releases/$tag"
  for file in "${files[@]}"; do cp "$file" "$MOCK_ROOT/releases/$tag/$(basename "$file")"; done
elif [[ "$op" == release && "$1" == create ]]; then
  tag=$2; shift 2
  while (($#)) && [[ "$1" == --* ]]; do
    flag=$1; shift
    [[ "$flag" == --title || "$flag" == --notes ]] && shift
  done
  mkdir -p "$MOCK_ROOT/releases/$tag"
  for file in "$@"; do cp "$file" "$MOCK_ROOT/releases/$tag/$(basename "$file")"; done
else
  echo "unexpected gh call: $op $*" >&2; exit 2
fi
GH
cat > "$MOCK/bin/curl" <<'CURL'
#!/bin/bash
set -euo pipefail
out= url=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ -n "$out" && -n "$url" ]] || exit 2
prefix=https://github.com/banestojanovic/vaelen/releases/download/
[[ "$url" == "$prefix"* ]] || { echo "unexpected URL $url" >&2; exit 2; }
relative=${url#"$prefix"}
tag=${relative%%/*}; file=${relative#*/}
[[ -f "$MOCK_ROOT/releases/$tag/$file" ]] || exit 22
cp "$MOCK_ROOT/releases/$tag/$file" "$out"
if [[ "${MOCK_CORRUPT_URL:-}" == "$url" ]]; then printf corrupted >> "$out"; fi
CURL
chmod +x "$MOCK/bin/gh" "$MOCK/bin/curl"
export MOCK_ROOT="$MOCK" PATH="$MOCK/bin:$PATH"
make_release() {
  local version=$1 tag="php-v$1" dir="$MOCK/releases/php-v$1" cli fpm
  mkdir -p "$dir"
  cli="php-$version-cli-macos-arm64.tar.gz"; fpm="php-$version-fpm-macos-arm64.tar.gz"
  printf 'cli payload %s\n' "$version" > "$dir/$cli"
  printf 'fpm payload %s\n' "$version" > "$dir/$fpm"
  jq -n --arg version "$version" --arg tag "$tag" --arg cli "$cli" --arg fpm "$fpm" \
    --arg ch "$(shasum -a 256 "$dir/$cli" | awk '{print $1}')" \
    --arg fh "$(shasum -a 256 "$dir/$fpm" | awk '{print $1}')" \
    '{schemaVersion:1,module:"php",phpVersion:$version,platform:"macos",architecture:"arm64",catalogURL:"https://github.com/banestojanovic/vaelen/releases/download/php-catalog/php-catalog.json",release:{tag:$tag,url:("https://github.com/banestojanovic/vaelen/releases/download/"+$tag)},verification:{algorithm:"sha256",authenticity:"trusted-vaelen-release-manifest"},artifacts:{cli:{file:$cli,url:("https://github.com/banestojanovic/vaelen/releases/download/"+$tag+"/"+$cli),sha256:$ch},fpm:{file:$fpm,url:("https://github.com/banestojanovic/vaelen/releases/download/"+$tag+"/"+$fpm),sha256:$fh}}}' > "$dir/vaelen-php-manifest.json"
}
make_release 8.4.26
"$ROOT/Scripts/promote-php-catalog.sh" php-v8.4.26 "$MOCK/releases/php-v8.4.26/vaelen-php-manifest.json"
jq -e '[.manifests[].phpVersion] == ["8.4.26"]' "$MOCK/releases/php-catalog/php-catalog.json" >/dev/null
make_release 8.3.33
"$ROOT/Scripts/promote-php-catalog.sh" php-v8.3.33 "$MOCK/releases/php-v8.3.33/vaelen-php-manifest.json"
jq -e '([.manifests[].phpVersion] | sort) == ["8.3.33","8.4.26"]' "$MOCK/releases/php-catalog/php-catalog.json" >/dev/null
before=$(shasum -a 256 "$MOCK/releases/php-catalog/php-catalog.json" | awk '{print $1}')
make_release 8.4.27
if MOCK_CORRUPT_TAG=php-v8.4.27 "$ROOT/Scripts/promote-php-catalog.sh" php-v8.4.27 "$MOCK/releases/php-v8.4.27/vaelen-php-manifest.json"; then
  echo "corrupt package unexpectedly promoted" >&2; exit 1
fi
after=$(shasum -a 256 "$MOCK/releases/php-catalog/php-catalog.json" | awk '{print $1}')
[[ "$before" == "$after" ]]
jq -e '([.manifests[].phpVersion] | sort) == ["8.3.33","8.4.26"]' "$MOCK/releases/php-catalog/php-catalog.json" >/dev/null
if MOCK_CORRUPT_URL=https://github.com/banestojanovic/vaelen/releases/download/php-v8.4.26/php-8.4.26-fpm-macos-arm64.tar.gz \
  "$ROOT/Scripts/promote-php-catalog.sh" php-v8.4.27 "$MOCK/releases/php-v8.4.27/vaelen-php-manifest.json"; then
  echo "invalid existing catalog release unexpectedly promoted" >&2; exit 1
fi
after_prior_failure=$(shasum -a 256 "$MOCK/releases/php-catalog/php-catalog.json" | awk '{print $1}')
[[ "$before" == "$after_prior_failure" ]]
jq -e '([.manifests[].phpVersion] | sort) == ["8.3.33","8.4.26"]' "$MOCK/releases/php-catalog/php-catalog.json" >/dev/null
echo "PHP catalog promotion tests: 2 serial merges preserved prior versions; failed new/prior package verification left catalog unchanged."
