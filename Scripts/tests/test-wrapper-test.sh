#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

run_fixture() {
  local mode="$1" expected_status="$2"
  local fixture="$TEMP/$mode"
  mkdir -p "$fixture/scripts" "$fixture/bin" "$fixture/tmp"
  cp "$ROOT/Scripts/test.sh" "$fixture/scripts/test.sh"
  if [[ "$mode" == failure ]]; then
    mkdir -p "$fixture/Scripts/tests"
    cat > "$fixture/Scripts/tests/vaelen-dev-update-schema-contract-test.sh" <<'CONTRACT'
#!/usr/bin/env bash
printf 'earlier shell contract failure\n'
exit 17
CONTRACT
    chmod +x "$fixture/Scripts/tests/vaelen-dev-update-schema-contract-test.sh"
    cat > "$fixture/Scripts/tests/service-package-build-test.py" <<'PYTHON'
print('later Python contract output')
PYTHON
  fi
  cat > "$fixture/bin/swift" <<'SWIFT'
#!/usr/bin/env bash
printf 'swift args: %s\n' "$*"
if [[ "${SWIFT_FIXTURE_MODE:-success}" == failure ]]; then
  printf 'Compile.swift:17: error: cannot convert value\n'
  printf "Test Case \"Example.testOne()\" failed (0.1 seconds).\n"
  printf 'XCTAssertEqual failed: (1) is not equal to (2)\n'
  printf 'noise that should not be printed\n'
  exit 23
fi
printf 'noise that should not be printed\n'
SWIFT
  chmod +x "$fixture/bin/swift"
  local stdout_file="$fixture/stdout"
  local actual_status=0
  SWIFT_FIXTURE_MODE="$mode" TMPDIR="$fixture/tmp" PATH="$fixture/bin:$PATH" "$fixture/scripts/test.sh" --filter FixtureTest >"$stdout_file" 2>&1 || actual_status=$?
  [[ "$actual_status" == "$expected_status" ]] || { cat "$stdout_file" >&2; echo "expected status $expected_status, got $actual_status" >&2; exit 1; }
  if [[ "$mode" == success ]]; then
    [[ "$(wc -l < "$stdout_file" | tr -d ' ')" == 1 ]] || { cat "$stdout_file" >&2; echo 'success output was not one quiet summary line' >&2; exit 1; }
    grep -q 'tests passed (full log discarded)' "$stdout_file"
    [[ -z "$(find "$fixture/tmp" -type f -print -quit)" ]]
    [[ ! -d "$fixture/.audit/test-failures" || -z "$(find "$fixture/.audit/test-failures" -type f -print -quit)" ]]
  else
    local retained
    retained="$(sed -n 's/.*full log: //p' "$stdout_file")"
    [[ -n "$retained" && -f "$retained" ]] || { cat "$stdout_file" >&2; echo 'failure summary did not identify a retained log' >&2; exit 1; }
    grep -q 'Compile.swift:17: error:' "$stdout_file"
    grep -q 'XCTAssertEqual failed' "$stdout_file"
    ! grep -q 'Test Case .* failed' "$stdout_file"
    ! grep -q 'noise that should not be printed' "$stdout_file"
    grep -q 'swift args: test --filter FixtureTest' "$retained"
    grep -q 'noise that should not be printed' "$retained"
    grep -q 'earlier shell contract failure' "$retained"
    grep -q 'later Python contract output' "$retained"
    grep -q 'status 23' "$stdout_file"
  fi
}
run_fixture success 0
run_fixture failure 23
echo 'test wrapper success and failure behavior: PASS'
