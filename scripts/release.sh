#!/usr/bin/env bash
# Builds a universal SpaType.app and zips it for a GitHub release.
# Usage: ./scripts/release.sh   ->  build/SpaType-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
swift test
SPATYPE_UNIVERSAL=1 ./scripts/bundle.sh
# The in-app updater only installs builds signed with the same certificate as the running app.
# Ad-hoc builds have no Authority and a cdhash-only requirement: nobody could update to or from them.
codesign -dvv build/SpaType.app 2>&1 | grep -q '^Authority=' \
  || { echo "Release is ad-hoc signed. Sign with the \"SpaType\" release certificate (GitHub secret SPATYPE_CERT_P12)." >&2; exit 1; }

ZIP="build/SpaType-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the code signature and extended attributes intact (plain zip can break them).
ditto -c -k --sequesterRsrc --keepParent build/SpaType.app "$ZIP"
codesign --verify --deep --strict build/SpaType.app
echo "Wrote $ZIP ($(lipo -archs build/SpaType.app/Contents/MacOS/SpaType))"
