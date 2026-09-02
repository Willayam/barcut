import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BarCut

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    func testImportsReadableScreenshotFromObservedDestination() async throws {
        let directories = try makeDirectories()
        defer { removeDirectories(directories) }
        let monitor = makeMonitor(directories)

        let imageURL = directories.screenshots.appendingPathComponent("Screenshot.png")
        try pngData(color: .systemRed).write(to: imageURL)
        await monitor.scanScreenshotDestination()

        XCTAssertEqual(monitor.images.count, 1)
        XCTAssertEqual(
            monitor.images.first?.screenshotPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            imageURL.lastPathComponent
        )
        XCTAssertNil(monitor.lastCopiedID)
    }

    func testPendingScreenshotDoesNotEnterHistoryUntilReadable() async throws {
        let directories = try makeDirectories()
        defer { removeDirectories(directories) }
        let monitor = makeMonitor(directories)

        let imageURL = directories.screenshots.appendingPathComponent("Pending.png")
        try Data("not an image yet".utf8).write(to: imageURL)
        await monitor.scanScreenshotDestination()
        XCTAssertTrue(monitor.images.isEmpty)

        try pngData(color: .systemBlue).write(to: imageURL)
        await monitor.scanScreenshotDestination()

        XCTAssertEqual(monitor.images.count, 1)
        XCTAssertEqual(
            monitor.images.first?.screenshotPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            imageURL.lastPathComponent
        )
    }

    func testExistingFilesAtStartupAreNotImported() async throws {
        let directories = try makeDirectories()
        defer { removeDirectories(directories) }
        let imageURL = directories.screenshots.appendingPathComponent("Existing.png")
        try pngData(color: .systemGreen).write(to: imageURL)

        let monitor = makeMonitor(directories)
        await monitor.scanScreenshotDestination()

        XCTAssertTrue(monitor.images.isEmpty)
    }

    func testHistorySurvivesRelaunchInTheSameOrder() async throws {
        let directories = try makeDirectories()
        defer { removeDirectories(directories) }
        let first = makeMonitor(directories)

        try pngData(color: .systemRed).write(
            to: directories.screenshots.appendingPathComponent("First.png")
        )
        await first.scanScreenshotDestination()
        try pngData(color: .systemBlue).write(
            to: directories.screenshots.appendingPathComponent("Second.png")
        )
        await first.scanScreenshotDestination()
        let expectedIDs = first.images.map(\.id)

        let second = makeMonitor(directories)
        await second.refresh()

        XCTAssertEqual(second.images.map(\.id), expectedIDs)
    }

    private func makeMonitor(_ directories: TestDirectories, maxItems: Int = 10) -> ClipboardMonitor {
        ClipboardMonitor(
            screenshotDir: directories.screenshots.path,
            storeDir: directories.store.path,
            maxItems: maxItems,
            pollClipboard: false,
            watchScreenshots: false
        )
    }

    private func makeDirectories() throws -> TestDirectories {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarCutTests-\(UUID().uuidString)", isDirectory: true)
        let screenshots = root.appendingPathComponent("Screenshots", isDirectory: true)
        let store = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return TestDirectories(root: root, screenshots: screenshots, store: store)
    }

    private func removeDirectories(_ directories: TestDirectories) {
        try? FileManager.default.removeItem(at: directories.root)
    }
}

final class ImageStoreTests: XCTestCase {
    func testPNGFileAndTIFFReencodeProduceOneItem() async throws {
        for colorSpace in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pngURL = directory.appendingPathComponent("source.png")
            let png = try pngData(color: .systemPurple, colorSpace: colorSpace)
            try png.write(to: pngURL)
            let tiff = try reencode(png, as: .tiff)
            let storeDirectory = directory.appendingPathComponent("Store", isDirectory: true)
            let store = ImageStore(directory: storeDirectory, maxItems: 10)

            let firstResult = await store.ingest(.screenshotFile(pngURL), screenshotPath: pngURL.path)
            let secondResult = await store.ingest(.pasteboard(tiff, isPNG: false), screenshotPath: nil)
            let first = try XCTUnwrap(firstResult)
            let second = try XCTUnwrap(secondResult)

            XCTAssertEqual(second.entries.count, 1, "\(colorSpace)")
            XCTAssertEqual(second.entries.first?.id, first.entries.first?.id, "\(colorSpace)")
            XCTAssertEqual(second.entries.first?.screenshotPath, pngURL.path)
        }
    }

    func testEvictionAndClearDeletePNGFiles() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageStore(directory: directory, maxItems: 2)
        let red = try pngData(color: .systemRed)
        let green = try pngData(color: .systemGreen)
        let blue = try pngData(color: .systemBlue)

        let firstResult = await store.ingest(.pasteboard(red, isPNG: true), screenshotPath: nil)
        let first = try XCTUnwrap(firstResult)
        let firstID = try XCTUnwrap(first.entries.first?.id)
        _ = await store.ingest(.pasteboard(green, isPNG: true), screenshotPath: nil)
        let retainedResult = await store.ingest(.pasteboard(blue, isPNG: true), screenshotPath: nil)
        let retained = try XCTUnwrap(retainedResult)

        XCTAssertEqual(retained.entries.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(firstID.fileName).path))
        for entry in retained.entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id.fileName).path))
        }

        let cleared = await store.clear()

        XCTAssertTrue(cleared.entries.isEmpty)
        for entry in retained.entries {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id.fileName).path))
        }
    }

    func testLoadRemovesOrphansAndManifestItemsWithoutFiles() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = directory.appendingPathComponent("orphan.png")
        try pngData(color: .systemOrange).write(to: orphan)
        try manifestData(ids: [String(repeating: "a", count: 64)]).write(
            to: directory.appendingPathComponent("manifest.json")
        )

        let snapshot = await ImageStore(directory: directory, maxItems: 10).current()

        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try manifestItemCount(in: directory), 0)
    }

    func testUnreadableOrNewerManifestRecoversItemsFromFiles() async throws {
        let manifests = [
            "{\"version\":1,\"items\":[",
            "{\"version\":2,\"items\":[]}",
            "{\"version\":1,\"items\":[{\"id\":{\"hex\":\"../escape\"}}]}",
        ]
        for manifest in manifests {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let keptName = String(repeating: "b", count: 64) + ".png"
            try pngData(color: .systemYellow).write(to: directory.appendingPathComponent(keptName))
            let orphan = directory.appendingPathComponent("orphan.png")
            try pngData(color: .systemTeal).write(to: orphan)
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))

            let snapshot = await ImageStore(directory: directory, maxItems: 10).current()

            XCTAssertEqual(snapshot.entries.map(\.id.hex), [String(repeating: "b", count: 64)], manifest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), manifest)
            XCTAssertEqual(try manifestItemCount(in: directory), 1, manifest)
        }
    }

    func testMissingManifestRecoversItemsFromFilesNewestFirst() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = String(repeating: "a", count: 64)
        let newer = String(repeating: "c", count: 64)
        try pngData(color: .systemBrown).write(to: directory.appendingPathComponent(older + ".png"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: directory.appendingPathComponent(older + ".png").path
        )
        try pngData(color: .systemPink).write(to: directory.appendingPathComponent(newer + ".png"))

        let snapshot = await ImageStore(directory: directory, maxItems: 10).current()

        XCTAssertEqual(snapshot.entries.map(\.id.hex), [newer, older])
        XCTAssertEqual(try manifestItemCount(in: directory), 2)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarCutStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func reencode(_ data: Data, as type: UTType) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func manifestData(ids: [String]) throws -> Data {
        let items = ids.map { ["id": ["hex": $0], "screenshotPath": NSNull()] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "items": items])
    }

    private func manifestItemCount(in directory: URL) throws -> Int {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["items"] as? [[String: Any]]).count
    }
}

private struct TestDirectories {
    let root: URL
    let screenshots: URL
    let store: URL
}

private func pngData(color: NSColor, colorSpace colorSpaceName: CFString = CGColorSpace.sRGB) throws -> Data {
    let width = 32
    let height = 24
    let colorSpace = try XCTUnwrap(CGColorSpace(name: colorSpaceName))
    let context = try XCTUnwrap(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
}
