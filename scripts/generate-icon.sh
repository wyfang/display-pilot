#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${1:-$ROOT/Assets}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}display-pilot-icon.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$OUTPUT" "$ROOT/.module-cache"
xcrun swift -module-cache-path "$ROOT/.module-cache" \
  "$ROOT/scripts/generate-icon.swift" "$TEMP_DIR/DisplayPilot.iconset"
iconutil --convert icns --output "$OUTPUT/DisplayPilot.icns" "$TEMP_DIR/DisplayPilot.iconset"
cp "$TEMP_DIR/DisplayPilot.iconset/icon_512x512@2x.png" "$OUTPUT/DisplayPilot.png"
echo "$OUTPUT/DisplayPilot.icns"
