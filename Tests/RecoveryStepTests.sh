#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/vaelen-dev"

fail_seven() { return 7; }
if output="$(recovery_step 'deliberate test step' fail_seven 2>&1)"; then
  echo 'recovery_step unexpectedly succeeded' >&2
  exit 1
else
  result=$?
fi

[[ "$result" -ne 0 ]] || { echo 'failed recovery command returned success' >&2; exit 1; }
grep -Fq 'recovery: FAIL deliberate test step (exit=7)' <<< "$output" || {
  echo "wrong recovery failure report: $output" >&2
  exit 1
}
echo 'Recovery step reporting tests: PASS'
