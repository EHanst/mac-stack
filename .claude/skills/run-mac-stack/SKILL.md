---
name: run-mac-stack
description: Build, run, and test VibeCockpit (mac-stack). Use when asked to start VibeCockpit, build it, run its tests, or interact with the macOS app.
---

VibeCockpit is a native macOS SwiftUI IDE that runs on **macOS 26.0+ on Apple Silicon only**. There is no Linux or x86_64 build path — the app uses SwiftUI, AppKit, WKWebView, and MLX Swift (Metal GPU inference), none of which exist on Linux. All commands below run on macOS.

All paths are relative to the repo root (`mac-stack/`).

⚠️ **This skill was authored from code inspection on a Linux container where Swift is unavailable. Commands are derived from `Package.swift`, `project.yml`, and `Scripts/release.sh` — not from a live run.** Any agent running these commands on macOS should verify and update this file if anything has changed.

## Prerequisites

```bash
# macOS 15+ / Xcode 16+, Apple Silicon
xcode-select --install           # installs Xcode command-line tools
brew install libgit2 xcodegen    # libgit2 required for CLibGit2 module
```

Verify:
```bash
swift --version         # must be Swift 6.0+
pkg-config --libs libgit2   # must resolve
```

## Setup

Generate the Xcode project from `project.yml` (optional — `swift build` also works without it):

```bash
xcodegen generate
```

## Build

### Swift Package Manager (headless / CI):
```bash
swift build -c release
```

### Xcode (full app with signing):
```bash
xcodebuild -scheme VibeCockpit -configuration Release build
```

## Run (agent path)

VibeCockpit is a GUI application — there is no headless mode. Launch it with:

```bash
open .build/release/VibeCockpit.app
# or after an xcodebuild archive:
open build/export/VibeCockpit.app
```

To drive the running app programmatically, use Accessibility APIs or `osascript`. There is no built-in REPL or IPC harness — the app communicates via in-process Swift actors only.

**Direct invocation of pure-Swift logic** (no GUI required) — useful for PRs that touch non-UI code:

```bash
# Import VibeCockpitCore and call specific functions:
swift run --package-path . -Xswiftc -module-name VibeCockpitCore
# Or write a small Swift script that imports the library target
```

## Run (human path)

After `swift build` or Xcode build:
1. Open `VibeCockpit.app`
2. A 3-pane `NavigationSplitView` appears (workspace picker → file navigator → AI chat)
3. The app initializes inference via MLX Swift; first launch downloads or locates a model under `~/Library/Application Support/VibeCockpit/Models/`

To download the default model:
```bash
bash Scripts/download_bonsai.sh
```

## Test

```bash
swift test
# or to run a specific suite:
swift test --filter AppCoordinatorTests
```

Tests use Swift Testing (`@Suite`, `@Test`). They import `VibeCockpitCore` (the non-UI library target) so they compile without `SwiftUI`/`AppKit` on the test host.

## Gotchas

- **macOS 26.0 deployment target** — Xcode 16 is the minimum; earlier Xcodes will refuse to build.
- **MLX requires Apple Silicon** — `swift build` will fail on Intel Mac or Linux because `mlx-swift` has no x86_64 build.
- **`CLibGit2` needs `libgit2` via Homebrew** — `pkg-config --libs libgit2` must return a path or the SPM system library target fails to link.
- **`CSQLiteVec` embeds a C amalgamation** — the file `Modules/CSQLiteVec/sqlite-vec.c` is the full sqlite-vec source; no separate install needed.
- **Entitlements and signing files are `.gitignore`d** — `App.xcconfig`, `VibeCockpit.entitlements`, and `BuildRunner.swift` are not in the repo. For a local debug build, set `CODE_SIGNING_REQUIRED=NO` (already set in `project.yml` base settings).
- **`VibeCockpit` executable target excludes core engine files** — the `Package.swift` `exclude:` list removes `UI/` from `VibeCockpitCore` and vice versa; don't mix them.
- **`swift build` succeeds for `VibeCockpitCore` only** — the executable target links SwiftUI and will fail without macOS SDK.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `error: cannot find type 'SwiftUI.App'` on Linux | Linux build is unsupported; use macOS. |
| `pkg-config: libgit2 not found` | `brew install libgit2` |
| `MLX/MLX.h: No such file` | `mlx-swift` requires Apple Silicon; Intel Mac unsupported. |
| `Module 'CSQLiteVec' not found` | Ensure `Modules/CSQLiteVec/sqlite-vec.c` and `include/` are present. |
| Tests fail with `@testable import VibeCockpitCore` error | Run `swift build` first to compile the library target. |
