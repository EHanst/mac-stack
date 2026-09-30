#!/usr/bin/env bash
# Regenerate the (gitignored) Xcode project, build Debug, and relaunch the app.
# Fails loudly on build errors so you never launch a stale binary.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
LOG=$(mktemp)
if ! xcodebuild -scheme VibeCockpit -configuration Debug -destination 'platform=macOS' build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "BUILD FAILED (full log: $LOG)" >&2
  exit 1
fi
APP=$(xcodebuild -scheme VibeCockpit -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/VibeCockpit.app
pkill -x VibeCockpit 2>/dev/null || true
for _ in $(seq 20); do pgrep -x VibeCockpit >/dev/null || break; sleep 0.25; done
for _ in 1 2 3; do open "$APP" 2>/dev/null && break; sleep 1; done
echo "Launched $APP"
