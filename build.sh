#!/bin/bash
# Builds build/Droplet.app. Works with just the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

# In the macOS 27 SDK, @State is a macro whose plugin only ships with Xcode,
# so without Xcode build against the 26.5 SDK (Liquid Glass APIs are the same).
if [[ "$(xcode-select -p)" == *CommandLineTools* && -z "${SDKROOT:-}" ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

swift build -c release

APP=build/Droplet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Droplet "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
