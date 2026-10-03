#!/usr/bin/env bash
# Packages dist/Miss Minutes.app into a compressed DMG with an Applications link.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
APP="$ROOT/dist/Miss Minutes.app"
DMG="$ROOT/dist/MissMinutes-$VERSION.dmg"
STAGE="$(mktemp -d)"

[ -d "$APP" ] || { echo "Build the app first: Scripts/build-app.sh" >&2; exit 1; }
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Packaging/dmg-readme.txt" "$STAGE/Read Me.txt"
rm -f "$DMG"
hdiutil create -volname "Miss Minutes $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG"
