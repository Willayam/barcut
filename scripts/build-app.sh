#!/usr/bin/env bash
# Builds BarCut.app next to Package.swift. Pass --install to copy it to /Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | tail -1
app="BarCut.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp .build/release/BarCut "$app/Contents/MacOS/BarCut"
# Compiles the Icon Composer icon into Assets.car (light, dark and tinted) plus AppIcon.icns.
xcrun actool Assets/AppIcon.icon --compile "$app/Contents/Resources" --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -d)/icon.plist" --enable-on-demand-resources NO \
    --development-region en --target-device mac --minimum-deployment-target 26.0 --platform macosx \
    --output-format human-readable-text >/dev/null
signing_args=(--force --options runtime --sign "${CODESIGN_IDENTITY:--}")
if [[ "${CODESIGN_IDENTITY:-}" == "Developer ID Application: "* ]]; then
    signing_args+=(--timestamp)
fi
codesign "${signing_args[@]}" "$app"
echo "built $PWD/$app"

if [ "${1:-}" = "--install" ]; then
    pkill -x BarCut || true
    rm -rf /Applications/BarCut.app
    cp -R "$app" /Applications/BarCut.app
    open /Applications/BarCut.app
    echo "installed and launched /Applications/BarCut.app"
fi
