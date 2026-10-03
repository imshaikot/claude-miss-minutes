#!/usr/bin/env bash
# Renders the 1024 px icon with the app binary's --render-icon mode and converts it to .icns.
# Usage: make-icns.sh <output.icns> <path to MissMinutes binary>
set -euo pipefail

OUT="$1"
BIN="$2"
WORK="$(mktemp -d)"
ICONSET="$WORK/icon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUT")"

"$BIN" --render-icon "$WORK/icon-1024.png" >/dev/null

for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$WORK"
echo "✓ $OUT"
