# BarCut

BarCut keeps your latest screenshots and copied images in the macOS menu bar. Open the menu to copy
an image again or add text and arrow annotations.

BarCut requires macOS 26 or later on an Apple silicon Mac (M1 or later).

## Install

1. Open Terminal. Press ⌘Space, type `Terminal`, and press Return.
2. Copy this line, paste it into Terminal, and press Return:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Willayam/barcut/main/install.sh | bash
   ```

3. If macOS asks whether BarCut can access files in your Desktop folder, click Allow. BarCut needs
   this to see new screenshots.

The BarCut icon appears in the menu bar at the top right of the screen. You can close Terminal.

To update BarCut, run the same line again. The script downloads the latest release, quits BarCut if
it is running, puts `BarCut.app` in `/Applications`, and opens it. If your account cannot write to
`/Applications`, it uses `~/Applications` instead. Read [install.sh](install.sh) to see every step.

### Install without Terminal

1. Download `BarCut.zip` from the [latest release](https://github.com/Willayam/barcut/releases/latest).
2. Open the zip file and drag `BarCut.app` into your Applications folder.
3. Open BarCut. Apple has not notarized BarCut, so macOS says it cannot verify the app. Click Done.
4. Open System Settings, select Privacy & Security, and scroll to the bottom. Click Open Anyway
   next to the message about BarCut, then confirm.

You only need to do steps 3 and 4 once. Developers can build the app from source by following
[CONTRIBUTING.md](CONTRIBUTING.md).

## Use BarCut

1. Take a screenshot or copy an image.
2. Select the BarCut icon in the menu bar.
3. Select a thumbnail to copy it. Use the controls on a thumbnail to add text or an arrow.

Press ⇧⌘2 to open the history from the keyboard. The arrow keys choose an image, Return copies it,
and Escape closes the history. The keyboard then goes back to the app you were in, so you can paste
right away.

Control-click a thumbnail to remove that one image from history.

Open the menu in the history panel to clear history, enable Open at Login, turn the ⇧⌘2 shortcut
off, or quit. Clear History asks before it deletes anything. BarCut does not enable Open at Login
unless you turn it on.

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
