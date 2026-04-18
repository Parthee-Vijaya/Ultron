#!/bin/bash
# run-dev.sh — build Debug and launch the .app directly.
# No DMG, no drag-to-Applications. Use this to iterate fast on UX tweaks.
#
# Usage:
#   ./run-dev.sh              # build + run
#   ./run-dev.sh --no-build   # just launch the last build
#
set -e

cd "$(dirname "$0")"

PROJECT="Jarvis.xcodeproj"
SCHEME="Jarvis"
BUILD_DIR="build-debug"
APP_PATH="$BUILD_DIR/Build/Products/Debug/Jarvis.app"

# Always kill any running instance so Keychain + mic don't get double-bound.
if pgrep -x Jarvis > /dev/null; then
    echo "▶ killing running Jarvis…"
    pkill -x Jarvis || true
    sleep 0.4
fi

if [[ "${1:-}" != "--no-build" ]]; then
    echo "▶ building Debug…"
    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" | head -30
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "✗ build output missing at $APP_PATH"
    exit 1
fi

echo "▶ launching $APP_PATH"
open "$APP_PATH"
echo "✓ Jarvis running. Tail logs with:  tail -f ~/Library/Logs/Jarvis/jarvis.log"
