#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
if [[ -f "$PROJECT_DIR/Package.swift" ]]; then
    APP="${1:-${PROJECT_DIR:h}/outputs/MyBar.app}"
else
    APP="${1:-$SCRIPT_DIR/MyBar.app}"
fi
[[ -d "$APP/Contents" && -x "$APP/Contents/MacOS/ThermoBar" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == local.thermobar.app ]]
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/ThermoBar" --validate-pet
"$APP/Contents/MacOS/ThermoBar" --verify-broken-pipe
"$APP/Contents/Library/LaunchServices/local.thermobar.typinghelper" --validate-sounds
"$APP/Contents/Library/LaunchServices/local.mybar.trackpadhelper" --validate-protocol
[[ ! -x "$APP/Contents/Library/LaunchServices/local.thermobar.menuhelper" ]]
echo "VALID|Signature, packaged assets, broken-pipe isolation, and menu-helper quarantine"
# Deliberately does not open windows, listen for keys, play/capture audio,
# change permissions, write to SMC, or change any user settings.
