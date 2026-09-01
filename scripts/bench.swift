import AppKit
import CryptoKit
import ImageIO

func ms(_ block: () -> Void) -> String {
    let start = DispatchTime.now().uptimeNanoseconds
    block()
    return String(format: "%7.1f ms", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
}

guard CommandLine.arguments.count == 2 else {
    print("usage: swift scripts/bench.swift <screenshot.png>")
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var image: NSImage!
print(ms { image = NSImage(contentsOf: url) }, "NSImage(contentsOf:)  size \(image.size)")

print(ms {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    _ = SHA256.hash(data: rep.representation(using: .png, properties: [:])!)
}, "fingerprint as shipped (tiff -> png -> sha256)")

print(ms {
    let ctx = CGContext(data: nil, width: 560, height: 312, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: 0, y: 0, width: 560, height: 312))
}, "full decode + draw into a 560x312 row (what the list does per row)")

print(ms {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 560,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    _ = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)!
}, "CGImageSource thumbnail at 560px")

print(ms {
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    _ = SHA256.hash(data: UnsafeRawBufferPointer(start: ctx.data, count: cg.width * cg.height * 4))
}, "exact pixel hash (draw RGBA + sha256)")

print(ms { _ = SHA256.hash(data: try! Data(contentsOf: url)) }, "sha256 of the file bytes")

let bench = NSPasteboard(name: NSPasteboard.Name("BarCutBench"))
print(ms {
    bench.clearContents()
    bench.writeObjects([NSImage(contentsOf: url)!])
}, "copy via writeObjects([NSImage]) on a private pasteboard")
print(ms {
    bench.clearContents()
    bench.setData(try! Data(contentsOf: url), forType: .png)
}, "copy via setData(png) on a private pasteboard")
