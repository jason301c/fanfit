#!/bin/zsh
# Builds release binaries and wraps the menu bar app in build/FanFit.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app=build/FanFit.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/FanFit "$app/Contents/MacOS/FanFit"
cp support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app and .build/release/fanfitd"
