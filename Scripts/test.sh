#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
raw_log="$(mktemp "${TMPDIR:-/tmp}/vaelen-swift-test.XXXXXX")" || exit 1
trap 'rm -f "$raw_log"' EXIT

status=0
(cd "$ROOT" && swift test "$@") >"$raw_log" 2>&1 || status=$?
if [[ "$status" == 0 ]]; then
  echo 'swift test passed (full log discarded)'
  exit 0
fi

failure_dir="$ROOT/.audit/test-failures"
mkdir -p "$failure_dir" || { echo "swift test failed with status $status; could not create log directory: $failure_dir" >&2; exit "$status"; }
retained_log="$(mktemp "$failure_dir/swift-test.XXXXXX")" || { echo "swift test failed with status $status; could not retain full log in $failure_dir" >&2; exit "$status"; }
cat "$raw_log" > "$retained_log"
grep -E '(^|[[:space:]])(.*: )?error:|XCTAssert[A-Za-z]* failed|Assertion Failure' "$raw_log" || true
echo "swift test failed with status $status; full log: $retained_log"
exit "$status"
