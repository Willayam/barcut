import AppKit
import Combine
import CryptoKit

struct ImageHistoryEntry: Identifiable {
    let id: String
    var image: NSImage
    var filePath: String?
}

private struct PendingScreenshot {
    let url: URL
    let creationDate: Date
    let firstObservedAt: Date
}

final class ClipboardMonitor: ObservableObject {
    @Published var images: [ImageHistoryEntry] = []
    @Published var lastCopiedID: ImageHistoryEntry.ID? = nil

    private var lastChangeCount: Int
    private var clipboardCancellable: AnyCancellable?
    private let maxItems: Int
    private var knownFiles: Set<String> = []
    let screenshotDir: String
    private var pendingScreenshots: [String: PendingScreenshot] = [:]
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var directorySource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private let pendingRetryInterval: TimeInterval = 0.25
    private let pendingScreenshotTimeout: TimeInterval = 5.0

    init(
        screenshotDir: String? = nil,
        maxItems: Int = 10,
        pollClipboard: Bool = true,
        watchScreenshots: Bool = true
    ) {
        self.maxItems = maxItems
        lastChangeCount = NSPasteboard.general.changeCount

        // Detect screenshot directory (in-process read, no subprocess)
        let customDir = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        self.screenshotDir = screenshotDir ?? ((customDir?.isEmpty == false) ? customDir! : NSHomeDirectory() + "/Desktop")

        snapshotExistingFiles()

        // Clipboard polling (no OS API for this)
        if pollClipboard {
            clipboardCancellable = Timer.publish(every: 1.0, tolerance: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.checkClipboard() }
        }

        // Watch screenshot folder (event-driven)
        if watchScreenshots {
            watchScreenshotFolder()
        }
    }

    deinit {
        pendingRetryWorkItem?.cancel()
        directorySource?.cancel()
        if dirFD >= 0 { close(dirFD) }
    }

    private func watchScreenshotFolder() {
        dirFD = open(screenshotDir, O_EVTONLY)
        guard dirFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scanScreenshotDestination()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }

        source.resume()
        directorySource = source
    }

    func scanScreenshotDestination() {
        discoverPendingScreenshots()
        importReadablePendingScreenshots()
        schedulePendingRetryIfNeeded()
    }

    private func discoverPendingScreenshots() {
        let url = URL(fileURLWithPath: screenshotDir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return }

        for file in contents where isImageFile(file) {
            guard !knownFiles.contains(file.path),
                  pendingScreenshots[file.path] == nil else { continue }

            let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            pendingScreenshots[file.path] = PendingScreenshot(
                url: file,
                creationDate: date,
                firstObservedAt: Date()
            )
        }
    }

    private func importReadablePendingScreenshots() {
        let now = Date()
        var readyScreenshots: [(url: URL, date: Date, image: NSImage)] = []

        for (path, pending) in pendingScreenshots {
            guard FileManager.default.fileExists(atPath: path) else {
                pendingScreenshots.removeValue(forKey: path)
                continue
            }

            if let image = NSImage(contentsOf: pending.url) {
                knownFiles.insert(path)
                pendingScreenshots.removeValue(forKey: path)
                readyScreenshots.append((url: pending.url, date: pending.creationDate, image: image))
            } else if now.timeIntervalSince(pending.firstObservedAt) >= pendingScreenshotTimeout {
                knownFiles.insert(path)
                pendingScreenshots.removeValue(forKey: path)
            }
        }

        readyScreenshots.sort { $0.date > $1.date }

        for screenshot in readyScreenshots {
            addImage(screenshot.image, filePath: screenshot.url.path, autoCopy: false)
        }
    }

    private func schedulePendingRetryIfNeeded() {
        pendingRetryWorkItem?.cancel()
        guard !pendingScreenshots.isEmpty else {
            pendingRetryWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingRetryWorkItem = nil
            self?.scanScreenshotDestination()
        }
        pendingRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingRetryInterval, execute: workItem)
    }

    private func snapshotExistingFiles() {
        let url = URL(fileURLWithPath: screenshotDir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }
        for file in contents where isImageFile(file) {
            knownFiles.insert(file.path)
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "tiff"].contains(url.pathExtension.lowercased())
    }

    func imageFromClipboard() -> NSImage? {
        let pasteboard = NSPasteboard.general
        guard let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil),
              let image = objects.first as? NSImage else { return nil }
        return image
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard let image = imageFromClipboard() else { return }
        addImage(image, filePath: nil, autoCopy: false)
    }

    @discardableResult
    private func addImage(_ image: NSImage, filePath: String?, autoCopy: Bool) -> ImageHistoryEntry? {
        let id = imageFingerprint(image) ?? UUID().uuidString

        if let existingIndex = images.firstIndex(where: { $0.id == id }) {
            var entry = images.remove(at: existingIndex)
            if let filePath {
                entry.filePath = filePath
            }
            images.insert(entry, at: 0)

            if autoCopy {
                copyToClipboard(entry.image)
                flashCopied(id: entry.id)
            }
            return entry
        }

        let entry = ImageHistoryEntry(id: id, image: image, filePath: filePath)
        images.insert(entry, at: 0)
        if images.count > maxItems {
            images.removeLast(images.count - maxItems)
        }

        if autoCopy {
            copyToClipboard(image)
            flashCopied(id: entry.id)
        }

        return entry
    }

    func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        lastChangeCount = pasteboard.changeCount
    }

    func copyAndFlash(_ entry: ImageHistoryEntry) {
        copyToClipboard(entry.image)
        flashCopied(id: entry.id)
    }

    func addAnnotatedImage(_ image: NSImage) {
        addImage(image, filePath: nil, autoCopy: true)
    }

    func copyLiveAnnotatedImage(_ image: NSImage) {
        copyToClipboard(image)
    }

    private func flashCopied(id: ImageHistoryEntry.ID) {
        lastCopiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.lastCopiedID == id {
                self?.lastCopiedID = nil
            }
        }
    }

    func clearHistory() {
        images.removeAll()
        lastCopiedID = nil
    }

    private func imageFingerprint(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation else { return nil }

        if let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return sha256Hex(png)
        }

        return sha256Hex(tiff)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
