#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/display-pilot-tests.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
mkdir -p "$ROOT/.module-cache"
for test in "$ROOT"/Tests/*Tests.swift; do
  name="${test:t:r}"
  xcrun swiftc -D TESTING -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$ROOT/.module-cache" \
    -framework AppKit -framework CoreGraphics -framework ServiceManagement \
    "$ROOT/DisplayCore.swift" "$ROOT/BetterDisplayBridge.swift" \
    "$ROOT/PresetApplication.swift" "$ROOT/DisplayPilot.swift" "$test" -o "$OUTPUT/$name"
  "$OUTPUT/$name"
done
