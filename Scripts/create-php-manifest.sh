#!/bin/bash
set -euo pipefail

artifact_dir=${1:?artifact directory is required}
config=${2:?build config is required}
output=${3:?manifest output is required}
release_tag=${4:?release tag is required}
release_base_url=${VAELEN_RELEASE_BASE_URL:?VAELEN_RELEASE_BASE_URL is required}
manifest_trust=${VAELEN_MANIFEST_TRUST:-trusted-vaelen-release-manifest}

version=$(jq -r '.phpVersion' "$config")
architecture=$(jq -r '.architecture' "$config")
platform=$(jq -r '.platform' "$config")
static_version=$(jq -r '.staticPhpCli.version' "$config")
static_commit=$(jq -r '.staticPhpCli.commit' "$config")
cli_name=$(jq -r '.artifactNames.cli' "$config")
fpm_name=$(jq -r '.artifactNames.fpm' "$config")
config_hash=$(shasum -a 256 "$config" | cut -d ' ' -f 1)
build_extensions=$(jq '.buildExtensions' "$config")
required_extensions=$(jq '.requiredExtensions' "$config")
optional_extensions=$(jq '.optionalExtensions' "$config")

cli_hash=$(shasum -a 256 "$artifact_dir/$cli_name" | cut -d ' ' -f 1)
fpm_hash=$(shasum -a 256 "$artifact_dir/$fpm_name" | cut -d ' ' -f 1)

jq -n \
  --arg releaseTag "$release_tag" \
  --arg releaseURL "$release_base_url" \
  --arg manifestTrust "$manifest_trust" \
  --arg module "php" \
  --arg version "$version" \
  --arg architecture "$architecture" \
  --arg platform "$platform" \
  --arg staticVersion "$static_version" \
  --arg staticCommit "$static_commit" \
  --arg configHash "$config_hash" \
  --arg cliName "$cli_name" \
  --arg cliHash "$cli_hash" \
  --arg fpmName "$fpm_name" \
  --arg fpmHash "$fpm_hash" \
  --argjson buildExtensions "$build_extensions" \
  --argjson requiredExtensions "$required_extensions" \
  --argjson optionalExtensions "$optional_extensions" \
  '{
    schemaVersion: 1,
    module: $module,
    phpVersion: $version,
    platform: $platform,
    architecture: $architecture,
    release: { tag: $releaseTag, url: $releaseURL },
    build: {
      mechanism: "static-php-cli",
      version: $staticVersion,
      commit: $staticCommit,
      configurationSha256: $configHash,
      buildExtensions: $buildExtensions,
      requiredExtensions: $requiredExtensions,
      optionalExtensions: $optionalExtensions
    },
    verification: {
      algorithm: "sha256",
      authenticity: $manifestTrust
    },
    artifacts: {
      cli: { file: $cliName, url: ($releaseURL + "/" + $cliName), sha256: $cliHash },
      fpm: { file: $fpmName, url: ($releaseURL + "/" + $fpmName), sha256: $fpmHash }
    }
  }' > "$output"
