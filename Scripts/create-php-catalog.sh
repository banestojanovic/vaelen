#!/bin/bash
set -euo pipefail

output=${1:?catalog output path is required}
shift
test "$#" -gt 0

manifests=()
for manifest in "$@"; do
  test -f "$manifest"
  manifests+=("$(cat "$manifest")")
done

printf '%s\n' "${manifests[@]}" | jq -s '{schemaVersion: 1, module: "php", manifests: .}' > "$output"
jq -e '
  .schemaVersion == 1 and .module == "php" and
  (.manifests | length > 0) and
  ((.manifests | map(.phpVersion) | unique | length) == (.manifests | length)) and
  all(.manifests[];
    .schemaVersion == 1 and .module == "php" and
    .platform == "macos" and .architecture == "arm64" and
    .verification.algorithm == "sha256" and
    (.artifacts.cli.sha256 | type == "string" and length == 64) and
    (.artifacts.fpm.sha256 | type == "string" and length == 64))
' "$output" >/dev/null
