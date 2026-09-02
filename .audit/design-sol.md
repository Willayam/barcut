## 1. Problem

BarCut must persist one visual image across several encodings without delaying the main actor or changing Standard Screenshot Behavior. That makes the design less obvious than saving each incoming `NSImage`. A screenshot may arrive after a Clipboard Image with the same pixels, then add a Screenshot Destination path to the existing item. The app must also restore ten items, preserve their order, ignore screenshots created while it was quit, survive interrupted writes, provide full resolution on demand, and show thumbnails without decoding every full image.

## 2. Usage (caller's view)

`AppDelegate` starts the model and asks it for a full image only when annotation begins. The login controller registers the packaged app on first launch.

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let history = ImageHistory(configuration: .live)
    private let loginItem = LaunchAtLoginController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        loginItem.registerOnFirstPackagedLaunch()

        Task {
            await history.start()
        }

        let view = ImageHistoryView(
            history: history,
            loginItem: loginItem
        ) { [weak self] id, tool in
            Task {
                guard let image = await self?.history.fullResolutionImage(for: id) else {
                    return
                }
                self?.openAnnotationEditor(image: image, initialTool: tool)
            }
        }

        // Install view in the existing popover.
    }

    private func openAnnotationEditor(
        image: NSImage,
        initialTool: AnnotationTool
    ) {
        let editor = AnnotationEditorView(
            image: image,
            initialTool: initialTool,
            onPreviewChanged: { [history] image in
                history.copyLiveAnnotatedImage(image)
            },
            onComplete: { [history] image in
                history.addAnnotatedImage(image, copy: true)
            },
            onCancel: {}
        )

        // Install editor in the existing window.
    }
}
```

`ImageHistoryView` receives thumbnails and stable IDs. It never loads files or handles pasteboard formats.

```swift
ForEach(history.items) { item in
    ImageHistoryRow(
        image: item.thumbnail,
        isCopied: history.lastCopiedID == item.id,
        onCopy: {
            history.copy(item.id)
        },
        onAnnotate: { tool in
            onAnnotate(item.id, tool)
        }
    )
}

Menu {
    Toggle(
        "Launch at Login",
        isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    )

    Button("Clear Image History") {
        history.clear()
    }

    Button("Quit") {
        NSApplication.shared.terminate(nil)
    }
} label: {
    Image(systemName: "gearshape")
}
```

Tests await the worker directly. They need no timer or running directory watcher.

```swift
@MainActor
func testImportsReadableScreenshot() async throws {
    let history = ImageHistory(
        configuration: HistoryConfiguration(
            screenshotDirectory: screenshotDirectory,
            storageDirectory: storageDirectory,
            maxItems: 10,
            pollClipboard: false,
            watchScreenshots: false
        )
    )

    await history.start()
    try validPNGData().write(to: screenshotURL)
    await history.scanScreenshotDestination()

    XCTAssertEqual(history.items.count, 1)
    XCTAssertEqual(
        history.items[0].sourceFacts.screenshotPaths,
        [screenshotURL.path]
    )
}
```

## 3. Shape

Data structures come first.

```swift
import AppKit
import CryptoKit

struct ImageFingerprint: Hashable, Codable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("v1_"), rawValue.count == 67 else {
            return nil
        }
        self.rawValue = rawValue
    }
}

struct ImageSourceFacts: Codable, Equatable, Sendable {
    var screenshotPaths: Set<String> = []
}

struct ImageHistoryEntry: Identifiable {
    let id: ImageFingerprint
    let thumbnail: NSImage
    let pixelSize: CGSize
    let sourceFacts: ImageSourceFacts
}

struct HistoryConfiguration: Sendable {
    let screenshotDirectory: URL
    let storageDirectory: URL
    let maxItems: Int
    let pollClipboard: Bool
    let watchScreenshots: Bool

    static var live: Self {
        fatalError("not implemented")
    }
}

private struct HistoryManifest: Codable, Sendable {
    let version: Int
    var entries: [Record]

    struct Record: Codable, Sendable {
        let id: ImageFingerprint
        var lastObservedAt: Date
        var pixelWidth: Int
        var pixelHeight: Int
        var sourceFacts: ImageSourceFacts
    }
}

private enum ImageInput: Sendable {
    case encoded(Data)
    case file(URL)
    case rendered(RenderedImage)
}

private struct RenderedImage: @unchecked Sendable {
    // CGImage is immutable. This wrapper documents the cross-queue handoff.
    let cgImage: CGImage
}

private struct StoreSnapshot: Sendable {
    let revision: UInt64
    let entries: [StoredEntry]
}

private struct StoredEntry: Sendable {
    let record: HistoryManifest.Record
    let decodedThumbnail: RenderedImage
}
```

The main model has one command interface.

```swift
@MainActor
final class ImageHistory: ObservableObject {
    @Published private(set) var items: [ImageHistoryEntry] = []
    @Published private(set) var lastCopiedID: ImageFingerprint?

    init(configuration: HistoryConfiguration) {
        fatalError("not implemented")
    }

    func start() async {
        fatalError("not implemented")
    }

    func scanScreenshotDestination() async {
        fatalError("not implemented")
    }

    func copy(_ id: ImageFingerprint) {
        // TODO: Ask the store for PNG and TIFF pasteboard data.
    }

    func fullResolutionImage(
        for id: ImageFingerprint
    ) async -> NSImage? {
        fatalError("not implemented")
    }

    func addAnnotatedImage(_ image: NSImage, copy: Bool) {
        // TODO: Capture an immutable CGImage and submit it to the worker.
    }

    func copyLiveAnnotatedImage(_ image: NSImage) {
        // TODO: Encode off the main actor, then write both pasteboard types.
    }

    func clear() {
        // TODO: Publish empty state and enqueue a durable clear.
    }
}
```

`ImageHistoryStore` owns one serial `DispatchQueue` with user-initiated quality of service. It owns the manifest, revisions, known Screenshot Destination paths, Pending Screenshots, retry deadlines, decoding, pixel normalization, hashing, thumbnails, and file writes. No other type mutates that state.

The main actor owns published state and all `NSPasteboard` access. Clipboard polling reads `changeCount` and encoded PNG or TIFF data on the main actor. The store performs decoding, hashing, thumbnail creation, TIFF conversion, and persistence. It returns immutable values. The main actor ignores any snapshot whose revision is older than the last applied revision.

The store normalizes every readable input to oriented, unpremultiplied RGBA8 pixels in sRGB. It hashes the width, height, and exact row bytes with SHA-256. The ID uses the `v1_` prefix so a later normalization change cannot silently merge incompatible identities. File-byte hashes lose because PNG, TIFF, and JPEG encodings of the same pixels differ.

The on-disk layout is:

```text
Application Support/com.williamlarsten.BarCut/ImageHistory/v1/
  manifest.json
  images/
    v1_<sha256>.png
  thumbnails/
    v1_<sha256>.png
```

`manifest.json` stores records newest first. The canonical PNG preserves full-resolution pixels. The thumbnail is an eager 560-pixel ImageIO thumbnail sized for the existing two-times display row. At rest, memory holds metadata and decoded thumbnails only. An annotation window owns its requested full image until that window closes. Copy reads the canonical PNG without creating a full `NSImage`.

A copy operation prepares PNG and TIFF data on the worker. The main actor creates one `NSPasteboardItem`, sets both `.png` and `.tiff`, writes it, and records the new `changeCount`. This prevents BarCut from ingesting its own copy.

`sourceFacts.screenshotPaths` replaces `filePath`. The store merges paths when a matching Screenshot later appears. It never loads the history image from those paths. BarCut's canonical PNG remains valid if the original Screenshot moves or disappears.

Startup uses this order:

1. Capture the current pasteboard `changeCount`.
2. Take Screenshot Destination snapshot A on the worker.
3. Restore and repair the manifest on the worker.
4. Publish the restored thumbnails on the main actor.
5. Start the directory watcher.
6. Take snapshot B and import readable files in B minus A.
7. Start clipboard polling from the captured change count.

A file created between snapshots appears in B and enters Image History. Files already present in snapshot A stay excluded. Directory events that arrive during restore enqueue another scan after snapshot B.

Each ingest records its boundary observation time. Dedup keeps the later time, merges source facts, and moves the record to the front. Worker completion time never decides order.

A new item writes its canonical PNG and thumbnail to sibling temporary files, then atomically renames them. The store writes the new manifest last through the same temporary-file replacement. Repeating the operation writes the same content-addressed names and reaches the same state.

Eviction first commits a manifest containing at most `maxItems`, then deletes files no longer referenced. A crash before the manifest replacement retains the old history. A crash after it leaves harmless orphan files. Startup removes those orphans.

Restore rejects malformed records and unreadable canonical images. It regenerates missing or invalid thumbnails. It removes duplicate IDs, applies the item limit, rewrites a repaired manifest, and deletes unreferenced files.

Clear commits an empty manifest before deleting BarCut's image and thumbnail files. It never deletes files from the Screenshot Destination. Startup finishes deletion if the app dies during Clear.

`HistoryConfiguration.live` reads normal system locations. It also honors `BARCUT_STORAGE_DIRECTORY`, `BARCUT_SCREENSHOT_DIRECTORY`, `BARCUT_POLL_CLIPBOARD`, and `BARCUT_WATCH_SCREENSHOTS` for verification.

`LaunchAtLoginController` lives beside `AppDelegate` in `BarCutApp.swift`. It uses `SMAppService.mainApp`. The gear menu owns the toggle. The controller registers automatically on the first launch from a real `.app` bundle. It records an explicit disable choice in `UserDefaults` and never registers again against that choice. Tests and direct SwiftPM runs skip registration.

The module map is small:

```text
Sources/BarCut/ImageHistory.swift
  ImageHistory, entries, configuration, source monitoring, pasteboard boundary

Sources/BarCut/ImageHistoryStore.swift
  Manifest, normalization, fingerprinting, thumbnails, persistence, repair

Sources/BarCut/ImageHistoryView.swift
  Thumbnail rows, Clear, gear menu, login toggle

Sources/BarCut/BarCutApp.swift
  AppDelegate, LaunchAtLoginController, annotation image loading

Sources/BarCut/AnnotationEditorView.swift
  Existing editor callbacks only

Tests/BarCutTests/ImageHistoryTests.swift
  Restore, dedup, pending files, crash states, eviction, Clear, source facts
```

This replaces `ClipboardMonitor.swift` rather than wrapping it. The public interface hides retries, watcher state, file layout, persistence order, pasteboard encodings, and revisions. Callers can start, copy, request a full image, add an Annotated Image, or clear. They cannot coordinate internal phases incorrectly.

## 4. Tradeoffs accepted

- We accept a second thumbnail file per item in exchange for opening the popover without full-image decoding.
- We accept short queueing on one serial worker in exchange for deterministic recency and simple recovery.
- We accept normalized sRGB pixels in exchange for dedup across file and pasteboard encodings.
- We accept an async delay when annotation opens in exchange for keeping full images out of idle memory.
- We accept automatic login registration on the first packaged launch in exchange for meeting the reboot requirement without setup.
- We accept retained Screenshot Destination paths in the manifest in exchange for preserving source facts when duplicate inputs merge.

## 5. Alternatives considered

A SQLite database could store records, thumbnails, and full images in transactional blobs. It lost because ten items do not justify a database wrapper, migrations, blob-copy behavior, and extra failure paths. Content-addressed files plus one atomic manifest provide the needed transaction boundary and remain easy to inspect.

A directory per item with modification dates as ordering metadata would avoid a manifest. It lost because dedup, source-fact updates, Clear, and multi-item eviction would span unrelated file operations. Startup could observe an order that never existed before the crash.

Keeping full `NSImage` values in published state would require the smallest code change. It lost because ten decoded screenshots can consume about 330 MB and make the popover decode every row.

## 6. Open questions and risks

- Pixel normalization needs golden tests for orientation, color profiles, transparency, PNG, TIFF, JPEG, and pasteboard input. The hash contract must not change accidentally.
- `NSImage` to immutable `CGImage` capture may still trigger work on the main actor for unusual lazy images. Clipboard and restored inputs avoid this path by carrying encoded data.
- The current annotation renderer draws full-resolution output on the main actor. The history redesign removes its repeated storage and copy costs, but annotation rendering needs a separate measured pass if it still causes stalls.
- `SMAppService.mainApp` cannot be proved from the SwiftPM test executable. A packaged-app verification must cover first registration, disable, relaunch, and registration failure.
- Atomic replacement protects against process death. It does not promise recovery from external file edits or disk hardware corruption.

## 7. Next implementation step

Implement `ImageHistoryStore` with restore, ingest, dedup, eviction, and interrupted-write tests before connecting it to the UI.