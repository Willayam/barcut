import AppKit
import Combine
import CryptoKit

struct ImageHistoryEntry: Identifiable {
    let id: String
    var image: NSImage
    var filePath: String?
}

final class ClipboardMonitor: ObservableObject {
    @Published var images: [ImageHistoryEntry] = []
    @Published var lastCopiedID: ImageHistoryEntry.ID? = nil

    private var lastChangeCount: Int
    private var clipboardCancellable: AnyCancellable?
    private let maxItems = 10
    private var knownFiles: Set<String> = []
    let screenshotDir: String
    private var directorySource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var capturing = false

    init() {
        lastChangeCount = NSPasteboard.general.changeCount

        // Detect screenshot directory (in-process read, no subprocess)
        let customDir = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        screenshotDir = (customDir?.isEmpty == false) ? customDir! : NSHomeDirectory() + "/Desktop"

        snapshotExistingFiles()

        // Clipboard polling (no OS API for this)
        clipboardCancellable = Timer.publish(every: 1.0, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkClipboard() }

        // Watch screenshot folder (event-driven)
        watchScreenshotFolder()
    }

    deinit {
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
            self?.pickUpNewScreenshots(retries: 3)
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }

        source.resume()
        directorySource = source
    }

    private func pickUpNewScreenshots(retries: Int) {
        guard !capturing else { return }

        let url = URL(fileURLWithPath: screenshotDir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return }

        var newFiles: [(url: URL, date: Date)] = []
        for file in contents where isImageFile(file) {
            if !knownFiles.contains(file.path) {
                knownFiles.insert(file.path)
                let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                newFiles.append((url: file, date: date))
            }
        }

        if newFiles.isEmpty && retries > 0 {
            // FIXME: Treat unreadable new screenshots as pending instead of relying on this fixed retry window.
            // File might still be writing — retry quickly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.pickUpNewScreenshots(retries: retries - 1)
            }
            return
        }

        newFiles.sort { $0.date > $1.date }

        for entry in newFiles {
            guard let image = NSImage(contentsOf: entry.url) else { continue }
            addImage(image, filePath: entry.url.path, autoCopy: true)
        }
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
        guard !capturing else { return }

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

    func beginCapture() {
        capturing = true
    }

    func endCapture() {
        capturing = false
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func addScreenshot(_ image: NSImage, savedPath: String?) {
        // Register the saved file so the directory watcher doesn't duplicate it
        if let savedPath { knownFiles.insert(savedPath) }

        if let entry = addImage(image, filePath: savedPath, autoCopy: false) {
            flashCopied(id: entry.id)
        }

        // Re-enable other detection after state is fully updated
        endCapture()
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
