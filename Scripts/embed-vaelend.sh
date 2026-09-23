#!/bin/sh
set -eu

ROOT="${SRCROOT}/../.."
swift build --package-path "$ROOT" --configuration release --product vaelend

CORE="$ROOT/.build/release/vaelend"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/vaelend"
if [ ! -x "$CORE" ]; then
  echo "error: Vaelen Core build did not produce $CORE" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
install -m 755 "$CORE" "$DEST"
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$DEST"
