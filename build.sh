#!/bin/bash
# Build GitPad.app from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
rm -rf GitPad.app
mkdir -p GitPad.app/Contents/MacOS
cp .build/release/GitPad GitPad.app/Contents/MacOS/
cp Info.plist GitPad.app/Contents/
codesign --force --sign - GitPad.app
echo "Built $(pwd)/GitPad.app"
