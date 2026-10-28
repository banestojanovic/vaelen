#!/bin/bash
set -euo pipefail
EVIDENCE="${1:?usage: cleanup-fixture.sh <evidence-directory>}"
[[ -f "$EVIDENCE/run.txt" ]] || { echo "Missing run.txt; refusing cleanup" >&2; exit 1; }
value() { awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$EVIDENCE/run.txt"; }
pid="$(value pid)"
run_root="$(value run_root)"
app="$(value app)"
bundle_id="$(value bundle_id)"
fixture="$(value fixture)"
page="$(value page)"
[[ "$bundle_id" == dev.vaelen.app ]] || { echo "Unexpected bundle identity; refusing cleanup" >&2; exit 1; }
case "$fixture" in
  pending|unavailable|partial|empty|installed|all-installed|install-failed|remove-failed|php-settings|php-settings-no-default|php-settings-error|php-settings-invalid|php-settings-saving|php-update-review|php-update-progress|php-update-unknown-total|php-update-success|php-update-failed|php-update-checking|php-update-check-failed|php-release-security|php-release-coexist|php-release-stale|node-settings-selected|node-settings-unpinned|node-settings-unavailable|project-adoption|project-database|project-database-postgresql|project-database-retry|project-connection-setup|project-connection-recovery) ;;
  *) echo "Unexpected fixture identity; refusing cleanup" >&2; exit 1 ;;
esac
case "$page" in
  services|projects|php|network|general) ;;
  *) echo "Unexpected page identity; refusing cleanup" >&2; exit 1 ;;
esac
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
expected="$app/Contents/MacOS/Vaelen --settings-fixture=$fixture --settings-page=$page"
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
