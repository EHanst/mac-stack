#!/usr/bin/env bash
# VibeCockpit release automation: clean → archive → export → DMG → sign → notarize → staple
set -euo pipefail

SCHEME="VibeCockpit"
ARCHIVE_PATH="build/VibeCockpit.xcarchive"
EXPORT_PATH="build/export"
DMG_PATH="build/VibeCockpit.dmg"
KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-notarytool}"
DEVELOPER_ID="${DEVELOPER_ID_APPLICATION:-}"

if [ -z "$DEVELOPER_ID" ]; then
  echo "ERROR: Set DEVELOPER_ID_APPLICATION env var to your 'Developer ID Application: ...' certificate name." >&2
  exit 1
fi

echo "==> Cleaning build artifacts"
rm -rf build/
mkdir -p build

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Archiving"
xcodebuild clean archive \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -configuration Release \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" | xcbeautify

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist Config/ExportOptions.plist

echo "==> Creating DMG"
create-dmg \
  --volname "VibeCockpit" \
  --volicon "$EXPORT_PATH/VibeCockpit.app/Contents/Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 800 400 \
  --icon-size 100 \
  --icon "VibeCockpit.app" 200 190 \
  --hide-extension "VibeCockpit.app" \
  --app-drop-link 600 185 \
  "$DMG_PATH" \
  "$EXPORT_PATH/"

echo "==> Signing DMG"
codesign --deep --strict --options runtime \
  --sign "$DEVELOPER_ID" \
  "$DMG_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict "$DMG_PATH"
spctl --assess --type open --context context:primary-signature "$DMG_PATH" || true

echo "==> Submitting for notarization"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "✓ Release complete: $DMG_PATH"
