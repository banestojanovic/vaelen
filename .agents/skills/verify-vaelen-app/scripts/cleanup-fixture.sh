#!/bin/bash
set -euo pipefail
EVIDENCE="${1:?usage: cleanup-fixture.sh <evidence-directory>}"
[[ -f "$EVIDENCE/run.txt" ]] || { echo "Missing run.txt; refusing cleanup" >&2; exit 1; }
value() { awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$EVIDENCE/run.txt"; }
pid="$(value pid)"
run_root="$(value run_root)"
app="$(value app)"
[[ "$run_root" == /private/tmp/vaelen-app-verify.* && "$app" == "$run_root/DerivedData/Build/Products/Debug/Vaelen.app" ]] || {
  echo "Run paths do not match the expected isolated build; refusing cleanup" >&2; exit 1;
}
[[ "${run_root%/*}" == /private/tmp && "${run_root##*/}" == vaelen-app-verify.* ]] || {
  echo "Run root is not a direct child of /private/tmp; refusing cleanup" >&2; exit 1;
}
actual=""
if [[ "$pid" != unlaunched ]]; then
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "Invalid recorded PID; refusing cleanup" >&2; exit 1; }
fi
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  actual="${actual#"${actual%%[![:space:]]*}"}"
fi
expected="$app/Contents/MacOS/Vaelen --settings-fixture=php-settings --settings-page=services"
if [[ -n "$actual" ]]; then
  [[ "$actual" == "$expected" ]] || { echo "PID identity changed; leaving process and scratch state untouched" >&2; exit 1; }
  kill -TERM "$pid"
  for _ in {1..30}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "Owned fixture did not exit; preserving evidence and scratch state" >&2
    exit 1
  fi
fi
if [[ -d "$app" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app"
fi
rm -rf "$run_root"
printf 'pid=%s\nexit=confirmed\n' "$pid" >"$EVIDENCE/cleanup.txt"
echo "Owned fixture stopped; scratch build removed; evidence retained at $EVIDENCE"
