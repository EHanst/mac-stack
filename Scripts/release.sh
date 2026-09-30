#!/usr/bin/env bash
# Kokoro (VibeCockpit) release: archive -> sign (hardened runtime) -> DMG -> sign -> notarize -> staple -> verify.
#
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)" \
#   NOTARYTOOL_KEYCHAIN_PROFILE=notarytool VERSION=1.0.0 ./Scripts/release.sh
#   DRY_RUN=1 ./Scripts/release.sh     # everything except a real identity and Apple's notary service
#
# DRY_RUN signs ad hoc with the same hardened runtime + entitlements, builds the DMG, checks the
# signature flags and entitlements, and launches the packaged app as a smoke test. It stops before
# notarization (which needs the certificate and Apple's service), so it can run on any machine.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DRY_RUN="${DRY_RUN:-}"
KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-notarytool}"
ENTITLEMENTS="Config/VibeCockpit.entitlements"
ARCHIVE="build/VibeCockpit.xcarchive"
APP="build/export/VibeCockpit.app"
DMG="build/VibeCockpit-$VERSION.dmg"

if [ -n "$DRY_RUN" ]; then
  IDENTITY="-"; TIMESTAMP="--timestamp=none"
fi

echo "==> Cleaning"; rm -rf build; mkdir -p build/export
echo "==> libgit2";  ./Scripts/build-libgit2.sh
echo "==> Xcode project"; xcodegen generate >/dev/null

echo "==> Archiving $VERSION ($BUILD_NUMBER)"
# Xcode signs nothing here; the app is signed once, explicitly, below.
xcodebuild archive -scheme VibeCockpit -project VibeCockpit.xcodeproj -configuration Release \
  -archivePath "$ARCHIVE" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 2>&1 | { command -v xcbeautify >/dev/null && xcbeautify || cat; } | tail -n 40
cp -R "$ARCHIVE/Products/Applications/VibeCockpit.app" "$APP"

echo "==> Signing app (hardened runtime)"
# Sign any nested code first, deepest first (none today: everything is statically linked), then the app.
find "$APP/Contents/Frameworks" \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.dylib" -o -name "Autoupdate" -o -name "fileop" \) -print 2>/dev/null \
  | awk '{ print gsub("/","/"), $0 }' | sort -rn | cut -d' ' -f2- | while IFS= read -r nested; do
    codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$nested"
  done
codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

echo "==> Verifying app"
codesign --verify --deep --strict --verbose=2 "$APP"
FLAGS=$(codesign -d --verbose=4 "$APP" 2>&1)
echo "$FLAGS" | grep -q "flags=.*runtime" || { echo "ERROR: hardened runtime flag missing" >&2; exit 1; }
if otool -L "$APP/Contents/MacOS/VibeCockpit" | grep -E "/opt/homebrew|/usr/local/(opt|lib)|libgit2"; then
  echo "ERROR: binary links a library outside macOS" >&2; exit 1; fi
echo "entitlements:"; codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "^\s*\[Key\]|<key>" || true

echo "==> Smoke test (launch the packaged app)"
SMOKE_HOME=$(mktemp -d)
CFFIXED_USER_HOME="$SMOKE_HOME" "$APP/Contents/MacOS/VibeCockpit" >"$SMOKE_HOME/app.log" 2>&1 & SMOKE_PID=$!
for _ in $(seq 1 30); do [ -S "$SMOKE_HOME/.vibecockpit/mcp.sock" ] && break; sleep 1; done
if [ -S "$SMOKE_HOME/.vibecockpit/mcp.sock" ] && kill -0 $SMOKE_PID 2>/dev/null; then echo "app started and opened its MCP socket"; else
  echo "ERROR: packaged app did not start" >&2; tail -20 "$SMOKE_HOME/app.log" >&2; kill $SMOKE_PID 2>/dev/null || true; exit 1; fi
kill $SMOKE_PID 2>/dev/null || true; wait $SMOKE_PID 2>/dev/null || true; rm -rf "$SMOKE_HOME"

echo "==> Creating DMG"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Kokoro" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; rm -rf "$STAGE"
codesign --force $TIMESTAMP --sign "$IDENTITY" "$DMG"
codesign --verify --strict "$DMG"

if [ -n "$DRY_RUN" ]; then
  echo "==> DRY RUN stops here (no notarization). Gatekeeper would reject an ad-hoc build:"
  spctl --assess --type execute --verbose "$APP" 2>&1 | head -2 || true
  echo "OK: $DMG"; exit 0
fi

echo "==> Notarizing (this waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG"
echo "==> Gatekeeper check"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
xcrun stapler validate "$DMG"

echo "OK: $DMG"
