#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift scripts/make-icon.swift "$TMP/icon.png" >/dev/null

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$TMP/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/icon.png" Resources/AppIcon.png
echo "Wrote Resources/AppIcon.icns"
