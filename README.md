# BarCut

Menu bar history of recent screenshots and clipboard images. Click a thumbnail to copy it again,
hover for copy, text, and arrow annotation. See CONTEXT.md for the vocabulary the code uses.

## Build and install

```
./scripts/build-app.sh --install
```

Builds a release binary, assembles and ad hoc signs `BarCut.app`, copies it to `/Applications`,
and relaunches. The first launch from `/Applications` or `~/Applications` registers BarCut as a
login item. The "Open at Login" toggle in the popover's menu turns that off or on later.

## How it works

- Sources. A file watcher on the macOS screenshot destination (`com.apple.screencapture location`,
  default `~/Desktop`) and a clipboard poll every 0.5 s. Screenshots taken while BarCut is not
  running are not imported, per the ADR in `docs/adr`.
- Storage. `~/Library/Application Support/BarCut/History` holds `manifest.json` (order and the
  source path) plus one PNG per item, ten items, newest first. Writes are atomic and startup drops
  entries without a file and deletes files without an entry, so a crash at any point converges.
- Identity. A sha256 over the sRGB pixels, so the same image arriving as a file and as clipboard
  bytes is one entry.
- Memory. Only 560 px thumbnails stay resident. The annotation editor reads the full PNG on demand.
  Copy puts the stored PNG bytes on the pasteboard and promises TIFF for apps that ask.

## Verify

```
swift test
./scripts/verify.sh                       # builds the bundle, ingests, kills, restores, evicts
swift scripts/bench.swift <screenshot.png> # times the image hot paths
/usr/bin/log show --process BarCut --last 5m --style compact
```

`BARCUT_STORE_DIR`, `BARCUT_SCREENSHOT_DIR`, and `BARCUT_POLL_CLIPBOARD=0` redirect a test
instance away from the real history, Desktop, and clipboard.
