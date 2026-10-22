#!/bin/bash
set -euo pipefail
EVIDENCE="${1:?usage: doctor-fixture.sh <evidence-directory>}"
[[ -f "$EVIDENCE/run.txt" ]] || { echo "Missing run.txt" >&2; exit 1; }
value() { awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$EVIDENCE/run.txt"; }
pid="$(value pid)"
run_root="$(value run_root)"
app="$(value app)"
bundle_id="$(value bundle_id)"
fixture="$(value fixture)"
page="$(value page)"
[[ "$bundle_id" == dev.vaelen.app && "$fixture" =~ ^[a-z0-9-]+$ && "$page" =~ ^[a-z0-9-]+$ ]] || {
  echo "Unexpected fixture identity in run.txt" >&2; exit 1;
}
actual=""
if kill -0 "$pid" 2>/dev/null; then
  actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  actual="${actual#"${actual%%[![:space:]]*}"}"
fi
[[ -n "$actual" && "$actual" == "$app/Contents/MacOS/Vaelen --settings-fixture=$fixture --settings-page=$page" ]] || {
  echo "PID $pid is not the recorded fixture executable; refusing to drive" >&2; exit 1;
}
[[ -x "$app/Contents/MacOS/Vaelen" ]] || { echo "Recorded app executable is missing" >&2; exit 1; }
[[ -d "$run_root/DerivedData/Build/Products/Debug/Vaelen.app" ]] || { echo "Derived app bundle is missing" >&2; exit 1; }
echo "Process identity OK: pid=$pid bundle=$bundle_id fixture=$fixture page=$page"
echo "Check CUA accessibility state for Settings and UI fixture · $fixture before driving."
