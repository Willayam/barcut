import AppKit
import CryptoKit
import ImageIO
import OSLog
import UniformTypeIdentifiers

let historyLogger = Logger(subsystem: "com.williamlarsten.BarCut", category: "history")

struct ImageID: Hashable, Codable, Sendable {
    let hex: String

    var fileName: String { hex + ".png" }

    init?(hex: String) {
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        self.hex = hex
    }

    init(from decoder: Decoder) throws {
        let hex = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .hex)
        guard let id = ImageID(hex: hex) else {
            throw DecodingError.dataCorruptedError(forKey: .hex, in: try decoder.container(keyedBy: CodingKeys.self), debugDescription: "not a sha256 hex")
        }
        self = id
    }
}

// Unchecked because CGImage is immutable once the store has built the entry.
struct ImageHistoryEntry: Identifiable, Equatable, @unchecked Sendable {
    let id: ImageID
    let thumbnail: CGImage
    var screenshotPath: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.screenshotPath == rhs.screenshotPath
    }
}

enum ImageSource: @unchecked Sendable {
    case screenshotFile(URL)
    case pasteboard(Data, isPNG: Bool)
    case rendered(CGImage)

    fileprivate var origin: String {
        switch self {
        case .screenshotFile: "file"
        case .pasteboard: "pasteboard"
        case .rendered: "editor"
        }
    }
}

struct Snapshot: Sendable {
    let revision: Int
    let entries: [ImageHistoryEntry]
}

private struct Manifest: Codable {
    var version = 1
    var items: [Item]

    struct Item: Codable {
        let id: ImageID
        var screenshotPath: String?
    }
}

actor ImageStore {
    private let directory: URL
    private let maxItems: Int
    private var loaded = false
    private var directoryAvailable = true
    private var didLogUnavailable = false
    private var revision = 0
    private var items: [Manifest.Item] = []
    private var thumbnails: [ImageID: CGImage] = [:]
    private var volatilePNGData: [ImageID: Data] = [:]

    init(directory: URL, maxItems: Int) {
        self.directory = directory
        self.maxItems = max(0, maxItems)
    }

    func ingest(_ source: ImageSource, screenshotPath: String?) -> Snapshot? {
        ensureLoaded()
        guard let prepared = prepare(source) else { return nil }

        let previousIDs = Set(items.map(\.id))
        if let index = items.firstIndex(where: { $0.id == prepared.id }) {
            var item = items.remove(at: index)
            if let screenshotPath {
                item.screenshotPath = screenshotPath
            }
            items.insert(item, at: 0)
        } else {
            persist(prepared.pngData, for: prepared.id)
            thumbnails[prepared.id] = prepared.thumbnail
            items.insert(Manifest.Item(id: prepared.id, screenshotPath: screenshotPath), at: 0)
        }

        let snapshot = commit(previousIDs: previousIDs)
        historyLogger.notice(
            "ingested \(prepared.id.hex, privacy: .public) from \(source.origin, privacy: .public)"
        )
        return snapshot
    }

    func current() -> Snapshot {
        ensureLoaded()
        return snapshot()
    }

    func clear() -> Snapshot {
        ensureLoaded()
        let previousIDs = Set(items.map(\.id))
        items.removeAll()
        return commit(previousIDs: previousIDs)
    }

    func pngData(for id: ImageID) -> Data? {
        ensureLoaded()
        if let data = volatilePNGData[id] {
            return data
        }
        return try? Data(contentsOf: fileURL(for: id), options: .mappedIfSafe)
    }

    func fullImage(for id: ImageID) -> CGImage? {
        guard let data = pngData(for: id),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            markDirectoryUnavailable()
            historyLogger.notice("restored 0 items")
            return
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        let candidates = manifest?.version == 1 ? manifest!.items : itemsRecoveredFromFiles()

        for item in candidates {
            guard let decoded = decode(CGImageSourceCreateWithURL(fileURL(for: item.id) as CFURL, nil)),
                  let thumbnail = makeThumbnail(decoded.image) else { continue }
            items.append(item)
            thumbnails[item.id] = thumbnail
        }

        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
            let retainedIDs = Set(items.map(\.id))
            thumbnails = thumbnails.filter { retainedIDs.contains($0.key) }
        }

        let retainedNames = Set(items.map { $0.id.fileName })
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for file in files where file.pathExtension.lowercased() == "png" && !retainedNames.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        writeManifest()
        historyLogger.notice("restored \(self.items.count) items")
    }

    /// A missing or unreadable manifest must never cost the images, so order falls back to file dates.
    private func itemsRecoveredFromFiles() -> [Manifest.Item] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return files
            .compactMap { url -> (id: ImageID, date: Date)? in
                guard url.pathExtension == "png",
                      let id = ImageID(hex: url.deletingPathExtension().lastPathComponent) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (id, date)
            }
            .sorted { $0.date > $1.date }
            .map { Manifest.Item(id: $0.id, screenshotPath: nil) }
    }

    private func prepare(_ source: ImageSource) -> (id: ImageID, thumbnail: CGImage, pngData: Data)? {
        let image: CGImage
        var originalPNG: Data?

        switch source {
        case .screenshotFile(let url):
            guard let decoded = decode(CGImageSourceCreateWithURL(url as CFURL, nil)) else { return nil }
            image = decoded.image
            if decoded.isPNG {
                originalPNG = try? Data(contentsOf: url, options: .mappedIfSafe)
            }
        case .pasteboard(let data, let isPNG):
            guard let decoded = decode(CGImageSourceCreateWithData(data as CFData, nil)) else { return nil }
            image = decoded.image
            if isPNG {
                originalPNG = data
            }
        case .rendered(let rendered):
            image = rendered
        }

        guard let id = fingerprint(image),
              let thumbnail = makeThumbnail(image),
              let pngData = originalPNG ?? Self.encode(image, type: UTType.png.identifier) else { return nil }
        return (id, thumbnail, pngData)
    }

    /// nil while a Pending Screenshot is still being written.
    private func decode(_ source: CGImageSource?) -> (image: CGImage, isPNG: Bool)? {
        guard let source,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, CGImageSourceGetType(source) as String? == UTType.png.identifier)
    }

    private func fingerprint(_ image: CGImage) -> ImageID? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let bytes = context.data else { return nil }

        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hasher = SHA256()
        var encodedWidth = UInt64(width).bigEndian
        var encodedHeight = UInt64(height).bigEndian
        withUnsafeBytes(of: &encodedWidth) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: &encodedHeight) { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: width * height * 4))
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ImageID(hex: hex)
    }

    private func makeThumbnail(_ image: CGImage) -> CGImage? {
        let scale = min(1, 560 / Double(max(image.width, image.height, 1)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated static func encode(_ image: CGImage, type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func persist(_ data: Data, for id: ImageID) {
        guard directoryAvailable else {
            volatilePNGData[id] = data
            return
        }
        do {
            try data.write(to: fileURL(for: id), options: .atomic)
        } catch {
            volatilePNGData[id] = data
            markDirectoryUnavailable()
        }
    }

    private func commit(previousIDs: Set<ImageID>) -> Snapshot {
        let idsBeforeLimit = Set(items.map(\.id))
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        let retainedIDs = Set(items.map(\.id))

        writeManifest()

        for id in previousIDs.union(idsBeforeLimit).subtracting(retainedIDs) {
            thumbnails.removeValue(forKey: id)
            volatilePNGData.removeValue(forKey: id)
            if directoryAvailable {
                try? FileManager.default.removeItem(at: fileURL(for: id))
            }
        }

        revision += 1
        return snapshot()
    }

    private func writeManifest() {
        guard directoryAvailable else { return }
        do {
            let data = try JSONEncoder().encode(Manifest(items: items))
            try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            markDirectoryUnavailable()
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            revision: revision,
            entries: items.compactMap { item in
                guard let thumbnail = thumbnails[item.id] else { return nil }
                return ImageHistoryEntry(id: item.id, thumbnail: thumbnail, screenshotPath: item.screenshotPath)
            }
        )
    }

    private func fileURL(for id: ImageID) -> URL {
        directory.appendingPathComponent(id.fileName)
    }

    private func markDirectoryUnavailable() {
        directoryAvailable = false
        guard !didLogUnavailable else { return }
        didLogUnavailable = true
        historyLogger.notice("store unavailable \(self.directory.path, privacy: .public)")
    }
}
