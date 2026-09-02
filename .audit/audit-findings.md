# Audit findings, base 886092d

Read every file. Findings ordered by user impact. F1 to F3 are the user's asks; the rest came out
of the read and the benchmark.

F1. No persistence. `ClipboardMonitor.images` lives only in memory. Quit loses everything.
F2. No launch at login. Nothing registers with ServiceManagement.
F3. Popover cost scales with full-resolution bitmaps. Each row draws `Image(nsImage:)` from the full
    screenshot, so a 10 row popover decodes about 330 MB and spends over half a second before first
    paint (57 ms per row measured). Memory stays high after because NSImage caches the decode.
F4. Ingest blocks the main thread. `addImage` runs `imageFingerprint` (tiff, then png re-encode,
    then sha256) on main, 60 ms measured on a flat screenshot, more on busy ones. Folder ingest also
    does `NSImage(contentsOf:)` on main as the readability probe.
F5. Dedup fingerprint depends on re-encoding through NSBitmapImageRep, so two different decoders
    of the same pixels can produce different PNG bytes and defeat the "same image once" rule.
F6. Copy latency. `writeObjects([NSImage])` costs 16.5 ms versus 0.4 ms for handing the pasteboard
    the PNG bytes we already hold. Both PNG and TIFF should stay available to consumers.
F7. `filePath` is stored and never read. It exists so a history item can gain a source fact later.
    Keep only if the persisted model has a cheap place for it.
F8. `knownFiles` grows without bound while the app runs (one string per file ever seen in the
    Screenshot Destination). Harmless at Desktop scale, worth noting.
F9. Startup reads the screencapture location once. Changing it in macOS needs a BarCut relaunch.
    Acceptable, document it.
F10. Directory watch failure is silent when the Screenshot Destination is missing or unreadable.
F11. `AnnotationDocument.render()` uses `lockFocus`, so output pixel size follows the screen scale
     rather than the source bitmap. Fine on this retina Mac; on a non-retina main display it halves
     an annotated image. Out of scope for this run, logged as open.
F12. No single-instance guard. LaunchServices already dedups `open` by bundle id, so a login item
     plus a manual launch of the same bundle does not double up. Skip.
F13. Tests cover pending screenshot import only. Nothing covers persistence, restore, eviction,
     dedup, or Clear. The rewrite must land tests for each.
