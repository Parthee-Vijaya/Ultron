#!/bin/bash
set -e

APP_NAME="Jarvis"
SCHEME="Jarvis"
PROJECT="Jarvis.xcodeproj"
BUILD_DIR="build"
DMG_NAME="Jarvis-5.0.0-alpha.7.dmg"

echo "=== Building $APP_NAME ==="

# Clean build
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    clean build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

# Find the built .app (exclude dmg-staging leftovers from previous runs)
APP_PATH=$(find "$BUILD_DIR" -name "$APP_NAME.app" -type d -not -path "*/dmg-staging/*" | head -1)

if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find $APP_NAME.app in build directory"
    exit 1
fi

echo "=== Found app at: $APP_PATH ==="

# Create DMG staging directory
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app to staging
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create symbolic link to /Applications
ln -s /Applications "$STAGING_DIR/Applications"

# Create DMG
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_NAME"

echo ""
echo "=== DMG created: $DMG_NAME ==="
echo "=== Size: $(du -h "$DMG_NAME" | cut -f1) ==="
echo ""
echo "To install: Open $DMG_NAME and drag Jarvis to Applications"
