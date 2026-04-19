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
    # NB: we ENABLE code signing with the adhoc "-" identity instead of skipping
    # it (CODE_SIGNING_ALLOWED=YES). Reason: without a real codesign pass the
    # linker produces a binary where the Info.plist isn't bound into the signed
    # code directory. TCC (the macOS permissions database) keys its grants on
    # the signed bundle ID, so with no Info.plist binding every rebuild gets
    # treated as a *different* app and existing Accessibility / Microphone /
    # Screen-Recording grants don't carry over — causing the permission dialog
    # to pop up on every single run. Signing adhoc keeps `pavi.Jarvis` stable
    # across builds and lets TCC track a single persistent identity.
    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" | head -30
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "✗ build output missing at $APP_PATH"
    exit 1
fi

# Verify the signature actually bound the Info.plist — if not, TCC churn would
# return and we'd regret shipping the fix. `codesign -dv` surfaces `Info.plist=…`
# (the hash) on a bound binary and `Info.plist=not bound` on a broken one.
if codesign -dv "$APP_PATH" 2>&1 | grep -q "Info.plist=not bound"; then
    echo "⚠  codesign didn't bind Info.plist — TCC will still churn. Check CODE_SIGNING_ALLOWED."
fi

echo "▶ launching $APP_PATH"
open "$APP_PATH"
echo "✓ Jarvis running. Tail logs with:  tail -f ~/Library/Logs/Jarvis/jarvis.log"
