import AppKit
import CoreText

enum AnnotationRenderer {
    static func textRect(_ text: TextLabel, bounds: CGRect) -> CGRect {
        let line = textLine(text, color: .white)
        let size = line.size()
        let width = min(bounds.width, ceil(size.width + 0.9 * text.fontSize))
        let height = min(bounds.height, ceil(size.height + 0.4 * text.fontSize))
        return CGRect(
            x: min(max(text.position.x - width * text.anchor.x, bounds.minX), bounds.maxX - width),
            y: min(max(text.position.y - height * text.anchor.y, bounds.minY), bounds.maxY - height),
            width: width, height: height)
    }
    static func textLine(_ text: TextLabel, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text.string,
            attributes: [.font: NSFont.systemFont(ofSize: text.fontSize, weight: .semibold), .foregroundColor: color])
    }
    static func draw(_ document: AnnotationDocument, in context: CGContext, skipping: UUID? = nil) {
        for annotation in document.annotations where annotation.id != skipping {
            context.saveGState()
            let weight: CGFloat
            switch annotation.shape {
            case .arrow(let a): weight = a.weight
            case .box(let b): weight = b.weight
            case .text(let t): weight = t.fontSize * 0.17
            }
            // Quartz shadows keep their vertical direction after the image-space flip.
            context.setShadow(
                offset: CGSize(width: 0, height: -weight * 0.5), blur: weight * 1.5,
                color: NSColor.black.withAlphaComponent(0.3).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(annotation.color.nsColor.cgColor)
            context.setStrokeColor(annotation.color.nsColor.cgColor)
            context.setLineJoin(.round)
            switch annotation.shape {
            case .arrow(let arrow):
                let outline = arrow.outline
                context.addPath(outline.path)
                context.setLineWidth(0.35 * outline.weight)
                context.drawPath(using: .fillStroke)
            case .box(let box):
                let radius = min(2 * box.weight, min(box.rect.width, box.rect.height) / 4)
                context.addPath(
                    CGPath(roundedRect: box.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setLineWidth(0.75 * box.weight)
                context.strokePath()
            case .text(let text):
                let rect = textRect(text, bounds: document.bounds)
                context.addPath(
                    CGPath(
                        roundedRect: rect, cornerWidth: 0.3 * text.fontSize, cornerHeight: 0.3 * text.fontSize,
                        transform: nil))
                context.fillPath()
                context.saveGState()
                context.clip(to: rect)
                let line = CTLineCreateWithAttributedString(textLine(text, color: annotation.color.textColor))
                let font = NSFont.systemFont(ofSize: text.fontSize, weight: .semibold)
                context.translateBy(
                    x: rect.minX + text.fontSize * 0.45, y: rect.minY + text.fontSize * 0.2 + font.ascender)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }
    static func drawBase(_ image: CGImage, bounds: CGRect, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
    static func export(_ document: AnnotationDocument) -> NSImage {
        let region = document.visibleRegion
        let context = CGContext(
            data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: region.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.clip(to: region)
        drawBase(document.baseImage, bounds: document.bounds, in: context)
        draw(document, in: context)
        return NSImage(cgImage: context.makeImage()!, size: region.size)
    }
}
