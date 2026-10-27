#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
export PYTHONDONTWRITEBYTECODE=1
PACKAGE_OUTPUT=${VAELEN_SERVICE_PACKAGE_OUTPUT:-/private/tmp/vaelen-service-package-acceptance-20261027/packages}
MYSQL_PACKAGE_ROOT="$HOME/Library/Application Support/Vaelen/packages/mysql/8.4.11"
PACKAGE_TEMP=$(mktemp -d /private/tmp/vaelen-core-project-recovery.XXXXXX)
EVIDENCE=$(mktemp -d /private/tmp/vaelen-core-project-recovery-evidence.XXXXXX)
cleanup() {
    status=$?
    if [ "$status" -eq 0 ]; then rm -rf "$PACKAGE_TEMP"; else echo "Package fixture preserved at $PACKAGE_TEMP" >&2; fi
    echo "Evidence retained at $EVIDENCE"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "python3 Scripts/build-service-packages.py verify --packages $PACKAGE_OUTPUT" > "$EVIDENCE/commands.txt"
python3 Scripts/build-service-packages.py verify --packages "$PACKAGE_OUTPUT" > "$EVIDENCE/package-verifier.log" 2>&1
echo 'package_verifier_exit=0' > "$EVIDENCE/package-verifier.status"
printf '%s\n' "MySQL package preflight: $MYSQL_PACKAGE_ROOT" >> "$EVIDENCE/commands.txt"
python3 - "$MYSQL_PACKAGE_ROOT" <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
metadata_path = root / ".vaelen-package.json"
assert metadata_path.is_file(), f"installed MySQL package metadata is missing: {metadata_path}"
metadata = json.loads(metadata_path.read_text())
assert metadata.get("version") == "8.4.11", "installed MySQL version must be 8.4.11"
assert metadata.get("architecture") == "arm64", "installed MySQL package must be arm64"
assert metadata.get("artifactSHA256") == "b96e00493bc3499b9ffd7f08d65c5d64933af0383a8287d9873b64f94c2d6009", "installed MySQL package artifact SHA-256 mismatch"
assert os.path.realpath(metadata.get("packagePath", "")) == str(root), "MySQL package metadata path mismatch"
for key, relative in (("serverPath", "bin/mysqld"), ("clientPath", "bin/mysql"), ("adminPath", "bin/mysqladmin")):
    expected = root / relative
    assert os.path.realpath(metadata.get(key, "")) == str(expected), f"MySQL {key} metadata path mismatch"
    assert expected.is_file() and os.access(expected, os.X_OK), f"installed MySQL executable is unavailable: {expected}"
PY
python3 - "$PACKAGE_OUTPUT" "$PACKAGE_TEMP" <<'PY'
import importlib.util
import sys
from pathlib import Path

driver = Path("Scripts/build-service-packages.py").resolve()
spec = importlib.util.spec_from_file_location("vaelen_service_packages", driver)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
source = Path(sys.argv[1])
destination = Path(sys.argv[2]) / "extracted"
manifest = module.json.loads((source / "manifest.json").read_text())
for package_id in ("postgresql-18.6", "valkey-9.1.2"):
    package = next(row for row in manifest["packages"] if row["id"] == package_id)
    extract_root = destination / package_id
    module.extract_archive(source / package["archive"], extract_root)
    package_root = extract_root / package_id
    print(f"verified_package_root={package_root}")
PY

printf '%s\n' 'VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT=<verified local package> VAELEN_TEST_VALKEY_PACKAGE_ROOT=<verified local package> VAELEN_SERVICE_RECOVERY_EVIDENCE=<evidence> Scripts/test.sh --skip-update --disable-automatic-resolution --filter CoreProjectServiceRestartRecoveryEndToEndTests' >> "$EVIDENCE/commands.txt"
if VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT="$PACKAGE_TEMP/extracted/postgresql-18.6/postgresql-18.6" \
   VAELEN_TEST_VALKEY_PACKAGE_ROOT="$PACKAGE_TEMP/extracted/valkey-9.1.2/valkey-9.1.2" \
   VAELEN_SERVICE_RECOVERY_EVIDENCE="$EVIDENCE" \
   Scripts/test.sh --skip-update --disable-automatic-resolution --filter CoreProjectServiceRestartRecoveryEndToEndTests > "$EVIDENCE/package-backed-tests.log" 2>&1; then
    cat "$EVIDENCE/package-backed-tests.log"
else
    cat "$EVIDENCE/package-backed-tests.log"
    exit 1
fi
python3 - "$EVIDENCE" <<'PY'
import re
import sys
from pathlib import Path

evidence = Path(sys.argv[1])
expected = {"mysql", "postgresql", "valkey"}
records = {path.stem: path for path in evidence.glob("*.record")}
assert set(records) == expected, f"expected recovery records for {sorted(expected)}, got {sorted(records)}"
for kind, path in records.items():
    text = path.read_text().strip()
    fields = dict(re.findall(r"([A-Za-z]+)=([^ ]+)", text))
    assert fields.get("kind") == kind, f"wrong kind record: {path}"
    assert fields.get("previousPID", "") != fields.get("recoveredPID", ""), f"PID was not replaced for {kind}"
    assert fields.get("health") == "healthy", f"recovered runtime was not healthy for {kind}"
    assert fields.get("claims") == "1" and fields.get("globalMySQLIntent") == "off", f"claims or global intent mismatch for {kind}"
    assert fields.get("cleanup") == "confirmed" and fields.get("stoppedPID") == fields.get("recoveredPID"), f"cleanup evidence missing for {kind}"
    assert int(fields["previousPID"]) > 0 and int(fields["recoveredPID"]) > 0
print("recovery_records=3 skips=0")
PY

printf '%s\n' "Scripts/test.sh --skip-update --disable-automatic-resolution --filter 'StartupRestoresProjectClaimedServicesAndSurfacesPerInstanceFailure|ProjectUnlinkWaitsForStartupServiceRecoveryToFinish|ProjectPHPMutationWaitsForStartupServiceRecovery|testMutationWaitingOnRecoveryIsRejectedAfterShutdownBegins'" >> "$EVIDENCE/commands.txt"
if Scripts/test.sh --skip-update --disable-automatic-resolution --filter 'StartupRestoresProjectClaimedServicesAndSurfacesPerInstanceFailure|ProjectUnlinkWaitsForStartupServiceRecoveryToFinish|ProjectPHPMutationWaitsForStartupServiceRecovery|testMutationWaitingOnRecoveryIsRejectedAfterShutdownBegins' > "$EVIDENCE/existing-recovery-tests.log" 2>&1; then
    cat "$EVIDENCE/existing-recovery-tests.log"
else
    cat "$EVIDENCE/existing-recovery-tests.log"
    exit 1
fi
