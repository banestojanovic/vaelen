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
evidence="$(mktemp -d /private/tmp/vaelen-composer-evidence.XXXXXX)"
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
  git ls-files -z --cached --others --exclude-standard -- Sources/VaelenCLI Tests/VaelenCLITests/ComposerCommandTests.swift Tests/VaelenCLITests/ProjectPHPCLIParsingTests.swift Tests/VaelenIPCTests/ComposerEndToEndTests.swift Tests/Fixtures/Composer docs/cli/herd-parity.md | xargs -0 shasum -a 256
  find .agents/skills/verify-vaelen -type f -exec shasum -a 256 {} \;
  swift --version 2>&1
} > "$evidence/source.txt"
run launch swift build --skip-update --disable-automatic-resolution --product val
run discover swift test list --skip-update --disable-automatic-resolution
filters=(
  'VaelenCLITests.ComposerCommandTests/testExecutionPlanKeepsPHPAndComposerArgumentsInOrder'
  'VaelenCLITests.ComposerCommandTests/testMissingAndIncompatibleCandidatesHaveActionableErrors'
  'VaelenCLITests.ComposerCommandTests/testRejectsShellShebangAndMalformedPHPOpener'
  'VaelenCLITests.ComposerCommandTests/testRelativeAndEmptyPATHComponentsUseOriginalWorkingDirectory'
  'VaelenCLITests.ComposerCommandTests/testSearchChecksEachPATHDirectoryComposerThenPHAR'
  'VaelenCLITests.ComposerCommandTests/testSymlinkIsFollowedAndFirstIncompatibleCandidateStopsSearch'
  'VaelenCLITests.ProjectPHPCLIParsingTests/testComposerForwardsEveryTokenWithoutTreatingHelpAsVaelenHelp'
  'VaelenIPCTests.ComposerEndToEndTests/testComposerUsesCoreEffectivePHPAndPreservesProcessContract'
)
for name in "${filters[@]}"; do
  count="$(grep -Fc "$name" "$evidence/discover.log" || true)"
  [[ "$count" == 1 ]] || { echo "Expected one discovered test for $name, found $count" >&2; exit 1; }
done
{
  test -x .build/debug/val
  shasum -a 256 .build/debug/val
  printf 'discovered=%s selected=%s\n' "$(grep -c '^Vaelen.*Tests\.' "$evidence/discover.log")" "${#filters[@]}"
  printf 'ready=unsigned worktree CLI and eight exact tests; production Composer journey owns a private Core, socket, and SQLite store\n'
} > "$evidence/doctor.log"
filter='(ComposerCommandTests/.*|ProjectPHPCLIParsingTests/testComposerForwardsEveryTokenWithoutTreatingHelpAsVaelenHelp|ComposerEndToEndTests/testComposerUsesCoreEffectivePHPAndPreservesProcessContract)$'
run composer-drive swift test --skip-build --filter "$filter"
passed="$(grep -Ec "^Test Case .*' passed" "$evidence/composer-drive.log" || true)"
[[ "$passed" == 8 ]] || { echo "Expected eight passing test cases, found $passed" >&2; exit 1; }
for name in "${filters[@]}"; do
  short="${name##*/}"
  count="$(grep -Fc "$short]' passed" "$evidence/composer-drive.log" || true)"
  [[ "$count" == 1 ]] || { echo "Expected one pass for $name, found $count" >&2; exit 1; }
done
if grep -Eq 'Test Case .* skipped' "$evidence/composer-drive.log"; then
  echo 'Skipped or empty proof is not success.' >&2
  exit 1
fi
for marker in 'core-unavailable-exit=3' 'selected-PHP-unavailable' 'stateSnapshot=unchanged' 'cleanup serverStopped=true rootExists=false'; do
  grep -Fq "$marker" "$evidence/composer-drive.log" || { echo "Missing Composer journey evidence: $marker" >&2; exit 1; }
done
printf 'selected=8 passed=8; inspect composer-drive.log for private Core, process fidelity, error paths, unchanged state, and cleanup\n' | tee -a "$evidence/status.txt"
printf 'Proof evidence remains readable after fixture cleanup: %s\n' "$evidence"
