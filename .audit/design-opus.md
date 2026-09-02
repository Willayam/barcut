# BarCut persistence and performance design (opus runner)

## Problem

Four asks land on one type. `ClipboardMonitor` is the model, the file watcher, the clipboard poll,
the deduper, and the copier, all on the main thread, holding ten full-resolution `NSImage` values
that the popover redraws at full resolution on every row. Persistence is not a bolt-on here because
identity is the thing that has to persist, and today identity is a 60 ms PNG re-encode computed on
the main thread from an `NSImage` that may have arrived from either a file or the pasteboard. The
same screenshot from those two sources has different bytes, so file-byte hashing cannot satisfy
"Image History represents the same image once." Meanwhile the ADR forbids owning the screenshot
flow, so BarCut must keep a second copy of every image it shows, which turns every ingest into a
write that can be interrupted. The shape has to make identity stable across sources, move every
expensive step off the main actor, keep the popover cheap enough to open instantly, and converge at
startup on whatever a kill left behind, without a manifest that can disagree with the files next to
it.

## Usage (caller's view)

`AppDelegate` builds the model, defers the popover, and registers the login item once.

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let history = ImageHistory()          // sync: changeCount + dir snapshot, nothing else
    private var popover: NSPopover?               // built on first open, not at launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        LoginItem.registerOnFirstLaunch()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        let popover = popover ?? makePopover()
        popover.isShown ? popover.performClose(nil) : popover.show(...)
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.contentViewController = NSHostingController(
            rootView: ImageHistoryView(history: history) { [weak self] id, tool in
                Task { @MainActor in
                    guard let image = await self?.history.fullImage(for: id) else { return }
                    self?.openAnnotationEditor(image: image, initialTool: tool)
                }
            }
        )
        popover = p
        return p
    }
}
```

The annotation editor is unchanged. Its two callbacks become awaits.

```swift
onPreviewChanged: { [weak self] rendered in
    Task { await self?.history.copyLiveAnnotatedImage(rendered) }
},
onComplete: { [weak self, weak window] rendered in
    Task { await self?.history.addAnnotatedImage(rendered) }   // persists, dedups, copies, flashes
    window?.close()
}
```

`ImageHistoryView` renders thumbnails and never sees a full-resolution image.

```swift
ForEach(history.entries) { entry in
    ImageHistoryRow(
        thumbnail: entry.thumbnail,                     // 560 px, already in memory
        isCopied: history.lastCopiedID == entry.id,
        onCopy: { Task { await history.copy(entry.id) } },
        onAnnotate: { tool in onAnnotate(entry.id, tool) }
    )
}
```

Header keeps `Clear` and moves `Quit` into an ellipsis menu that also owns the login toggle.

```swift
Menu { Toggle("Open at Login", isOn: $loginEnabled); Divider(); Button("Quit") { ... } }
    label: { Image(systemName: "ellipsis") }
```

Tests keep injecting directories and calling the scan. The scan becomes awaitable, and awaiting it
means every readable file in the destination has landed in `entries`.

```swift
func testImportsReadableScreenshotFromObservedDestination() async throws {
    let history = ImageHistory(screenshotDir: dir.path, storageDir: store.path,
                               pollClipboard: false, watchScreenshots: false)
    try validPNGData().write(to: dir.appendingPathComponent("Screenshot.png"))
    await history.scanScreenshotDestination()
    XCTAssertEqual(history.entries.count, 1)
}
```

## Shape

### Types

```swift
/// sha256 over canonical RGBA8 sRGB pixels. Constructible only by the hasher, so no caller
/// can invent one (the old `?? UUID().uuidString` fallback is gone).
struct Fingerprint: Hashable, Sendable, CustomStringConvertible {
    private let hex: String
    fileprivate init(hex: String) { self.hex = hex }
    init?(filename: String) { fatalError("not implemented") }   // disk boundary, validates
    var description: String { hex }
}

/// A readable image. Non-optional thumbnail is the type-level statement of
/// "Image History contains readable images only."
struct ImageHistoryEntry: Identifiable, @unchecked Sendable {
    let id: Fingerprint
    let sequence: Int          // total recency order, higher is newer
    let thumbnail: NSImage     // ~560 px, immutable after construction
    let pixelSize: CGSize
    var filePath: String?      // in-memory only source fact, see below
}
```

### Files

- `Sources/BarCut/ImageHistory.swift`. `@MainActor final class ImageHistory: ObservableObject`.
  Replaces `ClipboardMonitor.swift`. Owns published state, the `DispatchSource` watcher, the 1 s
  clipboard poll, the pending-screenshot retry loop, pasteboard reads and writes.
- `Sources/BarCut/HistoryStore.swift`. `actor HistoryStore`. The only code that touches the
  storage directory or does pixel work. Hash, encode, thumbnail, write, promote, evict, load.
- `Sources/BarCut/ImageHistoryView.swift`. Thumbnails, ellipsis menu, `private enum LoginItem`
  at the bottom of the file.
- `Sources/BarCut/BarCutApp.swift`. Lazy popover, async annotate.

```swift
@MainActor final class ImageHistory: ObservableObject {
    @Published private(set) var entries: [ImageHistoryEntry] = []
    @Published private(set) var lastCopiedID: Fingerprint?

    init(screenshotDir: String? = nil, storageDir: String? = nil,
         maxItems: Int = 10, pollClipboard: Bool = true, watchScreenshots: Bool = true)

    func scanScreenshotDestination() async
    func copy(_ id: Fingerprint) async
    func fullImage(for id: Fingerprint) async -> NSImage?
    func addAnnotatedImage(_ image: NSImage) async
    func copyLiveAnnotatedImage(_ image: NSImage) async
    func clear() async
}

actor HistoryStore {
    enum Ingest { case inserted(ImageHistoryEntry), promoted(ImageHistoryEntry) }
    func load(limit: Int) -> [ImageHistoryEntry]        // also sweeps, see restore
    func ingest(_ image: NSImage, maxItems: Int) -> Ingest?
    func pngData(for id: Fingerprint) -> Data?
    func fullImage(for id: Fingerprint) -> NSImage?
    func clear()
}
```

### On-disk layout: the directory is the database

```
~/Library/Application Support/BarCut/history/     ($BARCUT_STORAGE_DIR overrides)
  000000041-3f2a9c….png          full-resolution PNG, published by atomic rename
  000000041-3f2a9c….thumb.jpg    derived cache, never load-bearing
  .tmp-<uuid>                    in-flight write, swept at startup
```

No manifest. Order lives in the zero-padded sequence prefix, identity lives in the fingerprint
suffix, and existence of the `.png` is the only fact that matters. One source of truth, so there is
nothing to reconcile. Writes go to `.tmp-<uuid>` then `rename(2)`, which is atomic on APFS, so a
kill mid-write leaves a temp file and no half-entry. Promotion on dedup is a rename to a higher
sequence, not a re-encode.

### Identity

Fingerprint is a sha256 over the image drawn into a fixed RGBA8 sRGB bitmap at pixel dimensions,
with width and height mixed in. 35 ms per the bench, always off the main actor. File bytes are
rejected because the same screenshot arriving as a file and as a pasteboard image must collapse to
one entry, and byte hashes cannot do that. The shipped tiff-to-png-to-sha256 is rejected because it
costs 60 ms and depends on encoder determinism we do not control.

### Memory at rest

Thumbnails only. Ten 560 px thumbnails is about 7 MB against the 330 MB of decoded bitmaps the
popover holds today. Full-resolution images are never resident. `fullImage(for:)` decodes from disk
on demand for the annotation editor, 9.5 ms off the main actor. The store owns loading; nothing
else opens a file.

### Threading

Main actor holds `ImageHistory` and every published mutation. `HistoryStore` is an actor, so hash,
encode, thumbnail, and write all run off main and, being serial, need no lock for the sequence
counter and cannot interleave two writes of the same fingerprint. Results cross back as returned
values that the main actor splices into `entries`. The `DispatchSource` handler and the poll timer
fire on main and immediately hand off to a `Task`. Copy is `let data = await store.pngData(for:)`
then a single main-actor block that writes the pasteboard and updates `lastChangeCount` together,
so the poll can never observe our own copy as a new Clipboard Image.

Copy writes PNG eagerly with `setData(_:forType: .png)` (0.4 ms) and promises `.tiff` through a
lazy pasteboard provider that decodes only if some app asks. That replaces `writeObjects([NSImage])`
at 16.5 ms while keeping both types available.

### Restore order at launch

1. Synchronously on main in `init`, read `NSPasteboard.general.changeCount` and snapshot the
   Screenshot Destination into `knownFiles`. These two reads are the entire guarantee that images
   from while BarCut was quit are not imported, so nothing may ingest before they finish.
2. `Task { entries = await store.load(limit: maxItems) }`. Load sweeps `.tmp-*`, deletes thumbnails
   with no matching PNG, keeps the ten highest sequences and deletes the rest, regenerates any
   missing thumbnail, and seeds the sequence counter to max + 1.
3. Only after that lands, start the watcher and the poll timer. The watcher scans once on start, so
   a screenshot that appeared during restore is still found, and it gets a higher sequence than any
   restored entry, which puts it at the front where it belongs.

### Crash safety and idempotency

Every startup path converges. Running an ingest twice is a no-op because the store looks for an
existing file with that fingerprint before writing and returns `.promoted` instead. A kill between
the PNG rename and the thumbnail write leaves an entry whose thumbnail regenerates on next load. A
kill between the two renames of a promotion leaves an orphan thumbnail that the sweep deletes.

### Eviction, Clear, and files

Eviction past ten deletes the lowest-sequence PNG and thumbnail. Clear empties `entries` and
deletes every file in the storage directory. BarCut never deletes, moves, or writes anything in the
Screenshot Destination, in either path. Dedup promotes in place and touches no bytes.

### filePath

It stays as an in-memory field and is not persisted. Nothing in the app reads it today; the tests
assert on it and CONTEXT says an item may gain source facts after it appears, so the field earns
its place for the session. Persisting it would need a second file or an xattr, which would buy a
fact no code consumes. A restored entry has `filePath == nil`, which is honest.

### What the interface hides

Six methods and two read-only published properties. Callers cannot see the store, the sequence
counter, the fingerprint algorithm, the thumbnail pipeline, the watcher, the poll, eviction, or
restore. `entries` becomes `private(set)`, so the array order invariant cannot be broken from
outside. Nothing smaller works: each method is a complete user action, and there is no load, save,
or validate step a caller has to sequence.

## Tradeoffs accepted

- We accept an async boundary in the test-facing API in exchange for every expensive step leaving
  the main actor. Three tests gain `async` and three `await`s.
- We accept storing a second full-resolution PNG per entry, up to a few MB, in exchange for
  honoring the ADR and never touching the Screenshot Destination.
- We accept a directory listing at load instead of one manifest read in exchange for deleting the
  entire manifest-versus-files reconciliation problem.
- We accept regenerating a thumbnail after an unlucky crash in exchange for the thumbnail never
  being load-bearing for correctness.
- We accept 35 ms of pixel hashing per ingest in exchange for one entry per image across sources.
- We accept `@unchecked Sendable` on the entry, justified by the images being immutable after the
  store constructs them, in exchange for not copying bitmaps across the actor boundary.
- We accept registering the login item once on first launch in exchange for the reboot behavior the
  user asked for. A UserDefaults flag means we never re-register after the user turns it off.

## Alternatives considered

**Manifest plus content-addressed blobs.** `history.json` rewritten atomically after every change,
blobs named by fingerprint. This is the conventional shape and it loses because it creates two
sources of truth that drift. Every startup then needs reconciliation in both directions, entries
whose blob vanished and blobs no entry references, and every ingest pays a full manifest rewrite to
record an ordering change that a rename expresses for free. The sequence prefix carries the exact
information the manifest existed to carry.

**Keep full images resident, persist only paths.** Cheapest diff, and it fails the memory ask
outright. The popover still decodes 330 MB and still spends 57 ms per row.

**A `@ModelActor` or Core Data store.** Rejected. New dependency in spirit, migration surface, and
the data is ten rows of three fields.

## Open questions and risks

- Lazy `.tiff` pasteboard promises require the provider to outlive the copy and a live runloop.
  Some apps read the pasteboard after the promising app changes state. If any real app misbehaves,
  fall back to writing TIFF eagerly and take the 16 ms.
- The synchronous directory snapshot in `init` is on the main thread by design. A Desktop with tens
  of thousands of files could make it visible at launch. Measure before deciding to move it.
- `SMAppService.mainApp` needs the real bundle, so login-at-launch is untestable from `swift test`
  and needs the verification script against `/Applications/BarCut.app`.
- Ad hoc signing means the bundle identity changes on every rebuild, which may make macOS treat the
  login item registration as new. Worth checking during verification.
- JPEG thumbnails at 560 px on dense text screenshots. Visually fine at 156 pt, but confirm on a
  code screenshot before committing to JPEG over PNG thumbnails.

## Next implementation step

Write `HistoryStore` with `load`, `ingest`, and `clear`, plus a test that ingests the same image
twice and asserts one PNG on disk with a promoted sequence.
