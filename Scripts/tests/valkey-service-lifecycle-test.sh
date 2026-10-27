#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
PACKAGE_OUTPUT=${VAELEN_SERVICE_PACKAGE_OUTPUT:-/private/tmp/vaelen package output fixed-prefix smoke}
PACKAGE_TEMP=$(mktemp -d /private/tmp/vaelen-valkey-package.XXXXXX)
cleanup_package_fixture() {
    status=$?
    if [ "$status" -eq 0 ]; then rm -rf "$PACKAGE_TEMP"; else echo "Valkey package fixture preserved at $PACKAGE_TEMP" >&2; fi
}
trap cleanup_package_fixture EXIT HUP INT TERM

python3 Scripts/build-service-packages.py verify --packages "$PACKAGE_OUTPUT"
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
package = next(row for row in manifest["packages"] if row["id"] == "valkey-9.1.2")
module.extract_archive(source / package["archive"], destination)
PY
PACKAGE_ROOT="$PACKAGE_TEMP/extracted/valkey-9.1.2"
swift build --product val --skip-update --disable-automatic-resolution
VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" \
VAELEN_TEST_VALKEY_PACKAGE_ROOT="$PACKAGE_ROOT" \
Scripts/test.sh --filter ValkeyServiceLifecycleEndToEndTests
