#!/bin/bash
# Build GitPad.app from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")"
# app icon: regenerate only when the generator is newer than the shipped icns
if [ ! -f Resources/AppIcon.icns ] || [ make-icon.swift -nt Resources/AppIcon.icns ]; then
    ./make-icns.sh
fi
swift build -c release
rm -rf GitPad.app
mkdir -p GitPad.app/Contents/MacOS GitPad.app/Contents/Resources
cp .build/release/GitPad GitPad.app/Contents/MacOS/
cp Info.plist GitPad.app/Contents/
cp Resources/AppIcon.icns GitPad.app/Contents/Resources/
codesign --force --options runtime --sign - GitPad.app
echo "Built $(pwd)/GitPad.app"
