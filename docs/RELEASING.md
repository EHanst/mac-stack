# Releasing Kokoro

## One-time setup (needs you)

1. **Apple Developer ID.** Enrol in the Apple Developer Program, create a *Developer ID Application* certificate, and store notarization credentials:
   `xcrun notarytool store-credentials notarytool --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`
2. **CI (optional).** Add the secrets listed at the top of `.github/workflows/release.yml`.

## Cutting a release

```
DRY_RUN=1 ./Scripts/release.sh                      # rehearsal: no certificate or Apple service needed
DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)" VERSION=1.0.1 ./Scripts/release.sh
```
Or push a tag `v1.0.1` and let CI do it. The script builds, signs (hardened runtime), smoke-tests the packaged app, builds and signs the DMG, notarizes and staples it. Publish the DMG as a GitHub release (non-draft, non-prerelease) whose tag is `v<version>`.

## How updating works

There is no auto-updater. The app asks `api.github.com/repos/EHanst/mac-stack/releases/latest` whether a newer tag exists and, if so, offers a button that opens the release page; the user downloads the DMG and drags the app in.

- Only when the user presses *Check for Updates…* (menu bar or Settings), or turns on *Check for updates daily* (off by default; never automatic under "Only on this Mac"). Manual checks appear in the privacy ledger as "Update check".
- Nothing is sent but a plain GET; nothing is installed by the app; the link must be on github.com.
- Pre-releases and drafts are ignored. The version compared is `CFBundleShortVersionString`, set from `VERSION` at build time.
- If one-click updates are wanted later, Sparkle can be added (needs an EdDSA key you must back up, an appcast, and nested-code signing); it was tried and backed out in this branch's history.
