---
name: run-kokoro
description: Run, build, launch, start, screenshot, or visually verify the Kokoro macOS desktop app. Use this skill any time someone asks to run, open, demo, or take a screenshot of Kokoro.
---

Kokoro is a SwiftUI macOS app (a prompt sidecar). It must be built with `xcodebuild` into a `.app` bundle — running the SPM executable directly produces a plain Unix binary that macOS won't register as a GUI app. Once launched, the app is driven via the `mcp__computer-use__app_*` background-control tools.

## Prerequisites

- Xcode installed at `/Applications/Xcode.app`
- `xcodegen` installed: `brew install xcodegen`
- `libgit2` installed: `brew install libgit2`
- Working directory: repo root (`/Users/erichanst/house/projects/mac-stack`)

## Build

Regenerate the Xcode project if `project.yml` changed:

```bash
xcodegen generate
```

Build the `.app` bundle:

```bash
env PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH" \
  xcodebuild -scheme Kokoro \
             -project Kokoro.xcodeproj \
             -configuration Debug \
             -derivedDataPath /tmp/kokoro-build \
             build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

The `.app` lands at:

```
/tmp/kokoro-build/Build/Products/Debug/Kokoro.app
```

First-time build resolves SPM packages (~3-5 min). Incremental builds are fast.

## Run (agent path)

Launch:

```bash
open /tmp/kokoro-build/Build/Products/Debug/Kokoro.app && sleep 3
```

Request access and screenshot:

```
mcp__computer-use__request_access(apps=["com.vibecockpit.app"])
mcp__computer-use__app_screenshot(app="com.vibecockpit.app", scale=0.5)
```

Click nav items (Briefs, Library, Models, Settings) by `element_index` from the AX summary.

## Run (human path)

```bash
open /tmp/kokoro-build/Build/Products/Debug/Kokoro.app
```

A window opens with a dark sidebar (Briefs, Library, Models, Settings) and a prompt bar at the bottom. Close normally.

## Gotchas

- **`import KokoroCore` in UI files breaks xcodebuild** — SPM uses `KokoroCore` as a separate library module, but `project.yml` compiles everything as one `Kokoro` target. Those imports were removed; don't re-add them to files under `Sources/Kokoro/UI/` or `App/KokoroApp.swift`.
- **`project.yml` must use the single-target layout** — splitting into a `KokoroCore` static-library xcodegen target causes Clang dependency scanning failures for all SPM C-shim modules (`_NumericsShims`, `Cmlx`, etc.). Keep everything under the single `Kokoro` application target.
- **`swift build` / SPM executable won't launch as a GUI app** — `open` on a raw Unix binary doesn't register with macOS. Always use `xcodebuild` + `.app`.
- **Xcode PATH must come first** — prefix `env PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"` before xcodebuild to avoid Homebrew Swift taking precedence.
- **Package resolution on clean derived data** — if you see "Clang dependency scanning failure", delete `/tmp/kokoro-build` and re-run with `-resolvePackageDependencies` first, then build.
- **Bundle ID is `com.vibecockpit.app`** — use this with `request_access` and all `app_*` tools.
