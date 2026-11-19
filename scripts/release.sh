#!/usr/bin/env bash
# Builds a universal SpaType.app and zips it for a GitHub release.
# Usage: ./scripts/release.sh   ->  build/SpaType-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
swift test
SPATYPE_UNIVERSAL=1 ./scripts/bundle.sh

ZIP="build/SpaType-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the code signature and extended attributes intact (plain zip can break them).
ditto -c -k --sequesterRsrc --keepParent build/SpaType.app "$ZIP"
codesign --verify --deep --strict build/SpaType.app
echo "Wrote $ZIP ($(lipo -archs build/SpaType.app/Contents/MacOS/SpaType))"
