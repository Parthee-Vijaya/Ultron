#!/bin/bash
# v1.2.0 — notarization wrapper for Jarvis DMGs.
#
# Required environment:
#   APPLE_ID            — Apple ID email used for notarization
#   APPLE_TEAM_ID       — 10-char Team ID from developer.apple.com
#   APPLE_APP_PASSWORD  — app-specific password for the Apple ID
#
# Typical flow (locally):
#   export APPLE_ID="you@example.com"
#   export APPLE_TEAM_ID="ABCD123456"
#   export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # create at appleid.apple.com
#   ./build-dmg.sh
#   ./scripts/notarize.sh
#
# The CI workflow calls this script automatically when the three secrets are
# set on the repo. Skipped otherwise so alpha releases ship unnotarized.

set -e

DMG=$(ls Jarvis-*.dmg | head -1)
if [ -z "$DMG" ]; then
  echo "ERROR: No Jarvis-*.dmg found in working directory"
  exit 1
fi

if [ -z "$APPLE_ID" ] || [ -z "$APPLE_TEAM_ID" ] || [ -z "$APPLE_APP_PASSWORD" ]; then
  echo "Notarization skipped — set APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD to enable."
  exit 0
fi

echo "=== Submitting $DMG to Apple notary service ==="
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

echo "=== Stapling notarization ticket onto $DMG ==="
xcrun stapler staple "$DMG"

echo "=== Verifying ==="
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG" || true

echo "=== Done ==="
