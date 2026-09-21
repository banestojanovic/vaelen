#!/bin/bash
set -euo pipefail

ROOT="$HOME/Library/Application Support/M14CoreLifecycleExperiment"
APP_ROOT="$ROOT/App"
FINAL_APP="$APP_ROOT/M14CoreLifecycleExperiment.app"
GEN_ROOT="$ROOT/AB/repaired-A"
UNSIGNED_ROOT="$GEN_ROOT/unsigned"
ARTIFACT_APP="$GEN_ROOT/artifact/M14CoreLifecycleExperiment.app"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$ROOT" != "$HOME/Library/Application Support/M14CoreLifecycleExperiment" || "$ROOT" == *"Vaelen/runtime"* || "$ROOT" == *"Vaelen/state"* || "$ROOT" == *"dev.vaelen.core"* ]]; then
  echo "Refusing unsafe experiment root: $ROOT" >&2
  exit 2
fi
if [[ -e "$FINAL_APP" || -e "$GEN_ROOT" ]]; then
  echo "Refusing to replace an existing repaired-A artifact or final app." >&2
  exit 2
fi

SIGNING_IDENTITY="${M14_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Set M14_SIGNING_IDENTITY to the stable Apple Development identity." >&2
  exit 2
fi

ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac

mkdir -p "$UNSIGNED_ROOT" "$ARTIFACT_APP/Contents/MacOS" "$ARTIFACT_APP/Contents/Resources" "$ARTIFACT_APP/Contents/Library/LaunchAgents" "$APP_ROOT"
U_CONTROLLER="$UNSIGNED_ROOT/M14CoreLifecycleExperiment"
U_HELPER="$UNSIGNED_ROOT/M14CoreLifecycleAgent"

swiftc -O -target "$ARCH-apple-macosx14.0" -framework Foundation -framework ServiceManagement \
  "$PROJECT_DIR/main.swift" -o "$U_CONTROLLER"
swiftc -O -target "$ARCH-apple-macosx14.0" -framework Foundation \
  "$PROJECT_DIR/agent.swift" -o "$U_HELPER"
if cmp -s "$U_CONTROLLER" "$U_HELPER"; then
  echo "Controller and helper unexpectedly produced identical executables." >&2
  exit 2
fi
shasum -a 256 "$U_CONTROLLER" "$U_HELPER" > "$UNSIGNED_ROOT/sha256.txt"
shasum -a 256 "$PROJECT_DIR/main.swift" "$PROJECT_DIR/agent.swift" > "$UNSIGNED_ROOT/source-sha256.txt"

cp "$U_CONTROLLER" "$ARTIFACT_APP/Contents/MacOS/M14CoreLifecycleExperiment"
cp "$U_HELPER" "$ARTIFACT_APP/Contents/Resources/M14CoreLifecycleAgent"
cp "$PROJECT_DIR/Info.plist" "$ARTIFACT_APP/Contents/Info.plist"
cp "$PROJECT_DIR/dev.vaelen.m14-lifecycle-experiment.agent.plist" \
  "$ARTIFACT_APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"

FINAL_PLIST="$ARTIFACT_APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath '$ROOT/agent.stdout.log'" "$FINAL_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath '$ROOT/agent.stderr.log'" "$FINAL_PLIST"
plutil -lint "$ARTIFACT_APP/Contents/Info.plist"
plutil -lint "$FINAL_PLIST"
[[ "$(plutil -extract BundleProgram raw -o - "$FINAL_PLIST")" == "Contents/Resources/M14CoreLifecycleAgent" ]] || exit 2
if plutil -extract ProgramArguments raw -o - "$FINAL_PLIST" >/dev/null 2>&1; then
  echo "ProgramArguments must remain absent." >&2
  exit 2
fi

codesign --force --sign "$SIGNING_IDENTITY" --identifier dev.vaelen.m14-lifecycle-experiment.agent \
  "$ARTIFACT_APP/Contents/Resources/M14CoreLifecycleAgent"
codesign --force --sign "$SIGNING_IDENTITY" "$ARTIFACT_APP"
codesign --verify --strict --verbose=2 "$ARTIFACT_APP/Contents/Resources/M14CoreLifecycleAgent"
codesign --verify --deep --strict --verbose=2 "$ARTIFACT_APP"
ditto "$ARTIFACT_APP" "$FINAL_APP"

echo "Prepared repaired-A artifact: $FINAL_APP"
echo "Repaired-A unsigned hashes: $UNSIGNED_ROOT/sha256.txt"
echo "Repaired-A source hashes: $UNSIGNED_ROOT/source-sha256.txt"
echo "No ServiceManagement registration was performed."
