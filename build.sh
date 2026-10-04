#!/bin/bash
# Builds build/DropPulse.app. Works with just the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

# In the macOS 27 SDK, @State is a macro whose plugin only ships with Xcode,
# so without Xcode build against the 26.5 SDK (Liquid Glass APIs are the same).
if [[ "$(xcode-select -p)" == *CommandLineTools* && -z "${SDKROOT:-}" ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

swift build -c release

APP=build/DropPulse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DropPulse "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources
cp Resources/AppIcon.icns Resources/*Template.pdf "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
