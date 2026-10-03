#!/usr/bin/env bash
# Notarizes a Developer ID signed .app or .dmg with Apple and staples the ticket to it.
# Usage: notarize.sh <path>   with APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD
# (an app-specific password from appleid.apple.com) in the environment.
set -euo pipefail

TARGET="$1"
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"

SUBMIT="$TARGET"
if [ -d "$TARGET" ]; then
  # notarytool takes a zip, dmg or pkg, not a bare bundle.
  SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "▸ Notarizing $(basename "$TARGET")"
xcrun notarytool submit "$SUBMIT" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" --wait --timeout 30m
xcrun stapler staple "$TARGET"
echo "✓ Notarized and stapled $TARGET"
