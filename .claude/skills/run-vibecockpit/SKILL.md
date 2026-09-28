---
name: run-vibecockpit
description: Run, build, launch, start, screenshot, or visually verify the VibeCockpit macOS desktop app. Use this skill any time someone asks to run, open, demo, or take a screenshot of VibeCockpit.
---

VibeCockpit is a SwiftUI macOS app (AI Coding IDE). It must be built with `xcodebuild` into a `.app` bundle — running the SPM executable directly produces a plain Unix binary that macOS won't register as a GUI app. Once launched, the app is driven via the `mcp__computer-use__app_*` background-control tools.

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
  xcodebuild -scheme VibeCockpit \
             -project VibeCockpit.xcodeproj \
             -configuration Debug \
             -derivedDataPath /tmp/vibe-build \
             build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

The `.app` lands at:

```
/tmp/vibe-build/Build/Products/Debug/VibeCockpit.app
```

First-time build resolves SPM packages (~3-5 min). Incremental builds are fast.

## Run (agent path)

Launch:

```bash
open /tmp/vibe-build/Build/Products/Debug/VibeCockpit.app && sleep 3
```

Request access and screenshot:

```
mcp__computer-use__request_access(apps=["com.vibecockpit.app"])
mcp__computer-use__app_screenshot(app="com.vibecockpit.app", scale=0.5)
```

Click nav items by `element_index` from the AX summary (Chat=[3], Changes=[4], Models=[5], MCP Tools=[6], Snapshots=[7], Settings=[8]).

## Run (human path)

```bash
open /tmp/vibe-build/Build/Products/Debug/VibeCockpit.app
```

A window opens with a dark sidebar (Chat, Changes, Models, MCP Tools, Snapshots, Settings) and a prompt bar at the bottom. Close normally.

## Gotchas

- **`import VibeCockpitCore` in UI files breaks xcodebuild** — SPM uses `VibeCockpitCore` as a separate library module, but `project.yml` compiles everything as one `VibeCockpit` target. Those imports were removed; don't re-add them to files under `Sources/VibeCockpit/UI/` or `App/VibeCockpitApp.swift`.
- **`project.yml` must use the single-target layout** — splitting into a `VibeCockpitCore` static-library xcodegen target causes Clang dependency scanning failures for all SPM C-shim modules (`_NumericsShims`, `Cmlx`, etc.). Keep everything under the single `VibeCockpit` application target.
- **`swift build` / SPM executable won't launch as a GUI app** — `open` on a raw Unix binary doesn't register with macOS. Always use `xcodebuild` + `.app`.
- **Xcode PATH must come first** — prefix `env PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"` before xcodebuild to avoid Homebrew Swift taking precedence.
- **Package resolution on clean derived data** — if you see "Clang dependency scanning failure", delete `/tmp/vibe-build` and re-run with `-resolvePackageDependencies` first, then build.
- **Bundle ID is `com.vibecockpit.app`** — use this with `request_access` and all `app_*` tools.
