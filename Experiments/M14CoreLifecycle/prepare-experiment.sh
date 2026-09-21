#!/bin/bash
set -euo pipefail

ROOT="$HOME/Library/Application Support/M14CoreLifecycleExperiment"
APP="$ROOT/App/M14CoreLifecycleExperiment.app"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
STAGED_APP="$BUILD_DIR/M14CoreLifecycleExperiment.app"

if [[ "$ROOT" == *"Vaelen/runtime"* || "$ROOT" == *"Vaelen/state"* || "$ROOT" == *"dev.vaelen.core"* ]]; then
  echo "Refusing unsafe experiment root: $ROOT" >&2
  exit 2
fi
if [[ "$ROOT" != "$HOME/Library/Application Support/M14CoreLifecycleExperiment" ]]; then
  echo "Refusing unexpected experiment root: $ROOT" >&2
  exit 2
fi

if [[ -e "$APP" ]]; then
  echo "Refusing to replace an existing experiment app. Unregister and clean the experiment first." >&2
  exit 2
fi
rm -rf "$BUILD_DIR"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Library/LaunchAgents"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported experiment architecture: $ARCH" >&2; exit 2 ;;
esac

CONTROLLER="$STAGED_APP/Contents/MacOS/M14CoreLifecycleExperiment"
AGENT="$STAGED_APP/Contents/Resources/M14CoreLifecycleAgent"

swiftc -O -target "$ARCH-apple-macosx14.0" -framework Foundation -framework ServiceManagement \
  "$PROJECT_DIR/main.swift" \
  -o "$CONTROLLER"
swiftc -O -target "$ARCH-apple-macosx14.0" -framework Foundation \
  "$PROJECT_DIR/agent.swift" \
  -o "$AGENT"
if cmp -s "$CONTROLLER" "$AGENT"; then
  echo "Controller and agent unexpectedly produced identical executables." >&2
  exit 2
fi

cp "$PROJECT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/dev.vaelen.m14-lifecycle-experiment.agent.plist" \
  "$STAGED_APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"

/usr/libexec/PlistBuddy -c "Set :StandardOutPath '$ROOT/agent.stdout.log'" \
  "$STAGED_APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath '$ROOT/agent.stderr.log'" \
  "$STAGED_APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"

mkdir -p "$ROOT/App"
ditto "$STAGED_APP" "$APP"

FINAL_AGENT="$APP/Contents/Resources/M14CoreLifecycleAgent"
FINAL_PLIST="$APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"
plutil -lint "$APP/Contents/Info.plist"
plutil -lint "$FINAL_PLIST"
[[ "$(plutil -extract BundleProgram raw -o - "$FINAL_PLIST")" == "Contents/Resources/M14CoreLifecycleAgent" ]] || {
  echo "Embedded BundleProgram is not the expected experiment agent." >&2
  exit 2
}
if plutil -extract ProgramArguments raw -o - "$FINAL_PLIST" >/dev/null 2>&1; then
  echo "Embedded agent plist unexpectedly contains ProgramArguments." >&2
  exit 2
fi

# Preserve the accumulated JSONL record, but discard only stale runtime
# identity/log artifacts from the previously unregistered experiment.
rm -f "$ROOT/agent.pid" "$ROOT/agent.stdout.log" "$ROOT/agent.stderr.log"

# ServiceManagement launch admission is the subject of this experiment. Do
# not silently produce another ad-hoc/cdhash identity: require the human to
# select a stable local signing identity explicitly.
SIGNING_IDENTITY="${M14_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Set M14_SIGNING_IDENTITY to a stable local Apple Development identity before preparing this experiment." >&2
  exit 2
fi
codesign --force --sign "$SIGNING_IDENTITY" --identifier dev.vaelen.m14-lifecycle-experiment "$FINAL_AGENT"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$FINAL_AGENT"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$FINAL_AGENT" 2>&1
codesign -d -r- "$FINAL_AGENT" 2>&1
codesign -d -r- "$APP" 2>&1

echo "Prepared disposable experiment app: $APP"
echo "Signing identity: $SIGNING_IDENTITY"
echo "No ServiceManagement registration was performed."
