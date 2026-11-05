#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
ICON_SOURCE="${1:-$PROJECT_DIR/Resources/TheBarIcon.png}"
ICON_DIR="$PROJECT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"

# Mechanical export only: keep the generated master and its alpha unchanged.
for entry in \
    "16:icon_16x16.png" "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" "512:icon_256x256@2x.png" \
    "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    ICON_SIZE="${entry%%:*}"
    ICON_FILENAME="${entry#*:}"
    sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" --out "$ICON_DIR/$ICON_FILENAME" >/dev/null
done
