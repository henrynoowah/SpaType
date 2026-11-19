#!/usr/bin/env bash
# Builds SpaType.app into ./build. Usage: ./scripts/bundle.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/SpaType.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/SpaType" "$APP/Contents/MacOS/SpaType"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so Accessibility / Input Monitoring grants survive rebuilds.
# Uses a local self-signed certificate (see scripts/make-dev-cert.sh) if one is in the keychain,
# otherwise ad-hoc. Override with:
#   SPATYPE_SIGN_IDENTITY="Apple Development: you@example.com" ./scripts/bundle.sh
DEFAULT_IDENTITY="-"
for candidate in "SpaType Dev" "Retype Dev"; do
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$candidate\""; then
    DEFAULT_IDENTITY="$candidate"
    break
  fi
done
IDENTITY="${SPATYPE_SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x SpaType 2>/dev/null || true
  open "$APP"
fi
