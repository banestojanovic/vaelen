#!/bin/sh
set -eu

ROOT="${SRCROOT}/../.."
APP_CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
HELPER_PRODUCT="$ROOT/.build/release/vaelen-privileged-helper"
HELPER_DEST="$APP_CONTENTS/MacOS/vaelen-privileged-helper"
PLIST_DEST="$APP_CONTENTS/Library/LaunchDaemons/dev.vaelen.privileged-helper.plist"
MANIFEST_DEST="$APP_CONTENTS/Resources/vaelen-privileged-helper.manifest"

if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] || [ "$EXPANDED_CODE_SIGN_IDENTITY" = "-" ]; then
  echo "error: SMAppService daemon requires a non-ad-hoc code-signing identity" >&2
  exit 1
fi

swift build --package-path "$ROOT" --configuration release --product vaelen-privileged-helper
if [ ! -x "$HELPER_PRODUCT" ]; then
  echo "error: Release privileged helper was not produced at $HELPER_PRODUCT" >&2
  exit 1
fi

mkdir -p "$(dirname "$HELPER_DEST")" "$(dirname "$PLIST_DEST")"
install -m 755 "$HELPER_PRODUCT" "$HELPER_DEST"
# Record the helper payload before embedding its code signature. Re-signing the
# app/helper for a local development install should not look like a functional
# helper update and trigger an unregister/register cycle.
helper_payload_digest=$(/usr/bin/shasum -a 256 "$HELPER_PRODUCT" | /usr/bin/awk '{print $1}')
/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
  --identifier dev.vaelen.privileged-helper --timestamp=none "$HELPER_DEST"
/usr/bin/codesign --verify --strict "$HELPER_DEST"

helper_team=$(/usr/bin/codesign -dv --verbose=4 "$HELPER_DEST" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
if [ -z "$helper_team" ] || [ "$helper_team" = "not set" ]; then
  echo "error: signed helper has no meaningful Apple signing team" >&2
  exit 1
fi
if [ -n "${DEVELOPMENT_TEAM:-}" ] && [ "$helper_team" != "$DEVELOPMENT_TEAM" ]; then
  echo "error: helper Team ID $helper_team differs from Xcode DEVELOPMENT_TEAM $DEVELOPMENT_TEAM" >&2
  exit 1
fi

cat > "$PLIST_DEST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.vaelen.privileged-helper</string>
  <key>BundleProgram</key>
  <string>Contents/MacOS/vaelen-privileged-helper</string>
  <key>MachServices</key>
  <dict>
    <key>dev.vaelen.privileged-helper</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$PLIST_DEST"
mkdir -p "$(dirname "$MANIFEST_DEST")"
plist_digest=$(/usr/bin/shasum -a 256 "$PLIST_DEST" | /usr/bin/awk '{print $1}')
printf '%s:%s\n' "$helper_payload_digest" "$plist_digest" > "$MANIFEST_DEST"
