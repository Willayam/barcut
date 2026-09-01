import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

private struct PendingScreenshot {
    let url: URL
    let creationDate: Date
    let firstObservedAt: Date
}

/// TIFF is encoded only if a consumer asks for it; PNG is already on the pasteboard.
private final class TIFFPromise: NSObject, NSPasteboardItemDataProvider {
    private let pngData: Data

    init(pngData: Data) {
        self.pngData = pngData
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let tiff = ImageStore.encode(image, type: UTType.tiff.identifier) else { return }
        item.setData(tiff, forType: .tiff)
    }
}

@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published private(set) var images: [ImageHistoryEntry] = []
    @Published private(set) var lastCopiedID: ImageID?

    let screenshotDir: String

    private let store: ImageStore
    private var appliedRevision = -1
    private var lastChangeCount: Int
    private var clipboardCancellable: AnyCancellable?
    private var knownFiles: Set<String> = []
    private var pendingScreenshots: [String: PendingScreenshot] = [:]
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var directorySource: DispatchSourceFileSystemObject?
    private var tiffPromise: TIFFPromise?
    private let pendingRetryInterval: TimeInterval = 0.25
    private let pendingScreenshotTimeout: TimeInterval = 5.0

    init(
        screenshotDir: String? = nil,
        storeDir: String? = nil,
        maxItems: Int = 10,
        pollClipboard: Bool? = nil,
        watchScreenshots: Bool = true
    ) {
        let environment = ProcessInfo.processInfo.environment
        let customScreenshotDir = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let resolvedScreenshotDir = screenshotDir
            ?? environment["BARCUT_SCREENSHOT_DIR"]
            ?? ((customScreenshotDir?.isEmpty == false) ? customScreenshotDir! : NSHomeDirectory() + "/Desktop")
        let defaultStoreDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarCut/History", isDirectory: true)
        let resolvedStoreDir = storeDir.map(URL.init(fileURLWithPath:))
            ?? environment["BARCUT_STORE_DIR"].map(URL.init(fileURLWithPath:))
            ?? defaultStoreDir
        let shouldPollClipboard = pollClipboard ?? (environment["BARCUT_POLL_CLIPBOARD"] != "0")

        self.screenshotDir = resolvedScreenshotDir
        store = ImageStore(directory: resolvedStoreDir, maxItems: maxItems)
        lastChangeCount = NSPasteboard.general.changeCount

        snapshotExistingFiles()
        if shouldPollClipboard {
            clipboardCancellable = Timer.publish(every: 0.5, tolerance: 0.2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    Task { @MainActor in
                        await self?.checkClipboard()
                    }
                }
        }
        if watchScreenshots {
            watchScreenshotFolder()
        }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    deinit {
        pendingRetryWorkItem?.cancel()
        directorySource?.cancel()
    }

    func refresh() async {
        apply(await store.current())
    }

    func scanScreenshotDestination() async {
        discoverPendingScreenshots()
        let pending = pendingScreenshots.values.sorted { $0.creationDate < $1.creationDate }
        let now = Date()

        for screenshot in pending {
            let path = screenshot.url.path
            guard FileManager.default.fileExists(atPath: path) else {
                pendingScreenshots.removeValue(forKey: path)
                continue
            }

            if let snapshot = await store.ingest(.screenshotFile(screenshot.url), screenshotPath: path) {
                knownFiles.insert(path)
                pendingScreenshots.removeValue(forKey: path)
                apply(snapshot)
            } else if now.timeIntervalSince(screenshot.firstObservedAt) >= pendingScreenshotTimeout {
                knownFiles.insert(path)
                pendingScreenshots.removeValue(forKey: path)
            }
        }

        schedulePendingRetryIfNeeded()
    }

    func copy(_ entry: ImageHistoryEntry) {
        Task { [weak self] in
            guard let self, let pngData = await self.store.pngData(for: entry.id) else { return }
            self.writeToPasteboard(pngData)
            self.flashCopied(id: entry.id)
        }
    }

    func fullImage(for entry: ImageHistoryEntry) async -> NSImage? {
        guard let image = await store.fullImage(for: entry.id) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func addAnnotatedImage(_ image: NSImage) {
        guard let rendered = cgImage(from: image) else { return }
        Task { [weak self] in
            guard let self,
                  let snapshot = await self.store.ingest(.rendered(rendered), screenshotPath: nil) else { return }
            self.apply(snapshot)
            guard let entry = snapshot.entries.first else { return }
            self.copy(entry)
        }
    }

    func copyLiveAnnotatedImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        lastChangeCount = pasteboard.changeCount
    }

    func clearHistory() {
        Task { [weak self] in
            guard let self else { return }
            self.apply(await self.store.clear())
            self.lastCopiedID = nil
        }
    }

    private func watchScreenshotFolder() {
        let descriptor = open(screenshotDir, O_EVTONLY)
        guard descriptor >= 0 else {
            historyLogger.notice("watch failed \(self.screenshotDir, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.scanScreenshotDestination()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func discoverPendingScreenshots() {
        let directory = URL(fileURLWithPath: screenshotDir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        for file in contents where isImageFile(file) {
            guard !knownFiles.contains(file.path), pendingScreenshots[file.path] == nil else { continue }
            let creationDate = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            pendingScreenshots[file.path] = PendingScreenshot(
                url: file,
                creationDate: creationDate,
                firstObservedAt: Date()
            )
        }
    }

    private func schedulePendingRetryIfNeeded() {
        pendingRetryWorkItem?.cancel()
        guard !pendingScreenshots.isEmpty else {
            pendingRetryWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.pendingRetryWorkItem = nil
                await self?.scanScreenshotDestination()
            }
        }
        pendingRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingRetryInterval, execute: workItem)
    }

    private func snapshotExistingFiles() {
        let directory = URL(fileURLWithPath: screenshotDir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }
        knownFiles = Set(contents.filter(isImageFile).map(\.path))
    }

    private func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "tiff"].contains(url.pathExtension.lowercased())
    }

    private func checkClipboard() async {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if let pngData = pasteboard.data(forType: .png),
           let snapshot = await store.ingest(.pasteboard(pngData, isPNG: true), screenshotPath: nil) {
            apply(snapshot)
        } else if let tiffData = pasteboard.data(forType: .tiff),
                  let snapshot = await store.ingest(.pasteboard(tiffData, isPNG: false), screenshotPath: nil) {
            apply(snapshot)
        }
    }

    private func writeToPasteboard(_ pngData: Data) {
        let promise = TIFFPromise(pngData: pngData)
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setDataProvider(promise, forTypes: [.tiff])
        tiffPromise = promise

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
    }

    private func apply(_ snapshot: Snapshot) {
        guard snapshot.revision > appliedRevision else { return }
        appliedRevision = snapshot.revision
        images = snapshot.entries
    }

    private func flashCopied(id: ImageID) {
        lastCopiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.lastCopiedID == id {
                self?.lastCopiedID = nil
            }
        }
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
