#!/usr/bin/env bash
# Installs (or updates) the latest Miss Minutes release and opens it:
#   curl -fsSL https://raw.githubusercontent.com/imshaikot/claude-miss-minutes/main/Scripts/install.sh | bash
# Downloaded with curl, the app carries no quarantine flag, so Gatekeeper doesn't stop the ad-hoc build.
set -euo pipefail

REPO="imshaikot/claude-miss-minutes"
APP_NAME="Miss Minutes.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Miss Minutes is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Miss Minutes needs macOS 14 or later (this Mac runs $(sw_vers -productVersion))."

# /releases/latest redirects to /releases/tag/vX.Y.Z.
tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
tag="${tag##*/}"
case "$tag" in v*) ;; *) fail "Couldn't find the latest release of $REPO." ;; esac
version="${tag#v}"
base="https://github.com/$REPO/releases/download/$tag"
zip="MissMinutes-$version.zip"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say "▸ Downloading Miss Minutes $version"
curl -fL --progress-bar -o "$work/$zip" "$base/$zip"
curl -fsSL -o "$work/SHA256SUMS.txt" "$base/SHA256SUMS.txt"
(cd "$work" && grep " $zip\$" SHA256SUMS.txt | shasum -a 256 -c - >/dev/null) || fail "Checksum mismatch for $zip."
ditto -x -k "$work/$zip" "$work"
[ -d "$work/$APP_NAME" ] || fail "$zip doesn't contain $APP_NAME."

dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

if pgrep -x MissMinutes >/dev/null; then
  say "▸ Quitting the running Miss Minutes"
  osascript -e 'quit app "Miss Minutes"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x MissMinutes 2>/dev/null || true
fi

say "▸ Installing to $dest/$APP_NAME"
rm -rf "${dest:?}/$APP_NAME"
ditto "$work/$APP_NAME" "$dest/$APP_NAME"

command -v claude >/dev/null || say "Note: Claude Code isn't on your PATH. Install it (https://claude.com/claude-code) and sign in; it is her brain."
command -v node >/dev/null || say "Note: Node.js isn't installed. She still talks, but Claude can't move her and the neural voice is unavailable."

open "$dest/$APP_NAME"
say "✓ Miss Minutes $version is installed. Click her or press ⌃⌥M to talk."
