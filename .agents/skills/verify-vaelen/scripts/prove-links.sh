#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
cd "$repo"
if [[ "$(git rev-parse --absolute-git-dir)" == "$(git rev-parse --path-format=absolute --git-common-dir)" ]]; then
  echo 'Use an isolated task worktree, not the canonical checkout.' >&2
  exit 1
fi
if [[ -n "${VAELEN_TEST_SUPPORT_ROOT_ENABLED:-}" || -n "${VAELEN_TEST_SUPPORT_ROOT:-}" ]]; then
  echo 'Unset ambient VAELEN_TEST_SUPPORT_ROOT_ENABLED and VAELEN_TEST_SUPPORT_ROOT before verification.' >&2
  exit 1
fi
evidence="$(mktemp -d /private/tmp/vaelen-verify-evidence.XXXXXX)"
printf 'Evidence retained at %s\n' "$evidence"
run() {
  local label="$1" code
  shift
  printf '%q ' "$@" >> "$evidence/commands.txt"
  printf '\n' >> "$evidence/commands.txt"
  if "$@" > "$evidence/$label.log" 2>&1; then code=0; else code=$?; fi
  printf '%s exit=%s\n' "$label" "$code" | tee -a "$evidence/status.txt"
  if [[ "$code" != 0 ]]; then cat "$evidence/$label.log"; return "$code"; fi
}
{
  printf 'worktree=%s\nbranch=%s\ncommit=%s\n' "$repo" "$(git branch --show-current)" "$(git rev-parse HEAD)"
  git status --short
  git diff --stat HEAD
  git diff HEAD | shasum -a 256
  find .agents/skills/verify-vaelen -type f -exec shasum -a 256 {} \;
  swift --version 2>&1
} > "$evidence/source.txt"
run launch swift build --skip-update --disable-automatic-resolution --product val
run discover swift test list --skip-update --disable-automatic-resolution
filters=(
  testHumanLinksEndToEndSixMinimalNoPHPProjects
  testHumanLinksDetectsMissingExpectedProject
  testSubprocessTimeoutTerminatesOwnedChildWithoutPreservingRoot
)
for name in "${filters[@]}"; do
  count="$(grep -c "^VaelenIPCTests.LinkedProjectsPerformanceTests/$name$" "$evidence/discover.log" || true)"
  [[ "$count" == 1 ]] || { echo "Expected one discovered test for $name, found $count" >&2; exit 1; }
done
{
  test -x .build/debug/val
  shasum -a 256 .build/debug/val
  printf 'discovered=%s selected=3\n' "$(grep -c '^Vaelen.*Tests\.' "$evidence/discover.log")"
  printf 'ready=unsigned worktree CLI and three exact tests; private Core doctor runs inside each links scenario\n'
} > "$evidence/doctor.log"
filter='LinkedProjectsPerformanceTests/(testHumanLinksEndToEndSixMinimalNoPHPProjects|testHumanLinksDetectsMissingExpectedProject|testSubprocessTimeoutTerminatesOwnedChildWithoutPreservingRoot)$'
run drive swift test --skip-build --filter "$filter"
grep -Eq 'Executed 3 tests, with 0 failures' "$evidence/drive.log"
for name in "${filters[@]}"; do
  count="$(grep -Fc "LinkedProjectsPerformanceTests $name]' passed" "$evidence/drive.log" || true)"
  [[ "$count" == 1 ]] || { echo "Expected one pass for $name, found $count" >&2; exit 1; }
done
if grep -Eq 'Test Case .* skipped' "$evidence/drive.log"; then
  echo 'Skipped or empty proof is not success.' >&2
  exit 1
fi
printf 'selected=3 passed=3; inspect drive.log for doctor, CLI output, controlled mismatch, and cleanup\n' | tee -a "$evidence/status.txt"
printf 'Proof evidence remains readable after fixture cleanup: %s\n' "$evidence"
