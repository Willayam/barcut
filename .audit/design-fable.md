# BarCut design candidate (fable)

## Problem

Image History has to become durable, fast, and small without changing what it means. The hard
part is not persistence. It is that identity, ordering, eviction, and files on disk all have to
agree while three sources (Screenshot Destination, pasteboard, annotation editor) feed the list at
unpredictable times and the app can die at any point. Today one class on the main thread holds
full-resolution NSImages and hashes a PNG re-encode (60 ms) per arrival. Splitting that into
"in-memory list plus a side file" invites races between the list and the directory. The shape
below makes the directory the truth, puts every change to it behind one actor, and treats the
published list as a cache of the last transaction.

## Usage (caller's view)

AppDelegate creates the monitor as before. Overrides come from the environment inside the init
defaults (`BARCUT_STORE_DIR`, `BARCUT_SCREENSHOT_DIR`, `BARCUT_POLL_CLIPBOARD=0`).

```swift
private let monitor = ClipboardMonitor()

// Annotate: the row hands over the entry, the delegate loads full resolution off main.
ImageHistoryView(monitor: monitor) { [weak self] entry, tool in
    Task { @MainActor in
        guard let self, let image = await self.monitor.fullImage(for: entry) else { return }
        self.openAnnotationEditor(image: image, initialTool: tool)
    }
}

// Right-click menu on the status item.
menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    .state = LoginItem.isEnabled ? .on : .off
```

ImageHistoryView renders thumbnails and issues commands. Nothing awaits in the view.

```swift
ForEach(monitor.images) { entry in
    ImageHistoryRow(
        thumbnail: entry.thumbnail,
        isCopied: monitor.lastCopiedID == entry.id,
        onCopy: { monitor.copy(entry) },
        onAnnotate: { tool in onAnnotate(entry, tool) }
    )
}
Button("Clear") { monitor.clearHistory() }
```

The annotation editor keeps its two callbacks. `onComplete` becomes durable, `onPreviewChanged`
stays clipboard only.

```swift
onPreviewChanged: { [weak self] rendered in self?.monitor.copyLiveAnnotatedImage(rendered) },
onComplete: { [weak self, weak window] rendered in
    self?.monitor.addAnnotatedImage(rendered)
    window?.close()
}
```

Tests await the scan and get a settled list. No expectations, no run loop spinning.

```swift
@MainActor
func testImportsReadableScreenshotFromObservedDestination() async throws {
    let dir = try makeTempDir()
    let monitor = ClipboardMonitor(screenshotDir: dir.path, storeDir: try makeTempDir().path,
                                   pollClipboard: false, watchScreenshots: false)
    try validPNGData().write(to: dir.appendingPathComponent("Screenshot.png"))
    await monitor.scanScreenshotDestination()
    XCTAssertEqual(monitor.images.count, 1)
    XCTAssertEqual(monitor.images.first?.screenshotPath?.hasSuffix("Screenshot.png"), true)
}

@MainActor
func testHistorySurvivesRelaunch() async throws {
    let store = try makeTempDir().path
    let first = ClipboardMonitor(screenshotDir: shots.path, storeDir: store, pollClipboard: false, watchScreenshots: false)
    try validPNGData().write(to: shots.appendingPathComponent("A.png"))
    await first.scanScreenshotDestination()
    let second = ClipboardMonitor(screenshotDir: shots.path, storeDir: store, pollClipboard: false, watchScreenshots: false)
    await second.refresh()
    XCTAssertEqual(second.images.map(\.id), first.images.map(\.id))
}
```

## Shape

### Data

```swift
/// sha256 over an sRGB RGBA8 redraw of the pixels, prefixed with width and height.
/// Same function for every source, so a Screenshot arriving from the file and from the
/// pasteboard gets one id. Doubles as the file name.
struct ImageID: Hashable, Codable { let hex: String; var fileName: String { hex + ".png" } }

struct ImageHistoryEntry: Identifiable, Equatable {
    let id: ImageID
    let thumbnail: CGImage            // longest side 560 px, about 0.7 MB decoded
    var screenshotPath: String?       // Screenshot Destination path, a source fact, nothing else
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.screenshotPath == b.screenshotPath }
}

/// What the monitor hands to the store. Read on the main actor, cheap to produce.
enum ImageSource {
    case screenshotFile(URL)          // bytes as macOS wrote them
    case pasteboard(Data, isPNG: Bool)// png if offered, else tiff
    case rendered(CGImage)            // Annotated Image from the editor
}

struct Snapshot { let revision: Int; let entries: [ImageHistoryEntry] }

/// On disk: <storeDir>/manifest.json plus <storeDir>/<id>.png per item. Order is array order.
private struct Manifest: Codable {
    var version = 1
    var items: [Item]
    struct Item: Codable { let id: ImageID; var screenshotPath: String? }
}
```

### The store

```swift
/// Owns the directory. Every method is one transaction: mutate manifest, write files, write
/// manifest atomically, bump revision, return the full list. Nothing else touches storeDir.
actor ImageStore {
    init(directory: URL, maxItems: Int)

    /// Returns nil for a Pending Screenshot (CGImageSource status not complete, or unreadable).
    func ingest(_ source: ImageSource, screenshotPath: String?) -> Snapshot? { fatalError("not implemented") }
    func current() -> Snapshot                { fatalError("not implemented") }   // load if needed
    func clear() -> Snapshot                  { fatalError("not implemented") }
    func pngData(for id: ImageID) -> Data?    { fatalError("not implemented") }
    func fullImage(for id: ImageID) -> CGImage? { fatalError("not implemented") }

    // private, all synchronous inside the actor
    // ensureLoaded(): read manifest, drop items whose file is missing or unreadable, delete
    //   every *.png the manifest does not name, decode thumbnails, write manifest. Runs once,
    //   lazily, at the top of every public method. Idempotent by construction.
    // fingerprint(CGImage) -> ImageID        35 ms on a 3600x2338 image
    // thumbnail(CGImageSource) -> CGImage    25 ms via kCGImageSourceThumbnailMaxPixelSize 560
    // commit(): items.prefix(maxItems), write manifest (Data.write .atomic), delete files of
    //   items that left, drop their thumbnails, revision += 1
}
```

Ingest steps, all inside the actor: build a `CGImageSource` (from URL or Data), require status
`.statusComplete` and a decodable frame, fingerprint, then either move the existing item to the
front (attaching `screenshotPath` when given) or write `<id>.png` atomically and insert at index 0.
PNG bytes for `.screenshotFile` and `.pasteboard(isPNG: true)` are copied as is. TIFF and rendered
images are encoded once here. Thumbnails come from the source, not from a second decode.

### The monitor

```swift
@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published private(set) var images: [ImageHistoryEntry] = []
    @Published private(set) var lastCopiedID: ImageID?

    init(screenshotDir: String? = nil, storeDir: String? = nil, maxItems: Int = 10,
         pollClipboard: Bool = true, watchScreenshots: Bool = true)
    // env overrides applied to nil arguments; default store is
    // ~/Library/Application Support/BarCut/History

    func refresh() async                       // apply store.current(); init calls it in a Task
    func scanScreenshotDestination() async     // discover pending, ingest each, retry the rest
    func copy(_ entry: ImageHistoryEntry)      // Task: pngData -> pasteboard -> flash
    func fullImage(for entry: ImageHistoryEntry) async -> NSImage?
    func addAnnotatedImage(_ image: NSImage)   // Task: ingest(.rendered) then copy(front)
    func copyLiveAnnotatedImage(_ image: NSImage)  // writeObjects([image]), bump lastChangeCount
    func clearHistory()                        // Task: apply(store.clear())

    private func apply(_ s: Snapshot) { guard s.revision > applied else { return }; applied = s.revision; images = s.entries }
    private var pending: [String: PendingScreenshot]   // unchanged shape
    private var knownFiles: Set<String>                // startup snapshot of the Destination
}
```

The monitor keeps: the DispatchSource on the Screenshot Destination, the 1 s poll, the 250 ms
retry for Pending Screenshots, the changeCount bookkeeping. The source handler and the timer call
`Task { await scanScreenshotDestination() }` and `Task { await checkClipboard() }`.

Copy writes the PNG bytes with `setData(_, forType: .png)` (0.4 ms) and registers the monitor as
`NSPasteboardItemDataProvider` for `.tiff`, decoding on demand for the few apps that only read
TIFF. `lastChangedCount` is set right after the write, so the poll never re-imports our own copy.

### Module map

- `Sources/BarCut/ImageStore.swift` (new). `ImageID`, `ImageSource`, `Snapshot`, `Manifest`,
  the actor, fingerprint and thumbnail helpers. Only file that imports ImageIO and CryptoKit.
- `Sources/BarCut/ClipboardMonitor.swift`. Sources, pending bookkeeping, pasteboard, published
  state. Loses `imageFingerprint`, `sha256Hex`, `imageFromClipboard`, the `NSImage(contentsOf:)`
  probe, and the `image` field. About 60 lines shorter.
- `Sources/BarCut/ImageHistoryView.swift`. Rows take `CGImage`, `onAnnotate` passes the entry.
- `Sources/BarCut/BarCutApp.swift`. Right-click NSMenu on the status item, `LoginItem` enum
  (20 lines over `SMAppService.mainApp`), async editor open, first-launch registration.
- `Tests/BarCutTests/ClipboardMonitorTests.swift`. Existing three become `async` and pass a
  temp `storeDir`. Add relaunch, dedup across file and pasteboard bytes, orphan sweep, and
  truncated-manifest cases against `ImageStore` directly.

### Load-bearing decisions

- On-disk layout. `manifest.json` plus `<id>.png`. The manifest is the only order and the only
  index. The PNG is the canonical image. No thumbnail files, no sidecars.
- Identity. Exact pixel hash off main. File bytes differ between a Screenshot's file and its
  pasteboard copy, so a byte hash would show one image twice and break the CONTEXT rule. The
  PNG re-encode hash is the same idea at twice the cost.
- Memory at rest. Ten thumbnails, about 7 MB total, down from about 330 MB. Full resolution is
  read from disk only for the editor and only for the entry the user picked. The store owns
  loading. The view never loads anything.
- Threading. Main actor does pasteboard IO, directory listing, pending bookkeeping, and all
  published mutation. The `ImageStore` actor does decode, hash, thumbnail, PNG encode, file and
  manifest writes. Results re-enter as full `Snapshot` values through `await`, guarded by
  revision so a late result cannot overwrite a newer list. There is no shared mutable object.
- Restore order at launch. `init` records `changeCount` and the Destination file list
  synchronously (both under 1 ms) so images present at launch are never imported, then starts
  the watcher and poll, then `Task { await refresh() }`. Because the store loads lazily inside
  its first transaction, an ingest that lands before `refresh` still operates on the persisted
  manifest and simply becomes revision 2. Order converges either way.
- Crash safety. Files and manifest use `.atomic` writes. Crash after the PNG but before the
  manifest leaves an orphan, swept at next load. Crash after the manifest but before eviction
  deletes leaves an orphan, same sweep. A manifest item with no file is dropped at load. A
  truncated manifest decodes as empty and the sweep removes everything, which is the only lossy
  case and needs a torn rename, which APFS does not produce. Running any write twice rewrites
  identical bytes to the same name.
- Eviction, Clear, dedup. All three are manifest edits inside one actor transaction, so the
  file operations follow from the diff of the item list and cannot race the list. Clear is
  "items = []" then commit. Dedup never writes a second file because the name is the id.
  BarCut never deletes from the Screenshot Destination.
- `filePath` stays as `screenshotPath`, persisted, attached late when the pasteboard copy arrives
  before the file. It is a source fact for the user and for tests. Nothing in the app reads it
  for behavior, and it must not, because the user may move the file.
- Login item. `SMAppService.mainApp`. Toggle in a right-click menu on the status item, with
  "Quit" beside it. First launch registers automatically once, only when the bundle lives under
  `/Applications` and the status is `.notRegistered`, remembered by a UserDefaults flag so a
  user who turns it off stays off. Dev binaries and tests never register.

### What the interface hides

Callers see a list of entries and five commands. They do not see the manifest, the file names,
the hash, the thumbnail size, the pending retry loop, the pasteboard types, or the revision
guard. `ImageStore` is internal to the module and only the monitor talks to it. The public
surface is no larger than the old one. It gained `refresh` and `fullImage`, lost `copyAndFlash`
and the `image` field.

## Tradeoffs accepted

- We accept one actor transaction per event (manifest rewrite of a few hundred bytes) in
  exchange for never reasoning about list versus directory races.
- We accept about 70 ms of off-main work per ingest (decode, hash, thumbnail, write) in exchange
  for a main thread that never blocks and a correct cross-source identity.
- We accept 250 ms of thumbnail decoding after launch, off main, in exchange for not storing and
  syncing thumbnail files.
- We accept that TIFF on the pasteboard is promised, not written, in exchange for a 0.4 ms copy.
- We accept ~80 ms between Done in the editor and the durable copy landing on the pasteboard in
  exchange for one encode path. The live preview already put the same pixels there.
- We accept that a Screenshot taken in the last 70 ms before Clear can survive Clear in exchange
  for not adding a generation counter.
- We accept async test methods in exchange for tests that see settled state.

## Alternatives considered

- Keep the list as truth in the monitor, run heavy work on a serial `DispatchQueue`, persist as a
  side effect. Walked through it. An in-flight duplicate of an entry being evicted or cleared can
  land after the sweep deleted its file, leaving an entry with no PNG. Fixing it needs stat
  checks in apply plus a generation counter plus sweep ordering rules. The actor design deletes
  that whole class.
- One JSON sidecar per item and order by mtime, no manifest. Move to front becomes a touch, and
  attaching `screenshotPath` becomes a second file write. One atomic manifest is simpler.
- Persist thumbnails as `<id>.thumb.png`. Faster restore, twice the files, one more thing the
  sweep has to understand. Not worth it for 250 ms off main.
- Keep `writeObjects([NSImage])` for copy. 16.5 ms on main and a full decode per click.
- Launch at login toggle inside the popover header. The header is 280 pt with three items
  already. Menu bar apps put settings on right-click.

## Open questions and risks

- Pixel hash equality across sources depends on both paths landing in the same sRGB context.
  Screenshot PNGs carry Display P3. Verify with `scripts/bench.swift` that a screenshot file and
  its pasteboard TIFF hash the same. If they do not, fall back to hashing the CGImageSource's
  decoded bytes in the image's own colour space and accept a rare double entry.
- Promised TIFF is lost if BarCut quits before the consumer asks. Rare, and PNG is still there.
- Swift actors do not guarantee FIFO. The revision guard makes the final state correct, but a
  fast clipboard event could momentarily show ahead of a slower screenshot. Not visible at
  human speed.
- `SMAppService` with an ad hoc signature works for non-sandboxed apps but macOS shows a
  "Background Items Added" notification and ties the item to the bundle path. Moving the app
  breaks it until the next launch re-registers.
- If the store directory cannot be created, the store keeps the manifest in memory for the
  session and logs once. History then behaves like today.
- Pasteboard images that offer neither PNG nor TIFF (PDF only) are ignored. Today they are read
  through `NSImage`. Acceptable narrowing; name it in the changelog.

## Next implementation step

Write `ImageStore.swift` with `ingest`, `current`, `clear`, and the lazy load and sweep, plus the
store tests for relaunch, dedup, and orphan sweep, before touching the monitor.
