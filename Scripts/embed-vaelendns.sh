#!/bin/sh
set -eu

ROOT="${SRCROOT}/../.."
RESPONDER="$ROOT/.build/release/vaelendns"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/vaelendns"

swift build --package-path "$ROOT" --configuration release --product vaelendns
if [ ! -x "$RESPONDER" ]; then
  echo "error: Release DNS responder was not produced at $RESPONDER" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
install -m 755 "$RESPONDER" "$DEST"
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
  --identifier dev.vaelen.dns-responder --timestamp=none "$DEST"
/usr/bin/codesign --verify --strict "$DEST"
