#!/bin/bash
# Build, sign (Developer ID), notarize, and package GitPad for release.
# Dev builds use ./build.sh (ad-hoc signed); this script is the production path.
#
# One-time setup (stores an app-specific password in your keychain; Claude/CI never see it):
#   xcrun notarytool store-credentials gitpad-notary --apple-id <you@apple.id> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" \
    | sed 's/.*"\(.*\)"/\1/') || true
if [ -z "${IDENTITY:-}" ]; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "Create one at developer.apple.com → Certificates, download, and double-click to install." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="GitPad-$VERSION.zip"

# assemble the app exactly like build.sh, then sign for real
if [ ! -f Resources/AppIcon.icns ] || [ make-icon.swift -nt Resources/AppIcon.icns ]; then
    ./make-icns.sh
fi
swift build -c release
rm -rf GitPad.app "$ZIP"
mkdir -p GitPad.app/Contents/MacOS GitPad.app/Contents/Resources
cp .build/release/GitPad GitPad.app/Contents/MacOS/
cp Info.plist GitPad.app/Contents/
cp Resources/AppIcon.icns GitPad.app/Contents/Resources/
codesign --force --options runtime --timestamp --sign "$IDENTITY" GitPad.app

# notarize a temp zip, staple the app, then zip the stapled app for distribution
ditto -c -k --keepParent GitPad.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile gitpad-notary --wait
xcrun stapler staple GitPad.app
rm "$ZIP"
ditto -c -k --keepParent GitPad.app "$ZIP"

spctl -a -vv GitPad.app
echo "Release ready: $(pwd)/$ZIP (v$VERSION, notarized + stapled)"
echo "SHA-256 (paste into the release notes so users can verify downloads):"
shasum -a 256 "$ZIP"
