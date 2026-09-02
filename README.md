# BarCut

BarCut keeps your latest screenshots and copied images in the macOS menu bar. Open the menu to copy
an image again or add text and arrow annotations.

BarCut requires macOS 26 or later on an Apple silicon Mac.

## Install

Download `BarCut.zip` from the latest GitHub release, open it, and move `BarCut.app` to
`/Applications`. Launch BarCut once. Its image icon will appear in the menu bar.

Release downloads are signed with a Developer ID and notarized by Apple. Until the first release is
published, developers can build the app from source by following [CONTRIBUTING.md](CONTRIBUTING.md).

## Use BarCut

1. Take a screenshot or copy an image.
2. Select the BarCut icon in the menu bar.
3. Select a thumbnail to copy it. Use the controls on a thumbnail to add text or an arrow.

Open the menu in the history panel to clear history, enable Open at Login, or quit. BarCut does not
enable Open at Login unless you turn it on.

If a screenshot does not appear, confirm that macOS saves screenshots to an existing folder. BarCut
watches the location configured by `com.apple.screencapture`, which is the Desktop by default.

## Privacy

BarCut works locally and makes no network requests. It checks the system pasteboard twice per second,
but only imports image data. It also watches the macOS screenshot folder while it is running.

The app stores up to ten PNG files and a manifest at:

```text
~/Library/Application Support/BarCut/History
```

Clear History removes those files. Removing `BarCut.app` does not remove saved history.

## Uninstall

Turn off Open at Login from the BarCut menu, then quit the app and move it from `/Applications` to
the Trash. To delete saved history too, run:

```sh
rm -rf "$HOME/Library/Application Support/BarCut"
```

Review the path before running that command.

## How it works

- A file watcher observes the macOS screenshot destination. Screenshots created while BarCut is not
  running are not imported.
- A SHA-256 fingerprint of sRGB pixels prevents the same image from appearing twice.
- Only 560-pixel thumbnails stay in memory. The annotation editor loads the full PNG when needed.
- Storage writes are atomic. BarCut repairs a damaged manifest from the PNG files at the next launch.
- A process lock prevents more than one BarCut instance from running.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for setup and required checks. Design decisions live in
[`docs/adr`](docs/adr). Security problems should follow [SECURITY.md](SECURITY.md).

BarCut is available under the [MIT License](LICENSE).
