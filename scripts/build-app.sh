#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${1:-${PROJECT_DIR:h}/outputs}"
BUILD_DIR="$PROJECT_DIR/.build"
APP_PATH="$OUTPUT_DIR/MyBar.app"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"

swift build --disable-sandbox \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --configuration release \
    --product ThermoBarMenuHelper

swift build --disable-sandbox \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --configuration release \
    --product ThermoBar

swift build --disable-sandbox \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --configuration release \
    --product ThermoBarFanHelper

swift build --disable-sandbox \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --configuration release \
    --product ThermoBarAudioHelper

swift build --disable-sandbox \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --configuration release \
    --product TheBarTypingHelper

swift build --disable-sandbox \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --configuration release \
    --product MyBarTrackpadHelper

BIN_DIR="$(swift build --disable-sandbox \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --configuration release \
    --show-bin-path)"

STAGED_APP="$STAGING_DIR/MyBar.app"
mkdir -p \
    "$STAGED_APP/Contents/MacOS" \
    "$STAGED_APP/Contents/Resources" \
    "$STAGED_APP/Contents/Library/LaunchServices" \
    "$OUTPUT_DIR"
cp "$BIN_DIR/ThermoBar" "$STAGED_APP/Contents/MacOS/ThermoBar"
cp "$BIN_DIR/ThermoBarFanHelper" "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.fanhelper"
cp "$BIN_DIR/ThermoBarAudioHelper" "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.audiohelper"
cp "$BIN_DIR/TheBarTypingHelper" "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.typinghelper"
cp "$BIN_DIR/MyBarTrackpadHelper" "$STAGED_APP/Contents/Library/LaunchServices/local.mybar.trackpadhelper"
cp "$BIN_DIR/ThermoBarMenuHelper" "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.menuhelper"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$BIN_DIR/ThermoBar_TypingFeedbackProtocol.bundle" "$STAGED_APP/Contents/Resources/"
cp -R "$BIN_DIR/ThermoBar_ThermoBar.bundle" "$STAGED_APP/Contents/Resources/"
xcrun actool "$PROJECT_DIR/Resources/Assets.xcassets" \
    --compile "$STAGED_APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$STAGING_DIR/asset-info.plist" >/dev/null

codesign --force --sign - --identifier local.thermobar.fanhelper \
    "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.fanhelper"
codesign --force --sign - --identifier local.thermobar.audiohelper \
    "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.audiohelper"
codesign --force --sign - --identifier local.thermobar.typinghelper \
    "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.typinghelper"
codesign --force --sign - --identifier local.mybar.trackpadhelper \
    "$STAGED_APP/Contents/Library/LaunchServices/local.mybar.trackpadhelper"
codesign --force --sign - --identifier local.thermobar.menuhelper \
    "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.menuhelper"
# Quarantine this experimental feature, not the monitoring app. The live OS check
# failed system-icon preservation; do not make the helper launchable in releases.
chmod a-x "$STAGED_APP/Contents/Library/LaunchServices/local.thermobar.menuhelper"
codesign --force --sign - --identifier local.thermobar.app "$STAGED_APP"
rm -rf "$APP_PATH"
mv "$STAGED_APP" "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/MyBar.zip"
echo "$APP_PATH"
