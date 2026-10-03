#!/usr/bin/env bash
# Builds Miss Minutes in release mode and assembles a self-contained .app bundle.
# ARCHS="arm64" skips the Intel slice for quick local builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST="$ROOT/dist"
APP="$DIST/Miss Minutes.app"
ARCHS="${ARCHS:-arm64 x86_64}"
HOST_ARCH="$(uname -m)"

cd "$ROOT"

echo "▸ Building Miss Minutes $VERSION ($BUILD_NUMBER) for: $ARCHS"
mkdir -p "$DIST"
slices=()
for arch in $ARCHS; do
  build=(swift build -c release --triple "${arch}-apple-macosx14.0" --product MissMinutes)
  "${build[@]}"
  # Where the binary lands depends on the toolchain's build system (swiftbuild
  # puts every arch in one folder), so ask, and copy it out before the next arch.
  slice="$DIST/MissMinutes-$arch"
  cp "$("${build[@]}" --show-bin-path)/MissMinutes" "$slice"
  lipo "$slice" -verify_arch "$arch"
  slices+=("$slice")
done

BIN="$DIST/MissMinutes.bin"
if [ ${#slices[@]} -gt 1 ]; then
  lipo -create "${slices[@]}" -output "$BIN"
else
  cp "${slices[0]}" "$BIN"
fi

if [ ! -f "$DIST/AppIcon.icns" ]; then
  echo "▸ Rendering the app icon with the character renderer"
  HOST_BIN="$DIST/MissMinutes-$HOST_ARCH"
  [ -x "$HOST_BIN" ] || HOST_BIN="$BIN"
  "$ROOT/Scripts/make-icns.sh" "$DIST/AppIcon.icns" "$HOST_BIN"
fi
rm -f "${slices[@]}"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bridge" "$APP/Contents/Resources/voice"
mv "$BIN" "$APP/Contents/MacOS/MissMinutes"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp bridge/miss-minutes-mcp.mjs bridge/package.json "$APP/Contents/Resources/bridge/"
# Only the neural voice's installer: its packages and model are downloaded on request.
cp voice/miss-minutes-voice.mjs voice/package.json voice/package-lock.json "$APP/Contents/Resources/voice/"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo "✓ $APP"
