#!/bin/bash
set -euo pipefail

ROOT="$HOME/Library/Application Support/M14CoreLifecycleExperiment"
APP_ROOT="$ROOT/App"
FINAL_APP="$APP_ROOT/M14CoreLifecycleExperiment.app"
AB_ROOT="$ROOT/AB"
UNSIGNED_ROOT="$AB_ROOT/unsigned"
ARTIFACT_ROOT="$AB_ROOT/artifacts"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$ROOT" != "$HOME/Library/Application Support/M14CoreLifecycleExperiment" || "$ROOT" == *"Vaelen/runtime"* || "$ROOT" == *"Vaelen/state"* || "$ROOT" == *"dev.vaelen.core"* ]]; then
  echo "Refusing unsafe experiment root: $ROOT" >&2
  exit 2
fi

assert_real_directory() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local real_path
    real_path="$(cd "$path" && pwd -P)"
    if [[ "$real_path" != "$path" ]]; then
      echo "Refusing symlinked experiment path: $path -> $real_path" >&2
      exit 2
    fi
  fi
}

assert_real_directory "$ROOT"
assert_real_directory "$APP_ROOT"
assert_real_directory "$AB_ROOT"

VARIANT="${1:-}"
case "$VARIANT" in
  A) HELPER_IDENTIFIER="dev.vaelen.m14-lifecycle-experiment.agent" ;;
  B) HELPER_IDENTIFIER="dev.vaelen.m14-lifecycle-experiment" ;;
  *) echo "Usage: $0 A|B" >&2; exit 2 ;;
esac

SIGNING_IDENTITY="${M14_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Set M14_SIGNING_IDENTITY to the stable Apple Development identity." >&2
  exit 2
fi

if [[ -e "$FINAL_APP" ]]; then
  echo "Refusing to replace the final experiment app. Clean it through the approved controller workflow first." >&2
  exit 2
fi

mkdir -p "$UNSIGNED_ROOT" "$ARTIFACT_ROOT" "$APP_ROOT"
assert_real_directory "$ROOT"
assert_real_directory "$APP_ROOT"
assert_real_directory "$AB_ROOT"
assert_real_directory "$UNSIGNED_ROOT"
assert_real_directory "$ARTIFACT_ROOT"
U_CONTROLLER="$UNSIGNED_ROOT/M14CoreLifecycleExperiment"
U_HELPER="$UNSIGNED_ROOT/M14CoreLifecycleAgent"
INPUT_HASHES="$UNSIGNED_ROOT/sha256.txt"

if [[ ! -e "$U_CONTROLLER" || ! -e "$U_HELPER" || ! -e "$INPUT_HASHES" ]]; then
  if [[ -e "$U_CONTROLLER" || -e "$U_HELPER" || -e "$INPUT_HASHES" ]]; then
    echo "Unsigned A/B input set is incomplete; refusing to compile a replacement." >&2
    exit 2
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
  swiftc -O -target "$ARCH-apple-macosx14.0" -framework Foundation -framework ServiceManagement \
    "$PROJECT_DIR/main.swift" -o "$U_CONTROLLER"
  swiftc -O -target "$ARCH-apple-macosx14.0" -framework Foundation \
    "$PROJECT_DIR/agent.swift" -o "$U_HELPER"
  if cmp -s "$U_CONTROLLER" "$U_HELPER"; then
    echo "Controller and helper unexpectedly produced identical unsigned executables." >&2
    exit 2
  fi
  shasum -a 256 "$U_CONTROLLER" "$U_HELPER" > "$INPUT_HASHES"
else
  echo "Reusing preserved unsigned A/B inputs; no compilation performed."
fi

if ! shasum -a 256 "$U_CONTROLLER" "$U_HELPER" | cmp -s - "$INPUT_HASHES"; then
  echo "Preserved unsigned A/B inputs do not match their recorded hashes." >&2
  exit 2
fi

VARIANT_APP="$ARTIFACT_ROOT/$VARIANT/M14CoreLifecycleExperiment.app"
VARIANT_ROOT="$ARTIFACT_ROOT/$VARIANT"
assert_real_directory "$VARIANT_ROOT"
if [[ -e "$VARIANT_APP" ]]; then
  echo "Refusing to replace existing artifact $VARIANT_APP" >&2
  exit 2
fi
mkdir -p "$VARIANT_ROOT"
assert_real_directory "$VARIANT_ROOT"
mkdir -p "$VARIANT_APP/Contents/MacOS" "$VARIANT_APP/Contents/Resources" "$VARIANT_APP/Contents/Library/LaunchAgents"
cp "$U_CONTROLLER" "$VARIANT_APP/Contents/MacOS/M14CoreLifecycleExperiment"
cp "$U_HELPER" "$VARIANT_APP/Contents/Resources/M14CoreLifecycleAgent"
cp "$PROJECT_DIR/Info.plist" "$VARIANT_APP/Contents/Info.plist"
cp "$PROJECT_DIR/dev.vaelen.m14-lifecycle-experiment.agent.plist" \
  "$VARIANT_APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"

FINAL_PLIST="$VARIANT_APP/Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath '$ROOT/agent.stdout.log'" "$FINAL_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath '$ROOT/agent.stderr.log'" "$FINAL_PLIST"
plutil -lint "$VARIANT_APP/Contents/Info.plist"
plutil -lint "$FINAL_PLIST"
[[ "$(plutil -extract BundleProgram raw -o - "$FINAL_PLIST")" == "Contents/Resources/M14CoreLifecycleAgent" ]] || exit 2
if plutil -extract ProgramArguments raw -o - "$FINAL_PLIST" >/dev/null 2>&1; then
  echo "ProgramArguments must remain absent." >&2
  exit 2
fi

codesign --force --sign "$SIGNING_IDENTITY" --identifier "$HELPER_IDENTIFIER" \
  "$VARIANT_APP/Contents/Resources/M14CoreLifecycleAgent"
codesign --force --sign "$SIGNING_IDENTITY" "$VARIANT_APP"
codesign --verify --strict --verbose=2 "$VARIANT_APP/Contents/Resources/M14CoreLifecycleAgent"
codesign --verify --deep --strict --verbose=2 "$VARIANT_APP"

ditto "$VARIANT_APP" "$FINAL_APP"
echo "Prepared controlled A/B artifact $VARIANT at $FINAL_APP"
echo "Unsigned input hashes: $INPUT_HASHES"
echo "Helper identifier: $HELPER_IDENTIFIER"
echo "No ServiceManagement registration was performed."
