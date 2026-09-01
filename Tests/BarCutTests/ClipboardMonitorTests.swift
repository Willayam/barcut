import AppKit
import XCTest
@testable import BarCut

final class ClipboardMonitorTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try super.tearDownWithError()
    }

    func testImportsReadableScreenshotFromObservedDestination() throws {
        let dir = try makeTempDir()
        let monitor = ClipboardMonitor(
            screenshotDir: dir.path,
            pollClipboard: false,
            watchScreenshots: false
        )

        let imageURL = dir.appendingPathComponent("Screenshot.png")
        try validPNGData().write(to: imageURL)

        monitor.scanScreenshotDestination()

        XCTAssertEqual(monitor.images.count, 1)
        XCTAssertEqual((monitor.images.first?.filePath as NSString?)?.lastPathComponent, imageURL.lastPathComponent)
        XCTAssertNil(monitor.lastCopiedID)
    }

    func testPendingScreenshotDoesNotEnterHistoryUntilReadable() throws {
        let dir = try makeTempDir()
        let monitor = ClipboardMonitor(
            screenshotDir: dir.path,
            pollClipboard: false,
            watchScreenshots: false
        )

        let imageURL = dir.appendingPathComponent("Pending.png")
        try Data("not an image yet".utf8).write(to: imageURL)

        monitor.scanScreenshotDestination()
        XCTAssertTrue(monitor.images.isEmpty)

        try validPNGData().write(to: imageURL)
        monitor.scanScreenshotDestination()

        XCTAssertEqual(monitor.images.count, 1)
        XCTAssertEqual((monitor.images.first?.filePath as NSString?)?.lastPathComponent, imageURL.lastPathComponent)
    }

    func testExistingFilesAtStartupAreNotImported() throws {
        let dir = try makeTempDir()
        let imageURL = dir.appendingPathComponent("Existing.png")
        try validPNGData().write(to: imageURL)

        let monitor = ClipboardMonitor(
            screenshotDir: dir.path,
            pollClipboard: false,
            watchScreenshots: false
        )

        monitor.scanScreenshotDestination()

        XCTAssertTrue(monitor.images.isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarCutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func validPNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
