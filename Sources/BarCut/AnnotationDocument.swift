import AppKit

struct AnnotationDocument {
    let baseImage: NSImage
    private(set) var arrows: [ArrowAnnotation] = []
    private(set) var texts: [TextAnnotation] = []
    private(set) var pendingArrow: ArrowAnnotation?

    private let minimumArrowLength: CGFloat = 8

    init(baseImage: NSImage) {
        self.baseImage = baseImage
    }

    var imageSize: CGSize {
        baseImage.size
    }

    var defaultFontSize: CGFloat {
        max(22, min(imageSize.width, imageSize.height) * 0.035)
    }

    func projection(in viewportSize: CGSize) -> AnnotationProjection {
        AnnotationProjection(imageSize: imageSize, viewportSize: viewportSize)
    }

    mutating func addText(at point: CGPoint) -> TextAnnotation.ID {
        let text = TextAnnotation(position: clampedImagePoint(point), value: "Text", fontSize: defaultFontSize)
        texts.append(text)
        return text.id
    }

    mutating func updateText(id: TextAnnotation.ID, value: String) {
        guard let index = texts.firstIndex(where: { $0.id == id }) else { return }
        texts[index].value = value
    }

    mutating func beginArrow(at point: CGPoint) {
        let point = clampedImagePoint(point)
        pendingArrow = ArrowAnnotation(start: point, end: point)
    }

    mutating func updateArrow(to point: CGPoint) {
        let point = clampedImagePoint(point)
        if pendingArrow == nil {
            beginArrow(at: point)
        } else {
            pendingArrow?.end = point
        }
    }

    mutating func cancelPendingArrow() {
        pendingArrow = nil
    }

    @discardableResult
    mutating func finishArrow() -> Bool {
        defer { pendingArrow = nil }
        guard let pendingArrow, length(of: pendingArrow) > minimumArrowLength else { return false }
        arrows.append(pendingArrow)
        return true
    }

    func render() -> NSImage {
        let output = NSImage(size: imageSize)
        output.lockFocus()

        baseImage.draw(
            in: NSRect(origin: .zero, size: imageSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        NSColor.systemRed.setStroke()
        NSColor.systemRed.setFill()

        for arrow in arrows {
            drawRenderedArrow(arrow, imageSize: imageSize)
        }

        for text in texts where !text.value.isEmpty {
            drawRenderedText(text, imageSize: imageSize)
        }

        output.unlockFocus()
        return output
    }

    private func clampedImagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), imageSize.width),
            y: min(max(point.y, 0), imageSize.height)
        )
    }

    private func length(of arrow: ArrowAnnotation) -> CGFloat {
        hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
    }
}

struct AnnotationProjection {
    let imageRect: CGRect
    private let imageSize: CGSize

    init(imageSize: CGSize, viewportSize: CGSize) {
        self.imageSize = imageSize

        let bounds = CGRect(origin: .zero, size: viewportSize).insetBy(dx: 16, dy: 16)
        guard imageSize.width > 0, imageSize.height > 0 else {
            imageRect = bounds
            return
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale

        imageRect = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    func containsViewPoint(_ point: CGPoint) -> Bool {
        imageRect.contains(point)
    }

    func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }

        return CGPoint(
            x: min(max((viewPoint.x - imageRect.minX) / imageRect.width * imageSize.width, 0), imageSize.width),
            y: min(max((viewPoint.y - imageRect.minY) / imageRect.height * imageSize.height, 0), imageSize.height)
        )
    }

    func viewPoint(for imagePoint: CGPoint) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return imageRect.origin }

        return CGPoint(
            x: imageRect.minX + imagePoint.x / imageSize.width * imageRect.width,
            y: imageRect.minY + imagePoint.y / imageSize.height * imageRect.height
        )
    }

    func displayFontSize(for text: TextAnnotation) -> CGFloat {
        guard imageSize.width > 0 else { return text.fontSize }
        return text.fontSize * imageRect.width / imageSize.width
    }
}

struct ArrowAnnotation: Identifiable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
}

struct TextAnnotation: Identifiable {
    let id = UUID()
    var position: CGPoint
    var value: String
    var fontSize: CGFloat
}

private func drawRenderedArrow(_ arrow: ArrowAnnotation, imageSize: CGSize) {
    let start = renderPoint(arrow.start, imageSize: imageSize)
    let end = renderPoint(arrow.end, imageSize: imageSize)
    let angle = atan2(end.y - start.y, end.x - start.x)
    let lineWidth = max(4, min(imageSize.width, imageSize.height) * 0.006)
    let headLength = lineWidth * 5
    let headAngle = CGFloat.pi / 7

    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: start)
    path.line(to: end)
    path.stroke()

    let firstHeadPoint = CGPoint(
        x: end.x - headLength * cos(angle - headAngle),
        y: end.y - headLength * sin(angle - headAngle)
    )
    let secondHeadPoint = CGPoint(
        x: end.x - headLength * cos(angle + headAngle),
        y: end.y - headLength * sin(angle + headAngle)
    )

    let head = NSBezierPath()
    head.lineWidth = lineWidth
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: firstHeadPoint)
    head.line(to: end)
    head.line(to: secondHeadPoint)
    head.stroke()
}

private func drawRenderedText(_ text: TextAnnotation, imageSize: CGSize) {
    let point = renderPoint(text.position, imageSize: imageSize)
    let font = NSFont.systemFont(ofSize: text.fontSize, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let value = text.value as NSString
    let textSize = value.size(withAttributes: attributes)
    let rectWidth = min(textSize.width + 12, imageSize.width)
    let rectHeight = min(textSize.height + 6, imageSize.height)
    let maxX = max(imageSize.width - rectWidth, 0)
    let maxY = max(imageSize.height - rectHeight, 0)
    let rect = NSRect(
        x: min(max(point.x, 0), maxX),
        y: min(max(point.y - rectHeight, 0), maxY),
        width: rectWidth,
        height: rectHeight
    )

    NSColor.systemRed.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    value.draw(in: rect.insetBy(dx: 6, dy: 3), withAttributes: attributes)
}

private func renderPoint(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
    CGPoint(x: point.x, y: imageSize.height - point.y)
}
