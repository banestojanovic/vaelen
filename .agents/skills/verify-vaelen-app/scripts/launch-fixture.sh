#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
EVIDENCE="${1:?usage: launch-fixture.sh <evidence-directory>}"
case "$EVIDENCE" in /*) ;; *) EVIDENCE="$ROOT/$EVIDENCE" ;; esac
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
RUN_ROOT="$(mktemp -d /private/tmp/vaelen-app-verify.XXXXXX)"
APP="$RUN_ROOT/DerivedData/Build/Products/Debug/Vaelen.app"
BUILD_LOG="$EVIDENCE/build.log"

if pgrep -x Vaelen >/dev/null 2>&1; then
  echo "Refusing to launch: a Vaelen process is already running." >&2
  rm -rf "$RUN_ROOT"
  exit 2
fi

if ! python3 "$ROOT/Scripts/prepare-bundled-php.py" --offline >"$EVIDENCE/php-preflight.txt" 2>&1; then
  cat "$EVIDENCE/php-preflight.txt" >&2
  rm -rf "$RUN_ROOT"
  exit 1
fi

if ! xcodebuild -quiet -project "$ROOT/App/Vaelen/Vaelen.xcodeproj" -scheme Vaelen \
  -configuration Debug -derivedDataPath "$RUN_ROOT/DerivedData" build >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  echo "BUILD FAILED; diagnostics retained at $BUILD_LOG" >&2
  rm -rf "$RUN_ROOT/DerivedData"
  exit 1
fi

if [[ ! -x "$APP/Contents/MacOS/Vaelen" ]]; then
  echo "Build completed without the expected executable: $APP" >&2
  rm -rf "$RUN_ROOT/DerivedData"
  exit 1
fi

printf 'pid=unlaunched\nrun_root=%s\napp=%s\nbundle_id=dev.vaelen.app\nfixture=php-settings\npage=services\n' \
  "$RUN_ROOT" "$APP" >"$EVIDENCE/run.txt"
/usr/bin/open -n "$APP" --args --settings-fixture=php-settings --settings-page=services \
  >"$EVIDENCE/launch.log" 2>&1
APP_PID=""
for _ in {1..50}; do
  APP_PID="$(ps -axo pid=,command= | awk -v executable="$APP/Contents/MacOS/Vaelen" \
    '$2 == executable && $3 == "--settings-fixture=php-settings" && $4 == "--settings-page=services" { print $1; exit }')"
  [[ -n "$APP_PID" ]] && break
  sleep 0.2
done
if [[ -z "$APP_PID" ]]; then
  cat "$EVIDENCE/launch.log" >&2
  echo "LaunchServices did not leave the fixture running; run cleanup-fixture.sh for $RUN_ROOT" >&2
  exit 1
fi
printf 'pid=%s\nrun_root=%s\napp=%s\nbundle_id=dev.vaelen.app\nfixture=php-settings\npage=services\n' \
  "$APP_PID" "$RUN_ROOT" "$APP" >"$EVIDENCE/run.txt"
echo "BUILD SUCCEEDED"
echo "LAUNCHED pid=$APP_PID app=$APP fixture=php-settings"
