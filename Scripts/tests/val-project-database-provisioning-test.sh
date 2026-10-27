#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
SUPPORT="$HOME/Library/Application Support/Vaelen"
MYSQL_PACKAGE="$SUPPORT/packages/mysql/8.4.11"
PHP_PACKAGE="$SUPPORT/packages/php/8.4.27"
EVIDENCE=$(mktemp -d /private/tmp/vaelen-project-database-evidence.XXXXXX)
trap 'printf "Evidence retained at %s\n" "$EVIDENCE"' EXIT HUP INT TERM

python3 - "$MYSQL_PACKAGE" "$PHP_PACKAGE" > "$EVIDENCE/preflight.log" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

mysql = Path(sys.argv[1]).resolve()
php = Path(sys.argv[2]).resolve()
mysql_meta = json.loads((mysql / ".vaelen-package.json").read_text())
php_meta = json.loads((php / ".vaelen-package.json").read_text())
assert mysql_meta.get("version") == "8.4.11", "expected installed MySQL 8.4.11"
assert mysql_meta.get("architecture") == "arm64", "expected arm64 MySQL"
assert mysql_meta.get("artifactSHA256") == "b96e00493bc3499b9ffd7f08d65c5d64933af0383a8287d9873b64f94c2d6009", "MySQL artifact provenance mismatch"
assert os.path.realpath(mysql_meta.get("packagePath", "")) == str(mysql), "MySQL package metadata path mismatch"
for key, relative in (("serverPath", "bin/mysqld"), ("clientPath", "bin/mysql"), ("adminPath", "bin/mysqladmin")):
    executable = mysql / relative
    assert os.path.realpath(mysql_meta.get(key, "")) == str(executable), f"MySQL {key} metadata mismatch"
    assert executable.is_file() and os.access(executable, os.X_OK), f"installed MySQL executable missing: {executable}"
assert php_meta.get("version") == "8.4.27", "expected installed Vaelen PHP 8.4.27"
assert php_meta.get("architecture") == "arm64", "expected arm64 Vaelen PHP"
php_cli = php / "php"
assert os.path.realpath(php_meta.get("cliPath", "")) == str(php_cli), "PHP executable metadata path mismatch"
assert php_cli.is_file() and os.access(php_cli, os.X_OK), "installed PHP executable missing"
php_check = subprocess.run([str(php_cli), "-r", 'exit(extension_loaded("pdo_mysql") ? 0 : 1);'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert php_check.returncode == 0, "installed PHP pdo_mysql extension is unavailable"
for path in (mysql / "bin/mysqld", mysql / "bin/mysql", mysql / "bin/mysqladmin", php_cli):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"sha256 {path} {digest}")
print(f"mysql_package={mysql}")
print(f"php_package={php}")
PY
> "$EVIDENCE/source.txt"
python3 - "$MYSQL_PACKAGE" "$PHP_PACKAGE" >> "$EVIDENCE/source.txt" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

for root in map(Path, sys.argv[1:]):
    metadata = json.loads((root / ".vaelen-package.json").read_text())
    print(f"package={root} version={metadata['version']} architecture={metadata['architecture']}")
    for key in ("artifactSHA256", "cliSHA256"):
        if metadata.get(key): print(f"{key}={metadata[key]}")
PY
{
    printf 'commit=%s\n' "$(git rev-parse HEAD)"
    printf 'worktree=%s\n' "$PWD"
    printf 'val=%s/.build/debug/val\n' "$PWD"
} >> "$EVIDENCE/source.txt"
shasum -a 256 \
    Tests/VaelenIPCTests/ProjectDatabaseProvisioningEndToEndTests.swift \
    Scripts/tests/val-project-database-provisioning-test.sh \
    "$MYSQL_PACKAGE/.vaelen-package.json" \
    "$PHP_PACKAGE/.vaelen-package.json" >> "$EVIDENCE/source.txt"

printf '%s\n' 'swift build --product val --skip-update --disable-automatic-resolution' > "$EVIDENCE/commands.txt"
swift build --product val --skip-update --disable-automatic-resolution > "$EVIDENCE/build.log" 2>&1
shasum -a 256 .build/debug/val >> "$EVIDENCE/source.txt"
printf '%s\n' 'Scripts/test.sh --skip-update --disable-automatic-resolution --filter ProjectDatabaseProvisioningEndToEndTests' >> "$EVIDENCE/commands.txt"
if VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" \
   VAELEN_TEST_MYSQL_PACKAGE_ROOT="$MYSQL_PACKAGE" \
   VAELEN_TEST_PHP_EXECUTABLE="$PHP_PACKAGE/php" \
   VAELEN_PROJECT_DATABASE_EVIDENCE="$EVIDENCE/fixture.txt" \
   Scripts/test.sh --skip-update --disable-automatic-resolution --filter ProjectDatabaseProvisioningEndToEndTests > "$EVIDENCE/test.log" 2>&1; then
    cat "$EVIDENCE/test.log"
    test -s "$EVIDENCE/fixture.txt"
    cat "$EVIDENCE/fixture.txt"
    printf '%s\n' 'result=PASS' >> "$EVIDENCE/source.txt"
else
    result=$?
    cat "$EVIDENCE/test.log"
    printf 'result=FAIL exit=%s\n' "$result" >> "$EVIDENCE/source.txt"
    exit "$result"
fi
printf '%s\n' "Scripts/test.sh --skip-update --disable-automatic-resolution --filter ProjectDatabaseProvisioningEndToEndTests" >> "$EVIDENCE/commands.txt"
printf 'result=PASS evidence=%s\n' "$EVIDENCE"
