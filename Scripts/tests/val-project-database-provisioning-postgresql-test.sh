#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
POSTGRESQL_PACKAGE="/Users/banes/.codex/worktrees/vaelen/service-data-backup-recovery-fixtures/extracted/postgresql-18.6"
PHP="/opt/homebrew/bin/php"
EVIDENCE=$(mktemp -d /private/tmp/vaelen-project-database-postgresql-evidence.XXXXXX)
trap 'printf "Evidence retained at %s\n" "$EVIDENCE"' EXIT HUP INT TERM

python3 - "$POSTGRESQL_PACKAGE" "$PHP" > "$EVIDENCE/preflight.log" <<'PY'
import hashlib
import os
import subprocess
import sys
from pathlib import Path

package = Path(sys.argv[1])
php = Path(sys.argv[2])
expected = {
    "bin/postgres": "9f160d9e1e051b5c8608a8cd6ac5e520f1422edb06bdb3c91d8e19b4282404b3",
    "bin/initdb": "16c8c434fa6d926ac7db7f2055a5e6363ac4bb03fce919fe9d4f00ed26f11a85",
    "bin/psql": "21aac5eb2c496b6aa108ba2e6f6a0d4b26ed3b8731ef990b73ea723a28596dfe",
}
assert package.resolve() == Path("/Users/banes/.codex/worktrees/vaelen/service-data-backup-recovery-fixtures/extracted/postgresql-18.6").resolve(), "unexpected PostgreSQL package root"
for relative, digest in expected.items():
    executable = package / relative
    assert executable.is_file() and os.access(executable, os.X_OK), f"missing executable: {relative}"
    actual = hashlib.sha256(executable.read_bytes()).hexdigest()
    assert actual == digest, f"PostgreSQL fixture artifact hash mismatch: {relative}"
    print(f"sha256 {relative} {actual}")
version = subprocess.run([str(package / "bin/postgres"), "--version"], check=True, capture_output=True, text=True).stdout.strip()
assert version.endswith("18.6"), f"expected PostgreSQL 18.6, got {version}"
assert php == Path("/opt/homebrew/bin/php") and php.is_file() and os.access(php, os.X_OK), "expected /opt/homebrew/bin/php"
php_check = subprocess.run([str(php), "-r", 'exit(extension_loaded("pdo_pgsql") ? 0 : 1);'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert php_check.returncode == 0, "PHP pdo_pgsql extension is unavailable"
print(f"postgresql_version={version}")
print(f"php={php}")
print("php_extension=pdo_pgsql loaded")
PY
> "$EVIDENCE/source.txt"
{
    printf 'commit=%s\n' "$(git rev-parse HEAD)"
    printf 'worktree=%s\n' "$PWD"
    printf 'postgresql_package=%s\n' "$POSTGRESQL_PACKAGE"
    printf 'php=%s\n' "$PHP"
    printf 'val=%s/.build/debug/val\n' "$PWD"
} >> "$EVIDENCE/source.txt"
cat "$EVIDENCE/preflight.log" >> "$EVIDENCE/source.txt"
shasum -a 256 \
    Tests/VaelenIPCTests/ProjectDatabaseProvisioningPostgreSQLEndToEndTests.swift \
    Scripts/tests/val-project-database-provisioning-postgresql-test.sh >> "$EVIDENCE/source.txt"

printf '%s\n' 'swift build --product val --skip-update --disable-automatic-resolution' > "$EVIDENCE/commands.txt"
swift build --product val --skip-update --disable-automatic-resolution > "$EVIDENCE/build.log" 2>&1
shasum -a 256 .build/debug/val >> "$EVIDENCE/source.txt"
printf '%s\n' 'Scripts/test.sh --skip-update --disable-automatic-resolution --filter ProjectDatabaseProvisioningPostgreSQLEndToEndTests' >> "$EVIDENCE/commands.txt"
if VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" \
   VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT="$POSTGRESQL_PACKAGE" \
   VAELEN_TEST_POSTGRESQL_PHP_EXECUTABLE="$PHP" \
   VAELEN_PROJECT_DATABASE_EVIDENCE="$EVIDENCE/fixture.txt" \
   Scripts/test.sh --skip-update --disable-automatic-resolution --filter ProjectDatabaseProvisioningPostgreSQLEndToEndTests > "$EVIDENCE/test.log" 2>&1; then
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
printf '%s\n' "result=PASS evidence=$EVIDENCE"
