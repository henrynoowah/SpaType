#!/usr/bin/env bash
# Builds SpaType.app into ./build. Usage: ./scripts/bundle.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

# SPATYPE_UNIVERSAL=1 builds for both Apple silicon and Intel (used by scripts/release.sh).
BUILD_ARGS=(-c release)
if [[ "${SPATYPE_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP="build/SpaType.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SpaType" "$APP/Contents/MacOS/SpaType"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so Accessibility / Input Monitoring grants survive rebuilds.
# Uses the self-signed "SpaType" release certificate (or a local one from scripts/make-dev-cert.sh) if in the keychain,
# otherwise ad-hoc. Override with:
#   SPATYPE_SIGN_IDENTITY="Apple Development: you@example.com" ./scripts/bundle.sh
DEFAULT_IDENTITY="-"
for candidate in "SpaType" "SpaType Dev" "Retype Dev"; do
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
