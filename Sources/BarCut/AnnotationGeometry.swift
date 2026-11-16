import AppKit
import SwiftUI

enum AnnotationLayout {
    static let margin: CGFloat = 16
    static let toolbarBand: CGFloat = 88
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { .init(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { .init(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, b: CGFloat) -> CGPoint { .init(x: a.x * b, y: a.y * b) }
    var length: CGFloat { hypot(x, y) }
    var normal: CGPoint { .init(x: -y, y: x) }
    var unit: CGPoint { self * (1 / max(length, 0.0001)) }
    func clampedAlongRay(from origin: CGPoint, to rect: CGRect) -> CGPoint {
        let delta = self - origin
        var fraction: CGFloat = 1
        if delta.x > 0 { fraction = min(fraction, (rect.maxX - origin.x) / delta.x) }
        if delta.x < 0 { fraction = min(fraction, (rect.minX - origin.x) / delta.x) }
        if delta.y > 0 { fraction = min(fraction, (rect.maxY - origin.y) / delta.y) }
        if delta.y < 0 { fraction = min(fraction, (rect.minY - origin.y) / delta.y) }
        return origin + delta * max(0, fraction)
    }
    func clamped(to rect: CGRect) -> CGPoint {
        .init(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}

struct AnnotationProjection {
    let visibleRegion: CGRect
    let imageRect: CGRect
    let scale: CGFloat

    init(visibleRegion: CGRect, viewportSize: CGSize) {
        self.visibleRegion = visibleRegion
        let bounds = CGRect(
            x: AnnotationLayout.margin, y: AnnotationLayout.margin,
            width: max(1, viewportSize.width - 2 * AnnotationLayout.margin),
            height: max(1, viewportSize.height - 2 * AnnotationLayout.margin - AnnotationLayout.toolbarBand))
        scale = min(bounds.width / visibleRegion.width, bounds.height / visibleRegion.height)
        imageRect = CGRect(
            x: bounds.midX - visibleRegion.width * scale / 2,
            y: bounds.midY - visibleRegion.height * scale / 2,
            width: visibleRegion.width * scale, height: visibleRegion.height * scale)
    }
    func containsViewPoint(_ point: CGPoint) -> Bool { imageRect.contains(point) }
    func imagePoint(from point: CGPoint) -> CGPoint {
        (visibleRegion.origin + (point - imageRect.origin) * (1 / scale)).clamped(to: visibleRegion)
    }
    func viewPoint(for point: CGPoint) -> CGPoint { imageRect.origin + (point - visibleRegion.origin) * scale }
    func viewRect(for rect: CGRect) -> CGRect {
        CGRect(
            origin: viewPoint(for: rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
}

enum Handle: Equatable {
    case tail, head, bend
    case corner(Int)
}

extension Arrow {
    var control: CGPoint { (tail + head) * 0.5 + (head - tail).normal * (2 * bend) }
    func point(_ t: CGFloat) -> CGPoint {
        tail * ((1 - t) * (1 - t)) + control * (2 * (1 - t) * t) + head * (t * t)
    }
    func tangent(_ t: CGFloat) -> CGPoint { ((control - tail) * (1 - t) + (head - control) * t).unit }
    var samples: [(point: CGPoint, distance: CGFloat, t: CGFloat)] {
        var result: [(CGPoint, CGFloat, CGFloat)] = [(tail, 0, 0)]
        for i in 1...48 {
            let t = CGFloat(i) / 48
            let p = point(t)
            result.append((p, result.last!.1 + (p - result.last!.0).length, t))
        }
        return result
    }
    /// Sizes in units of the effective weight, so the whole arrow scales together.
    private enum Proportion {
        static let headLength: CGFloat = 5.2
        static let headHalfWidth: CGFloat = 2.6
        static let junction: CGFloat = 4.2
        static let tailHalfWidth: CGFloat = 0.18
        static let junctionHalfWidth: CGFloat = 0.75
        /// A short arrow gives at most this share of its length to the head.
        static let maxHeadShare: CGFloat = 0.45
    }

    var outline: (path: CGPath, weight: CGFloat) {
        let samples = self.samples
        let length = samples.last!.distance
        let w = min(weight, length * Proportion.maxHeadShare / Proportion.headLength)
        let path = CGMutablePath()
        guard length > 0.01 else { return (path, w) }

        func atDistance(_ distance: CGFloat) -> CGPoint {
            for i in 1..<samples.count where samples[i].distance >= distance {
                let a = samples[i - 1], b = samples[i]
                return a.point + (b.point - a.point) * ((distance - a.distance) / max(0.001, b.distance - a.distance))
            }
            return head
        }

        let axis = (head - atDistance(length - Proportion.headLength * w)).unit
        let junction = head - axis * (Proportion.junction * w)
        let barbBase = head - axis * (Proportion.headLength * w)
        let shaftLength = max(0.001, length - Proportion.junction * w)
        let taper = Proportion.junctionHalfWidth - Proportion.tailHalfWidth

        var left: [CGPoint] = [], right: [CGPoint] = []
        for sample in samples where sample.distance < shaftLength {
            let half = w * (Proportion.tailHalfWidth + taper * sample.distance / shaftLength)
            let normal = tangent(sample.t).normal
            left.append(sample.point + normal * half)
            right.append(sample.point - normal * half)
        }
        left.append(junction + axis.normal * (Proportion.junctionHalfWidth * w))
        right.append(junction - axis.normal * (Proportion.junctionHalfWidth * w))

        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        path.addLine(to: barbBase + axis.normal * (Proportion.headHalfWidth * w))
        path.addLine(to: head)
        path.addLine(to: barbBase - axis.normal * (Proportion.headHalfWidth * w))
        for p in right.reversed() { path.addLine(to: p) }
        path.addQuadCurve(to: left[0], control: tail - tangent(0) * (2 * Proportion.tailHalfWidth * w))
        path.closeSubpath()
        return (path, w)
    }
}

extension Arrow {
    /// Where a typed label goes: past the tail, growing away from the arrow. Near an edge, where
    /// clamping would push the label back over the arrow, it sits beside the tail instead.
    func labelPlacement(fontSize: CGFloat, in region: CGRect) -> (position: CGPoint, anchor: UnitPoint) {
        let direction = tangent(0)
        let past = tail - direction * (1.5 * weight)
        let beside = 3 * weight
        let lineRoom = 7 * fontSize
        let pillRoom = 1.6 * fontSize + beside

        if abs(direction.x) >= abs(direction.y) {
            let pointsRight = direction.x > 0
            let room = pointsRight ? tail.x - region.minX : region.maxX - tail.x
            if room >= lineRoom { return (past, pointsRight ? .trailing : .leading) }
            let above = tail.y - region.minY >= pillRoom
            return (
                CGPoint(x: tail.x, y: tail.y + (above ? -beside : beside)),
                UnitPoint(x: pointsRight ? 0 : 1, y: above ? 1 : 0)
            )
        }
        let pointsDown = direction.y > 0
        let room = pointsDown ? tail.y - region.minY : region.maxY - tail.y
        if room >= pillRoom { return (past, pointsDown ? .bottom : .top) }
        let right = region.maxX - tail.x >= lineRoom
        return (CGPoint(x: tail.x + (right ? beside : -beside), y: tail.y), right ? .leading : .trailing)
    }
}

extension CGRect {
    var corners: [CGPoint] {
        [.init(x: minX, y: minY), .init(x: maxX, y: minY), .init(x: maxX, y: maxY), .init(x: minX, y: maxY)]
    }
    var cropHandles: [CGPoint] {
        corners + [.init(x: midX, y: minY), .init(x: maxX, y: midY), .init(x: midX, y: maxY), .init(x: minX, y: midY)]
    }
    func translated(by delta: CGPoint, inside bounds: CGRect) -> CGRect {
        offsetBy(
            dx: min(max(delta.x, bounds.minX - minX), bounds.maxX - maxX),
            dy: min(max(delta.y, bounds.minY - minY), bounds.maxY - maxY))
    }
    static func between(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension Annotation {
    var handles: [(Handle, CGPoint)] {
        switch shape {
        case .arrow(let a): return [(.tail, a.tail), (.head, a.head), (.bend, a.point(0.5))]
        case .box(let b): return b.rect.corners.enumerated().map { (.corner($0.offset), $0.element) }
        case .text: return []
        }
    }
    func hit(_ point: CGPoint, slack: CGFloat, imageBounds: CGRect) -> Bool {
        switch shape {
        case .arrow(let a):
            let outline = a.outline
            return outline.path.contains(point)
                || outline.path.copy(strokingWithWidth: 2 * slack, lineCap: .round, lineJoin: .round, miterLimit: 1)
                    .contains(point)
        case .box(let b):
            return b.rect.insetBy(dx: -slack - b.weight / 2, dy: -slack - b.weight / 2).contains(point)
                && !b.rect.insetBy(dx: slack + b.weight / 2, dy: slack + b.weight / 2).contains(point)
        case .text(let t): return AnnotationRenderer.textRect(t, bounds: imageBounds).contains(point)
        }
    }
    mutating func move(by delta: CGPoint, inside bounds: CGRect) {
        switch shape {
        case .arrow(var a):
            let rect = CGRect.between(a.tail, a.head)
            let moved = rect.translated(by: delta, inside: bounds)
            let d = moved.origin - rect.origin
            a.tail = a.tail + d
            a.head = a.head + d
            shape = .arrow(a)
        case .box(var b):
            b.rect = b.rect.translated(by: delta, inside: bounds)
            shape = .box(b)
        case .text(var t):
            t.position = (t.position + delta).clamped(to: bounds)
            shape = .text(t)
        }
    }
}
