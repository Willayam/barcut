#!/usr/bin/env bash
# Installs or updates BarCut from the latest GitHub release, then opens it.
#   curl -fsSL https://raw.githubusercontent.com/Willayam/barcut/main/install.sh | bash
set -euo pipefail

url="https://github.com/Willayam/barcut/releases/latest/download/BarCut.zip"

fail() { echo "BarCut was not installed: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "BarCut runs only on macOS."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] || fail "BarCut needs a Mac with Apple silicon (M1 or later)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "BarCut needs macOS 26 or later. This Mac runs macOS $(sw_vers -productVersion)."

if [ -w /Applications ]; then dest="/Applications"; else dest="$HOME/Applications"; mkdir -p "$dest"; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading BarCut..."
curl -fsSL "$url" -o "$work/BarCut.zip" || fail "the download failed. Check your internet connection and try again."
ditto -x -k "$work/BarCut.zip" "$work"
[ -d "$work/BarCut.app" ] || fail "the download did not contain BarCut.app."

if pgrep -x BarCut >/dev/null; then
    echo "Quitting the running copy of BarCut..."
    pkill -x BarCut || true
    sleep 1
fi

rm -rf "$dest/BarCut.app"
ditto "$work/BarCut.app" "$dest/BarCut.app"
xattr -dr com.apple.quarantine "$dest/BarCut.app" 2>/dev/null || true
open "$dest/BarCut.app"

echo "Installed $dest/BarCut.app. Look for the BarCut icon in the menu bar."
echo "If macOS asks whether BarCut can access your Desktop folder, click Allow so BarCut can see new screenshots."
