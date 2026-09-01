#!/usr/bin/env bash
# Builds BarCut.app next to Package.swift. Pass --install to copy it to /Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | tail -1
app="BarCut.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
cp .build/release/BarCut "$app/Contents/MacOS/BarCut"
codesign --force --sign - "$app" 2>/dev/null
echo "built $PWD/$app"

if [ "${1:-}" = "--install" ]; then
    pkill -x BarCut || true
    rm -rf /Applications/BarCut.app
    cp -R "$app" /Applications/BarCut.app
    open /Applications/BarCut.app
    echo "installed and launched /Applications/BarCut.app"
fi
