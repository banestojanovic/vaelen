#!/bin/bash
# Run /shift one item per fresh Claude session until STOP, failure, or the round limit.
# Usage: Scripts/auto-shift.sh [max_rounds] (default 5). Never pushes.
set -u
cd "$(dirname "$0")/.." || exit 1

max=${1:-5}
if ! [[ "$max" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [positive max_rounds]" >&2
  exit 2
fi
logs=${VAELEN_SHIFT_LOGS:-$HOME/.cache/vaelen-shift}
mkdir -p "$logs" || exit 1
final="error:Auto-shift ended unexpectedly"
trap 'echo "stop: ${final#*:}"' EXIT

allowed=(
  Read Edit Write Grep Glob Agent
  "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)"
  "Bash(git rev-parse:*)" "Bash(git branch:*)"
  "Bash(git add:*)" "Bash(git commit:*)"
  "Bash(Scripts/test.sh:*)" "Bash(Scripts/tests/:*)"
  "Bash(swift build:*)" "Bash(swift test:*)" "Bash(python3:*)"
  "Bash(rg:*)" "Bash(find:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)"
)
prompt='/shift 1

Finish your report with one last line, exactly `SHIFT: CONTINUE` if another queue item remains that needs no owner decision, otherwise `SHIFT: STOP <reason>`. Never push.'

for round in $(seq 1 "$max"); do
  before=$(git rev-parse HEAD) || exit 1
  log="$logs/$(date +%Y%m%d-%H%M%S)-round$round.log"
  echo "round $round/$max (log: $log)"
  printf '%s\n' "$prompt" | claude -p --model sonnet --permission-mode acceptEdits \
    --allowedTools "${allowed[@]}" >"$log" 2>&1
  status=$?
  tail -n 8 "$log"
  if [ "$status" -ne 0 ]; then final="error:Claude exited $status in round $round"; exit 1; fi
  if tail -n 3 "$log" | grep -q '^SHIFT: STOP'; then
    final="done:$(grep '^SHIFT: STOP' "$log" | tail -n 1)"
    exit 0
  fi
  if [ "$(git rev-parse HEAD)" = "$before" ]; then final="error:No new commit in round $round"; exit 1; fi
  if ! tail -n 3 "$log" | grep -q '^SHIFT: CONTINUE'; then
    final="done:Round $round did not say CONTINUE"
    exit 0
  fi
done
final="done:Reached $max rounds"
