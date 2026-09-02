# BarCut grounding for design runners

BarCut is a macOS menu bar app (SwiftPM, macOS 26, SwiftUI + AppKit, about 1000 lines) that keeps a
short history of recent screenshots and clipboard images so the user can re-copy or annotate them.
Read CONTEXT.md first. Its vocabulary is binding (Screenshot, Clipboard Image, Screenshot
Destination, Image History, Pending Screenshot, Annotated Image). docs/adr/0001 says BarCut must not
recreate the macOS screenshot flow; it imports what macOS writes.

## Files (read all of them, they are short)

- Sources/BarCut/BarCutApp.swift. AppDelegate owns the NSStatusItem, the NSPopover hosting
  ImageHistoryView, and annotation editor windows. Creates `ClipboardMonitor()` with defaults.
- Sources/BarCut/ClipboardMonitor.swift. The whole model. `ImageHistoryEntry { id: String (sha256 of
  a PNG re-encode), image: NSImage (full resolution), filePath: String? }`. `@Published images`,
  `@Published lastCopiedID`. Sources of images: (1) a DispatchSource on the Screenshot Destination
  directory, new files become PendingScreenshot until NSImage can read them, retried every 250 ms
  for 5 s; (2) a 1 s Combine timer polling NSPasteboard.general.changeCount. Dedup by fingerprint
  moves an existing entry to the front and can attach a filePath. Everything runs on the main
  thread. Max 10 items. Nothing is persisted; history is lost on quit.
- Sources/BarCut/ImageHistoryView.swift. Popover, 280 pt wide, rows 156 pt tall, renders
  `Image(nsImage: entry.image)` at full resolution scaled down. Hover toolbar: copy, annotate text,
  annotate arrow. Header: Clear, Quit.
- Sources/BarCut/AnnotationDocument.swift, AnnotationEditorView.swift, AnnotationTool.swift,
  LiquidGlass.swift. Annotation editor. Takes an NSImage, renders an NSImage, result goes back to
  the monitor via addAnnotatedImage (autoCopy) and copyLiveAnnotatedImage (clipboard only).
- Tests/BarCutTests/ClipboardMonitorTests.swift. Three XCTest cases using
  `ClipboardMonitor(screenshotDir:pollClipboard:watchScreenshots:)` and `scanScreenshotDestination()`.
- scripts/build-app.sh builds BarCut.app (ad hoc signed, bundle id com.williamlarsten.BarCut).
- scripts/bench.swift measures the hot paths. Baseline on a 3600x2338 screenshot (158 KB PNG):
  NSImage(contentsOf:) 9.5 ms; shipped fingerprint (tiff to png to sha256) 60 ms; full decode plus
  draw into one 560x312 row 57 ms (the popover does this per row, so 10 rows is over half a second
  and about 330 MB of decoded bitmaps); CGImageSource thumbnail at 560 px 25 ms; exact pixel hash
  (draw RGBA then sha256) 35 ms; sha256 of file bytes 0.1 ms; pasteboard writeObjects([NSImage])
  16.5 ms; pasteboard setData(png) 0.4 ms.

## What the user asked for

1. Image History must survive quit and relaunch (today it does not).
2. BarCut must come back after a reboot (launch at login).
3. Everything should feel instant and use less memory: launch, popover open, copy, ingest.
4. General solidity. Crash safety, idempotent startup, no main-thread stalls.

## Constraints the design must honor

- CONTEXT.md relationships. Image History contains readable images only, represents the same image
  once even when it arrives from multiple sources, may gain source facts later, is ordered by
  recency, and includes images observed while BarCut is running (screenshots taken while BarCut was
  quit are not imported; the startup directory snapshot stays).
- The annotation editor needs the full-resolution image and produces a full-resolution NSImage.
- Copy must produce a pasteboard other apps read as an image (PNG and TIFF both matter in practice).
- Tests construct ClipboardMonitor with injected directories and call scan methods synchronously.
  Keep tests possible without a running event loop or make the async boundary testable.
- Launch at login uses SMAppService.mainApp (ServiceManagement, macOS 13+). It needs the real bundle.
- Storage location, screenshot directory, and clipboard polling should be overridable for tests and
  for a verification script (an environment variable is fine).
- Crash or kill mid-write must not corrupt history. Startup must converge on whatever is on disk.
- Keep the diff small. Delete what the new shape makes unnecessary. No new dependencies.

## Questions the design must answer explicitly

- The persisted data shape and its on-disk layout (manifest plus files? one file per item?), and
  what identity means (fingerprint semantics; exact pixel hash off main thread vs file bytes vs
  keep the PNG re-encode).
- What lives in memory at rest (thumbnail only? full image on demand?) and who owns loading.
- Which work moves off the main thread, on what queue, and how results re-enter the published
  state without races. All published state mutation should stay on one actor.
- How restore at launch is ordered against the directory snapshot and the clipboard changeCount.
- Whether `filePath` (Screenshot Destination path) stays, and what it is for.
- How Clear, max-items eviction, and dedup interact with files on disk.
- Where the login-item toggle lives in the UI and whether first launch registers automatically.
