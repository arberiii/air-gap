#!/bin/bash
# Builds a release binary for this Mac and wraps it into build/AirGap.app (menu-bar only, ad-hoc signed).
# Needs only the Command Line Tools (xcode-select --install); pass --universal for an arm64 + x86_64 build (needs Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS=(--arch "$(uname -m)")
[ "${1:-}" = "--universal" ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -q -c release "${ARCHS[@]}"
APP=build/AirGap.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/AirGap" "$APP/Contents/MacOS/AirGap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
