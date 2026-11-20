# BarCut

BarCut keeps your latest screenshots and copied images in the macOS menu bar. Open the menu to copy
an image again, crop it, or mark it up with arrows, boxes and text.

BarCut requires macOS 26 or later on an Apple silicon Mac (M1 or later).

## Install

1. [Download BarCut for Mac](https://barcut.app/download/mac).
2. Open the disk image and drag BarCut into Applications.
3. Open BarCut from Applications. If macOS asks for access to your screenshot folder, click Allow.

Look for BarCut in the menu bar. To update, quit BarCut and replace the app with the new download.
Developers can build from source by following [CONTRIBUTING.md](CONTRIBUTING.md).

## Use BarCut

1. Take a screenshot or copy an image.
2. Select the BarCut icon in the menu bar.
3. Select a thumbnail to copy it. Use the controls on a thumbnail to annotate or crop it.

Press ⇧⌘2 to copy the newest image. The keyboard goes back to the app you were in, so you can paste
right away. To copy an older one, keep ⇧⌘ held and press 2 or the arrow keys to move through the
history, then let go. Escape closes the history without copying.

Control-click a thumbnail to remove that one image from history.

### Annotate and crop

Point at a thumbnail and select the pencil to annotate or the crop icon to crop. The editor opens
ready to draw, so the first drag is already an arrow.

- Drag to draw an arrow. Drag its middle handle to curve it and its ends to re-aim it.
- Type to add text. Right after you draw an arrow, the text labels that arrow. Otherwise it appears
  under the pointer.
- Press 1 for arrows, 2 for boxes, 3 for text and 4 for crop.
- With the crop tool, drag over the part to keep. Drag the edges to adjust it. Switch to another
  tool and the editor shows only the cropped part.
- Select any annotation to move it, recolor it, or remove it with Delete. ⌘Z undoes.
- Hold Shift to snap an arrow to 45° steps or to make a box square.

BarCut copies the image after every change, so you can paste at any point. Press Return to add the
result to the history and close the editor. Escape closes it without adding anything.

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
