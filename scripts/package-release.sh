#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CODESIGN_IDENTITY:-}" == "Developer ID Application: "* ]] || {
    echo "A Developer ID Application signing identity is required." >&2
    exit 1
}
credentials=(--apple-id "${APPLE_ID:?}" --team-id "${APPLE_TEAM_ID:?}" --password "${APPLE_PASSWORD:?}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

notarize() {
    xcrun notarytool submit "$1" "${credentials[@]}" --wait --output-format json > "$work/submission.json"
    jq -e '.status == "Accepted"' "$work/submission.json" || {
        jq '{id, status, message}' "$work/submission.json" >&2
        return 1
    }
}

./scripts/build-app.sh
lipo BarCut.app/Contents/MacOS/BarCut -verify_arch arm64
codesign --verify --deep --strict BarCut.app
ditto -c -k --keepParent BarCut.app "$work/submission.zip"
notarize "$work/submission.zip"
xcrun stapler staple BarCut.app
xcrun stapler validate BarCut.app
spctl --assess --type execute BarCut.app

mkdir -p release "$work/disk"
ditto BarCut.app "$work/disk/BarCut.app"
ln -s /Applications "$work/disk/Applications"
hdiutil create -ov -volname BarCut -srcfolder "$work/disk" -format UDZO release/BarCut.dmg
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" release/BarCut.dmg
notarize release/BarCut.dmg
xcrun stapler staple release/BarCut.dmg
xcrun stapler validate release/BarCut.dmg
spctl --assess --type open --context context:primary-signature release/BarCut.dmg
ditto -c -k --keepParent BarCut.app release/BarCut.zip
(cd release && shasum -a 256 BarCut.zip > BarCut.zip.sha256 && shasum -a 256 BarCut.dmg > BarCut.dmg.sha256)
