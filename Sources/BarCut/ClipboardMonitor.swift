import AppKit
import Combine

final class ClipboardMonitor: ObservableObject {
    @Published var images: [(image: NSImage, filePath: String?)] = []
    @Published var lastCopiedIndex: Int? = nil

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
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let image = imageFromClipboard() else { return }
        addImage(image, filePath: nil, autoCopy: false)
    }

    private func addImage(_ image: NSImage, filePath: String?, autoCopy: Bool) {
        images.insert((image: image, filePath: filePath), at: 0)
        if images.count > maxItems {
            images.removeLast(images.count - maxItems)
        }

        if autoCopy {
            copyToClipboard(image)
            flashCopied(index: 0)
        }
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

        addImage(image, filePath: savedPath, autoCopy: false)
        flashCopied(index: 0)

        // Re-enable other detection after state is fully updated
        endCapture()
    }

    func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        lastChangeCount = pasteboard.changeCount
    }

    func copyAndFlash(_ image: NSImage, index: Int) {
        copyToClipboard(image)
        flashCopied(index: index)
    }

    private func flashCopied(index: Int) {
        lastCopiedIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.lastCopiedIndex == index {
                self?.lastCopiedIndex = nil
            }
        }
    }

    func clearHistory() {
        images.removeAll()
        lastCopiedIndex = nil
    }
}
