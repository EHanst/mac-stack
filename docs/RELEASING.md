# Releasing VibeCockpit

## One-time setup (needs you)

1. **Apple Developer ID.** Enrol in the Apple Developer Program, create a *Developer ID Application* certificate, and store notarization credentials:
   `xcrun notarytool store-credentials notarytool --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`
2. **Update-signing key (Sparkle).** Run once on your Mac (the private key goes into your login keychain):
   `/tmp/vibe-build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
   (or find `generate_keys` under `SourcePackages/artifacts/sparkle/Sparkle/bin` after a build). It prints the **public** key: put it in `project.yml` as `SUPublicEDKey` (replacing `REPLACE_WITH_SPARKLE_PUBLIC_KEY`) and re-run `xcodegen generate`. Until then the updater stays off and "Check for Updates…" is greyed out.
   Back the private key up (`generate_keys -x file`, keep it out of git). **If it is lost, installed copies can never be updated** — users would have to download a new build by hand.
3. **CI (optional).** Add the secrets listed at the top of `.github/workflows/release.yml`, including `SPARKLE_ED_PRIVATE_KEY` (contents of the file from `generate_keys -x`).

## Cutting a release

```
DRY_RUN=1 ./scripts/release.sh                      # rehearsal: no certificate or Apple service needed
DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)" VERSION=1.0.1 ./scripts/release.sh
```
Or push a tag `v1.0.1` and let CI do it. The script builds, signs (hardened runtime, nested code first), smoke-tests the packaged app, builds and signs the DMG, notarizes and staples it, and writes `build/appcast.xml`. Attach both the DMG and `appcast.xml` to the GitHub release; installed apps read `releases/latest/download/appcast.xml`.

## How updating behaves

- Manual by default: nothing contacts GitHub until the user picks *Check for Updates…* (menu bar or Settings) or turns on *Check for updates daily*. No system profile is sent.
- Sparkle verifies every download against the EdDSA signature in the appcast, so a hijacked download host cannot push code.
- The version comes from the tag (`VERSION`); the build number is the git commit count, and Sparkle compares build numbers.
