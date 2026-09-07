#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUTPUT="${DISPLAYPILOT_OUTPUT_DIR:-$ROOT/dist}"
APP="$OUTPUT/Display Pilot.app"
ARCH="${DISPLAYPILOT_ARCH:-$(uname -m)}"
TARGET="$ARCH-apple-macosx13.0"

case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "不支持的架构: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$ROOT/.module-cache"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/DisplayPilot.icns" "$APP/Contents/Resources/DisplayPilot.icns"
xcrun swiftc \
  -O \
  -target "$TARGET" \
  -module-cache-path "$ROOT/.module-cache" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ServiceManagement \
  "$ROOT/DisplayCore.swift" \
  "$ROOT/BetterDisplayBridge.swift" \
  "$ROOT/PresetApplication.swift" \
  "$ROOT/DisplayPilot.swift" \
  -o "$APP/Contents/MacOS/DisplayPilot"
codesign --force --sign - "$APP"

echo "$APP"
