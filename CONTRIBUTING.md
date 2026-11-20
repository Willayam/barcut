# Contributing to BarCut

BarCut accepts bug fixes, accessibility improvements, and focused feature proposals.

## Development setup

You need an Apple silicon Mac with macOS 26, Xcode 26, and the Xcode Command Line Tools.

```sh
git clone https://github.com/Willayam/barcut.git
cd barcut
swift test
./scripts/build-app.sh
open BarCut.app
```

The package has no third-party dependencies. Source files live in `Sources/BarCut`. Tests live in
`Tests/BarCutTests`. `CONTEXT.md` defines terms used by the implementation.

## Before opening a pull request

Run these checks:

```sh
swift test
swift build -c release
git diff --check
```

Keep pull requests limited to one change. Explain user-visible behavior and add tests for storage,
clipboard, or screenshot monitoring changes. Do not include screenshots or clipboard contents from
other people in fixtures or bug reports.

## Release a Mac download

Set the GitHub Actions secrets `APPLE_CERTIFICATE` (base64 of a Developer ID Application .p12 with its Apple intermediate certificate),
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_PASSWORD` (an app-specific password). Update both version fields in Info.plist and push
a tag matching the short version, such as `v1.2.0`. The release workflow verifies the stapled
app and disk image with Gatekeeper before publishing the DMG and the zip used by install.sh.

## Deploy barcut.app

The Cloudflare Worker serves `site/`. To enable deployment from this repository, set the
`CLOUDFLARE_ACCOUNT_ID` Actions variable and the `CLOUDFLARE_API_TOKEN` secret. The Website
workflow checks that the latest release includes `BarCut.dmg` before publishing.

For version 1.2.0, the signing and website jobs ran in the see.computer repository, which holds
the shared credentials. Both jobs checked out the same pinned BarCut commit. The release job
returned the notarized DMG and zip as artifacts for publication in the BarCut repository.
