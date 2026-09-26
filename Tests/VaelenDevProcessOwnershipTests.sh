#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/vaelen-dev"

# A worktree harness must recognize the canonical app's embedded processes.
CORE="/private/tmp/vaelen-worktree/.build/release/vaelend"
DNS="/private/tmp/vaelen-worktree/.build/release/vaelendns"
CANONICAL_APP="/Applications/Vaelen.app"

is_owned_process_command "$CANONICAL_APP/Contents/Resources/vaelend" || {
  echo "canonical app-embedded Core was not recognized from a worktree harness" >&2; exit 1;
}
is_owned_process_command "$CANONICAL_APP/Contents/Resources/vaelendns --port 53535" || {
  echo "canonical app-embedded DNS was not recognized from a worktree harness" >&2; exit 1;
}
is_owned_process_command "$CORE" || { echo "worktree release Core was not recognized" >&2; exit 1; }
is_owned_process_command "$DNS --port 53535" || { echo "worktree release DNS was not recognized" >&2; exit 1; }
if is_owned_process_command "/opt/other/Vaelen.app/Contents/Resources/vaelend"; then
  echo "unrelated Core was incorrectly treated as owned" >&2; exit 1
fi

echo "Vaelen developer harness process ownership tests: PASS"
