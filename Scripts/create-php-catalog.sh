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
    ((.release.url) as $releaseURL |
    .schemaVersion == 1 and .module == "php" and
    .platform == "macos" and .architecture == "arm64" and
    .verification.algorithm == "sha256" and .verification.authenticity == "trusted-vaelen-release-manifest" and
    (.phpVersion | test("^8\\.[0-9]+\\.[0-9]+$")) and
    (.release.tag == ("php-v" + .phpVersion)) and
    (.release.url == ("https://github.com/banestojanovic/vaelen/releases/download/" + .release.tag)) and
    (.artifacts.cli.file == ("php-" + .phpVersion + "-cli-macos-arm64.tar.gz")) and
    (.artifacts.fpm.file == ("php-" + .phpVersion + "-fpm-macos-arm64.tar.gz")) and
    all([.artifacts.cli, .artifacts.fpm][];
      (.file | type == "string" and length > 0) and
      (.url == ($releaseURL + "/" + .file)) and
      (.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$")))))
' "$output" >/dev/null
