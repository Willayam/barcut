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

A merge to `main` that changes the app starts the Release workflow. It builds, signs, notarizes
and publishes the DMG and the zip used by install.sh, after verifying the stapled app and disk
image with Gatekeeper. Changes to the website or the docs do not start it.

The workflow chooses the version. It takes the short version in Info.plist, or the last release
plus one patch when that version is already out, so a pull request does not need to bump it. To
move to a new minor or major version, change the short version in Info.plist. The build number is
the commit count. To release `main` without an app change, run the workflow by hand.

The workflow needs the GitHub Actions secrets `APPLE_CERTIFICATE` (base64 of a Developer ID
Application .p12 with its Apple intermediate certificate), `APPLE_CERTIFICATE_PASSWORD`,
`APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_PASSWORD` (an app-specific
password).

## Deploy barcut.app

The Cloudflare Worker serves `site/`. A merge to `main` that changes `site/` or `wrangler.toml`
starts the Website workflow, which checks that the latest release includes `BarCut.dmg` and then
deploys. It needs the GitHub Actions secrets `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`.
