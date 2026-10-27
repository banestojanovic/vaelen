#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
support="$HOME/Library/Application Support/Vaelen"
package="$support/packages/mailpit/1.31.1"
if [ ! -x "$package/mailpit" ] || [ ! -f "$package/.vaelen-package.json" ]; then
    printf '%s\n' "SKIP: installed Mailpit 1.31.1 package is unavailable at $package. No download was attempted."
    exit 0
fi
python3 - "$package" <<'PY'
import json, os, sys
root = os.path.realpath(sys.argv[1])
with open(os.path.join(root, ".vaelen-package.json"), "rb") as source:
    package = json.load(source)
assert package.get("version") == "1.31.1", "unexpected installed Mailpit version"
assert package.get("architecture") == "arm64", "unexpected installed Mailpit architecture"
assert os.path.realpath(package.get("packagePath", "")) == root, "package metadata path does not match package directory"
executable = os.path.join(root, "mailpit")
assert os.path.realpath(package.get("executablePath", "")) == executable, "package metadata executable path does not match package executable"
assert os.path.isfile(executable) and os.access(executable, os.X_OK), "Mailpit executable is missing or not executable"
PY
executable_sha=$(shasum -a 256 "$package/mailpit" | awk '{print $1}')
metadata_sha=$(shasum -a 256 "$package/.vaelen-package.json" | awk '{print $1}')
evidence="artifacts/verification/project-service-bindings-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$evidence"
{
    printf 'package=%s\n' "$package"
    printf 'executable_sha256=%s\n' "$executable_sha"
    printf 'metadata_sha256=%s\n' "$metadata_sha"
    printf 'val=%s\n' "$PWD/.build/debug/val"
} > "$evidence/source.txt"
swift build --product val --skip-update --disable-automatic-resolution > "$evidence/build.log" 2>&1
VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" \
VAELEN_TEST_MAILPIT_PACKAGE_ROOT="$package" \
Scripts/test.sh --filter ProjectServiceBindingsEndToEndTests > "$evidence/test.log" 2>&1 || {
    result=$?
    cat "$evidence/test.log"
    printf 'result=FAIL exit=%s evidence=%s\n' "$result" "$evidence"
    exit "$result"
}
cat "$evidence/test.log"
printf 'result=PASS evidence=%s\n' "$evidence"
