# Synthesized design (base: fable, grafts from opus and sol)

## Synthesis decision

Base is the fable candidate. Its store returns a full `Snapshot` per transaction with a revision,
so the main actor has one `apply` and no splice logic. Its on-disk shape (one `manifest.json` plus
`<id>.png`) keeps order and source facts in one atomic file and needs the least sweep logic.

Grafted from opus: the login toggle and Quit live in an ellipsis `Menu` in the popover header,
not a right-click menu on the status item. It is where the user already looks. Clear stays a
visible button. Also opus's point that `entries` is `private(set)`.

Grafted from sol: a `Logger` (subsystem `com.williamlarsten.BarCut`, category `history`) at
`notice` level for restore count, each ingest, watcher failure, and store directory failure, so
the real app can be verified from `log show` instead of a self-report.

Rejected: opus's manifest-less directory (source facts would have nowhere to live, thumbnail
files and sequence parsing add sweep cases). Sol's snapshot A/B startup (the store serializes
transactions, so the simpler init order converges anyway). Sol's `Set` of screenshot paths (one
optional path is enough). Persisted thumbnail files from opus and sol (ten 25 ms decodes off main
at launch is cheaper than a second file per item).

## Shape

Everything in `.audit/design-fable.md` under "Shape" applies, with these fixed decisions:

- `ImageHistoryEntry { id: ImageID, thumbnail: CGImage, screenshotPath: String? }`, marked
  `@unchecked Sendable` with a one-line why (immutable after the store builds it).
- `ImageID` is sha256 hex over `width, height` then the RGBA8 sRGB premultiplied-last bytes of the
  image drawn into a `CGContext` of the source pixel size. File name is `<hex>.png`.
- Store directory default `~/Library/Application Support/BarCut/History`. Env overrides on nil
  init arguments: `BARCUT_STORE_DIR`, `BARCUT_SCREENSHOT_DIR`, `BARCUT_POLL_CLIPBOARD=0`.
- Clipboard poll every 0.5 s, tolerance 0.2 s.
- Copy writes an `NSPasteboardItem` with `.png` data set eagerly and `.tiff` promised through a
  data provider the monitor retains. `lastChangeCount` is set in the same main-actor block.
- Login item: `enum LoginItem` over `SMAppService.mainApp` with `isEnabled`, `setEnabled(_:)`.
  On first launch, register only when `Bundle.main.bundlePath` starts with `/Applications/` or
  `~/Applications/` and the status is `.notRegistered`, then set UserDefaults
  `didAutoRegisterLoginItem` so the user's later choice sticks. Never in tests or `swift run`.
- Popover header: `BarCut` title, `Clear` button, ellipsis `Menu` holding a `Toggle("Open at
  Login")` bound to `LoginItem` and `Quit`.
- `AnnotationEditorView` unchanged. `onAnnotate` passes the entry; AppDelegate awaits
  `monitor.fullImage(for:)` and opens the editor.
- `ImageStore.ingest` returns nil for a file whose `CGImageSourceGetStatus` is not
  `.statusComplete` or that yields no image, which is how a Pending Screenshot stays pending.
