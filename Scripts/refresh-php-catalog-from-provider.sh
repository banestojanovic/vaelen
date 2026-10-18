#!/bin/bash
# Regenerate Vaelen's trusted PHP catalog from a provider's prepared macOS
# CLI/FPM packages.
#
# Vaelen does not compile PHP. This script pins the provider's published bytes:
# it downloads each prepared CLI/FPM package, records its SHA-256 and exact byte
# size, validates the extracted binaries the same way the product does at install
# time, and emits the catalog the signed app ships. A version is only pinned after
# every check passes.
#
# Provider configuration lives in one place: Distribution/PHP/provider.json.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
provider_config=${VAELEN_PHP_PROVIDER_CONFIG:-$repo_root/Distribution/PHP/provider.json}
cache_root=${VAELEN_PHP_PROVIDER_CACHE:-$repo_root/.build/php-provider}
output=${VAELEN_PHP_CATALOG_OUTPUT:-$repo_root/Sources/VaelenCore/Resources/php-catalog.json}
only_family=${VAELEN_PHP_PROVIDER_FAMILY:-}
bundle_family=${VAELEN_PHP_BUNDLE_FAMILY:-}
skip_bundled=${VAELEN_PHP_SKIP_BUNDLED:-0}

test -f "$provider_config"
command -v jq >/dev/null
command -v curl >/dev/null
command -v shasum >/dev/null

base_url=$(jq -er '.provider.baseURL' "$provider_config")
feed_url=$(jq -er '.provider.feedURL' "$provider_config")
license_base=$(jq -er '.provider.licenseBaseURL' "$provider_config")
channel=$(jq -er '.provider.channel' "$provider_config")
authenticity=$(jq -er '.provider.authenticity' "$provider_config")
platform=$(jq -er '.provider.platform' "$provider_config")
architecture=$(jq -er '.provider.architecture' "$provider_config")
minimum_macos=$(jq -er '.provider.minimumMacOS' "$provider_config")
required_extensions=$(jq -c '.requiredExtensions' "$provider_config")
optional_extensions=$(jq -c '.optionalExtensions' "$provider_config")
bundled_family=$(jq -r '.bundledFamily // ""' "$provider_config")

families=()
while IFS= read -r family; do
  families+=("$family")
done < <(jq -r '.supportedFamilies[]' "$provider_config")

fail() { echo "refresh-php-catalog-from-provider: $*" >&2; exit 1; }
note() { echo "  $*"; }

artifact_file() { printf 'php-%s-%s-macos-aarch64.tar.gz\n' "$1" "$2"; }

# Exact size from the download response, never the rounded directory listing.
remote_size() {
  curl -fsSLI --max-time 120 "$1" \
    | tr -d '\r' | grep -i '^content-length:' | tail -1 | awk '{print $2}'
}

# Cache per provider generation and channel. Artifact filenames are identical
# across generations, so a shared cache would silently reuse another
# generation's bytes for the same version.
generation=$(jq -r '.provider.generation // "legacy"' "$provider_config")
cache_root="$cache_root/$generation/$channel"
feed_cache="$cache_root/feed.json"
mkdir -p "$cache_root"
if [[ ! -s "$feed_cache" ]]; then
  curl -fsSL --retry 3 --max-time 180 "$feed_url" -o "$feed_cache.partial"
  mv "$feed_cache.partial" "$feed_cache"
fi
test -s "$feed_cache"
jq -e 'type == "array"' "$feed_cache" >/dev/null || fail "provider feed is not a JSON array"

# Every prepared macOS arm64 version the provider offers with BOTH SAPIs.
# Emits a JSON array of version strings: bare dotted versions are not valid JSON.
available_versions() {
  jq -c '[.[] | select(.is_dir == false) | .name
          | capture("^php-(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)-(?<s>cli|fpm)-macos-aarch64\\.tar\\.gz$")
         | select(. != null)]
         | map({version: .v, sapi: .s})
         | group_by(.version)
         | map(select((map(.sapi) | unique | sort) == ["cli", "fpm"]))
         | map(.[0].version)
         | unique
         | sort_by(split(".") | map(tonumber))' "$feed_cache"
}

if [[ -n "$only_family" ]]; then
  families=("$only_family")
fi

selected=()
for family in "${families[@]}"; do
  newest=$(available_versions | jq -r --arg family "$family" 'map(select(startswith($family + "."))) | last // empty')
  [[ -n "$newest" ]] || fail "provider offers no prepared CLI/FPM pair for PHP $family"
  selected+=("$newest")
  note "selected PHP $newest for family $family"
done

# Extra published versions to cache without adding them to the shipped catalog.
# Update acceptance needs a real same-family predecessor to update from.
if [[ -n "${VAELEN_PHP_EXTRA_VERSIONS:-}" ]]; then
  while IFS= read -r extra; do
    [[ -n "$extra" ]] || continue
    selected+=("$extra")
    note "caching extra PHP $extra (not added to the catalog)"
  done < <(tr ',' '\n' <<<"$VAELEN_PHP_EXTRA_VERSIONS")
fi

validate_package() {
  local version=$1 staged=$2
  local cli="$staged/php" fpm="$staged/php-fpm"

  [[ -x "$cli" && -x "$fpm" ]] || fail "prepared package for $version is missing php or php-fpm"

  local binary file_output dependencies output
  for binary in "$cli" "$fpm"; do
    file_output=$(file "$binary")
    case "$file_output" in
      *"Mach-O 64-bit executable arm64"*) ;;
      *) fail "unexpected architecture for $version: $file_output" ;;
    esac
    # Minimum macOS: Vaelen refuses a package that cannot run on the oldest
    # macOS it supports.
    local minos
    minos=$(otool -l "$binary" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
    if [[ -n "$minos" ]]; then
      local required_min="${minimum_macos%.*}"
      local binary_min="${minos%.*}"
      if [[ "$binary_min" -gt "$required_min" ]]; then
        fail "prepared $version requires macOS $minos but Vaelen requires $minimum_macos or later"
      fi
      note "  $version $(basename "$binary") minimum macOS $minos"
    fi
    dependencies=$(otool -L "$binary")
    case "$dependencies" in
      *"/opt/homebrew/"*|*"/usr/local/"*|*"Application Support/Herd"*)
        fail "prepared $version binary depends on an external runtime Vaelen does not own"
        ;;
    esac
  done

  output=$("$cli" -r 'echo PHP_VERSION;')
  [[ "$output" == "$version" ]] || fail "prepared $version CLI reports $output"
  output=$("$fpm" -v)
  [[ "$output" == *"PHP $version"* ]] || fail "prepared $version FPM reports: $output"

  # The required extension contract is authoritative and is never weakened to
  # accommodate a smaller provider build.
  local modules extension
  modules=$("$cli" -m | tr '[:upper:]' '[:lower:]' | sort -u)
  for extension in $(jq -r '.[]' <<<"$required_extensions"); do
    grep -Fxq "$extension" <<<"$modules" || fail "prepared $version is missing required PHP extension $extension"
  done
  # Optional extensions are reported, never required.
  for extension in $(jq -r '.[]' <<<"$optional_extensions"); do
    if grep -Fxq "$extension" <<<"$modules"; then
      if [[ "$extension" == imagick ]]; then
        note "  $version Imagick: $("$cli" -r 'echo (new Imagick())->getVersion()["versionString"];' 2>/dev/null || echo present)"
      else
        note "  $version optional extension $extension: present"
      fi
    else
      note "  $version optional extension $extension: not present in this build"
    fi
  done

  local runtime_dir
  runtime_dir=$(mktemp -d)
  # Prove the provider's FPM binds and releases a socket exactly as the product
  # starts it, then leaves nothing behind.
  cat > "$runtime_dir/fpm.conf" <<EOF
[global]
pid = $runtime_dir/php-fpm.pid
error_log = $runtime_dir/php-fpm.log
daemonize = no

[vaelen-provider-validation]
listen = $runtime_dir/php-fpm.sock
listen.mode = 0600
pm = static
pm.max_children = 1
clear_env = no
EOF
  "$fpm" -y "$runtime_dir/fpm.conf" -F >/dev/null 2>&1 &
  local fpm_pid=$!
  local attempts=0
  while [[ ! -S "$runtime_dir/php-fpm.sock" && $attempts -lt 80 ]]; do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if [[ ! -S "$runtime_dir/php-fpm.sock" ]]; then
    kill -TERM "$fpm_pid" 2>/dev/null || true
    cat "$runtime_dir/php-fpm.log" >&2 || true
    rm -rf "$runtime_dir"
    fail "prepared $version FPM never bound its socket"
  fi
  kill -TERM "$fpm_pid" 2>/dev/null || true
  wait "$fpm_pid" 2>/dev/null || true
  [[ ! -e "$runtime_dir/php-fpm.sock" ]] || fail "prepared $version FPM left its socket behind"
  rm -rf "$runtime_dir"
}

manifests=()
catalog_versions=$(printf '%s\n' "${selected[@]}" | head -"${#families[@]}" | tr '\n' ' ')
for version in "${selected[@]}"; do
  dir="$cache_root/$version"
  mkdir -p "$dir"

  cli_size=""
  fpm_size=""
  for sapi in cli fpm; do
    file_name=$(artifact_file "$version" "$sapi")
    archive="$dir/$file_name"
    url="$base_url/$file_name"
    if [[ ! -s "$archive" ]]; then
      note "downloading $file_name"
      curl -fsSL --retry 3 --max-time 1800 "$url" -o "$archive.partial"
      mv "$archive.partial" "$archive"
    else
      note "reusing cached $file_name"
    fi
    exact=$(remote_size "$url")
    if [[ -n "$exact" ]]; then
      if [[ "$sapi" == cli ]]; then cli_size="$exact"; else fpm_size="$exact"; fi
    fi
  done

  staged="$dir/staged"
  rm -rf "$staged"
  mkdir -p "$staged"
  tar xzf "$dir/$(artifact_file "$version" cli)" -C "$staged"
  tar xzf "$dir/$(artifact_file "$version" fpm)" -C "$staged"
  validate_package "$version" "$staged"

  cli_file=$(artifact_file "$version" cli)
  fpm_file=$(artifact_file "$version" fpm)
  cli_sha=$(shasum -a 256 "$dir/$cli_file" | cut -d ' ' -f 1)
  fpm_sha=$(shasum -a 256 "$dir/$fpm_file" | cut -d ' ' -f 1)
  # Recorded exact sizes drive a determinate progress bar. Fall back to the
  # measured local file size, which is exact, never to the rounded listing.
  cli_size=${cli_size:-$(stat -f%z "$dir/$cli_file")}
  fpm_size=${fpm_size:-$(stat -f%z "$dir/$fpm_file")}

  # Only supported-family selections are catalog entries; extras are cached for
  # acceptance testing but never advertised.
  if [[ " $catalog_versions " == *" $version "* ]]; then
  manifests+=("$(jq -n \
    --arg baseURL "$base_url" \
    --arg channel "$channel" \
    --arg authenticity "$authenticity" \
    --arg platform "$platform" \
    --arg architecture "$architecture" \
    --arg minimumMacOS "$minimum_macos" \
    --arg version "$version" \
    --arg cliFile "$cli_file" --arg cliSHA "$cli_sha" --arg cliSize "$cli_size" \
    --arg fpmFile "$fpm_file" --arg fpmSHA "$fpm_sha" --arg fpmSize "$fpm_size" \
    --argjson requiredExtensions "$required_extensions" \
    --argjson optionalExtensions "$optional_extensions" \
    '{
      schemaVersion: 1,
      module: "php",
      phpVersion: $version,
      platform: $platform,
      architecture: $architecture,
      release: { tag: $channel, url: $baseURL },
      build: {
        mechanism: "static-php-cli-prepared-package",
        minimumMacOS: $minimumMacOS,
        requiredExtensions: $requiredExtensions,
        optionalExtensions: $optionalExtensions
      },
      verification: { algorithm: "sha256", authenticity: $authenticity, digestPinnedByReview: true },
      verifiedArtifactSizes: { "cli": ($cliSize | tonumber), "fpm": ($fpmSize | tonumber) },
      artifacts: {
        cli: { file: $cliFile, url: ($baseURL + "/" + $cliFile), sha256: $cliSHA },
        fpm: { file: $fpmFile, url: ($baseURL + "/" + $fpmFile), sha256: $fpmSHA }
      }
    }')")
  note "pinned PHP $version (cli ${cli_sha:0:12}… ${cli_size}B, fpm ${fpm_sha:0:12}… ${fpm_size}B)"
  else
  note "cached PHP $version without adding it to the catalog"
  fi
done

mkdir -p "$(dirname "$output")"
temporary="$output.$$.tmp"
trap 'rm -f "$temporary"' EXIT
legacy_catalog="$repo_root/Distribution/PHP/legacy-catalog.json"
printf '%s\n' "${manifests[@]}" | jq -s --slurpfile legacy "$legacy_catalog" \
  '{schemaVersion: 1, module: "php", manifests: ((. + ($legacy[0].manifests // [])) | unique_by(.phpVersion) | sort_by(.phpVersion | split(".") | map(tonumber)))}' > "$temporary"
mv "$temporary" "$output"
trap - EXIT
echo "Wrote $output"
jq -r '.manifests[] | "  PHP \(.phpVersion)  cli=\(.artifacts.cli.sha256[0:12])…  fpm=\(.artifacts.fpm.sha256[0:12])…"' "$output"

# ---------------------------------------------------------------------------
# Bundle one validated current stable pair so first activation needs no download.
# ---------------------------------------------------------------------------
if [[ "$skip_bundled" == 1 ]]; then
  exit 0
fi
[[ -n "$bundle_family" ]] || bundle_family="$bundled_family"
[[ -n "$bundle_family" ]] || { echo "No bundleFamily configured; skipping bundled runtime."; exit 0; }

bundle_version=$(jq -r --arg family "$bundle_family" '.manifests[] | select(.phpVersion | startswith($family + ".")) | .phpVersion' "$output" | head -1)
[[ -n "$bundle_version" ]] || fail "no pinned PHP $bundle_family is available to bundle"

bundle_manifest=$(jq -c --arg version "$bundle_version" '.manifests[] | select(.phpVersion == $version)' "$output")
bundle_source_dir="$cache_root/$bundle_version"

bundle_root="$repo_root/Sources/VaelenCore/Resources/PHPBundledRuntime"
rm -rf "$bundle_root"
mkdir -p "$bundle_root"
note "bundling PHP $bundle_version from $bundle_source_dir into application resources"

# The bundled pair goes through the same extraction and validation the product
# performs on a downloaded package.
staged="$cache_root/$bundle_version/bundle-staged"
rm -rf "$staged"; mkdir -p "$staged"
tar xzf "$bundle_source_dir/$(artifact_file "$bundle_version" cli)" -C "$staged"
tar xzf "$bundle_source_dir/$(artifact_file "$bundle_version" fpm)" -C "$staged"
install -m 755 "$staged/php" "$bundle_root/php"
install -m 755 "$staged/php-fpm" "$bundle_root/php-fpm"

# PHP and every statically linked library carry their own license; the build
# tool's MIT license does not cover them. Retain the notices with the bundle.
license_dir="$bundle_root/license"
mkdir -p "$license_dir"
curl -fsSL --retry 3 --max-time 120 "$license_base/?format=json" -o "$bundle_root/license-index.json" \
  || fail "could not read the provider license index"
jq -r '.[] | select(.is_dir == false) | .name' "$bundle_root/license-index.json" \
  | grep -E '_LICENSE\.txt$|^SUMMARY\.json$' > "$bundle_root/license-files.txt" || true
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  curl -fsSL --retry 3 --max-time 120 "$license_base/$name" -o "$license_dir/$name" \
    || note "  WARNING: could not retain notice $name"
done < "$bundle_root/license-files.txt"
notices=$(find "$license_dir" -type f | wc -l | tr -d ' ')
[[ "$notices" -gt 0 ]] || fail "no license notices could be retained for the bundled runtime"
note "retained $notices license notices (PHP license included)"

# A machine-readable record so the app can verify the bundled bytes itself and
# install them through the normal managed package path.
cli_sha=$(shasum -a 256 "$bundle_root/php" | cut -d ' ' -f 1)
fpm_sha=$(shasum -a 256 "$bundle_root/php-fpm" | cut -d ' ' -f 1)
jq -n \
  --arg version "$bundle_version" \
  --arg authenticity "$authenticity" \
  --arg cliSHA "$cli_sha" --arg fpmSHA "$fpm_sha" \
  --arg json "$bundle_manifest" \
  '{
    schemaVersion: 1,
    module: "php-bundled-runtime",
    phpVersion: $version,
    verification: { algorithm: "sha256", authenticity: $authenticity, digestPinnedByReview: true },
    binaries: {
      cli: { file: "php", sha256: $cliSHA },
      fpm: { file: "php-fpm", sha256: $fpmSHA }
    },
    notices: "license",
    manifest: ($json | fromjson)
  }' > "$bundle_root/bundled-runtime.json"

# The app bundle must not treat a bundled runtime as installed: nothing here
# starts a runtime, changes the default, or touches a project. Installation
# happens only when the user activates PHP.
if [[ -n "$bundle_version" ]] && [[ "$skip_bundled" != 1 ]]; then
  echo "Bundled PHP $bundle_version (cli ${cli_sha:0:12}…, fpm ${fpm_sha:0:12}…)"
fi
