import AppKit
import SwiftUI

struct Annotation: Identifiable, Equatable {
    let id: UUID
    var color: AnnotationColor
    var shape: Shape

    init(id: UUID = UUID(), color: AnnotationColor, shape: Shape) {
        self.id = id
        self.color = color
        self.shape = shape
    }

    enum Shape: Equatable {
        case arrow(Arrow)
        case box(Box)
        case text(TextLabel)
    }
}

struct Arrow: Equatable {
    var tail: CGPoint
    var head: CGPoint
    var bend: CGFloat
    var weight: CGFloat
}

struct Box: Equatable {
    var rect: CGRect
    var weight: CGFloat
}

struct TextLabel: Equatable {
    var position: CGPoint
    var anchor: UnitPoint
    var string: String
    var fontSize: CGFloat
}

struct AnnotationDocument {
    let baseImage: CGImage
    private(set) var annotations: [Annotation] = []
    private(set) var crop: CGRect?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var pending: Snapshot?

    struct Snapshot: Equatable {
        var annotations: [Annotation]
        var crop: CGRect?
    }

    init(baseImage: NSImage) {
        self.baseImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    var imageSize: CGSize { CGSize(width: baseImage.width, height: baseImage.height) }
    var bounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    var visibleRegion: CGRect { crop ?? bounds }
    var snapshot: Snapshot { Snapshot(annotations: annotations, crop: crop) }
    var hasPendingEdits: Bool { pending.map { $0 != snapshot } ?? false }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Grows with the square root of the visible region, so annotations made before and after a crop
    /// stay close in size and a small image does not get hairline arrows.
    var creationSizes: (weight: CGFloat, fontSize: CGFloat) {
        let root = min(visibleRegion.width, visibleRegion.height).squareRoot()
        return (max(4, 0.3 * root), max(16, 1.35 * root))
    }

    mutating func beginChange() { if pending == nil { pending = snapshot } }
    @discardableResult mutating func commitChange() -> Bool {
        guard let before = pending else { return false }
        pending = nil
        guard before != snapshot else { return false }
        undoStack.append(before)
        redoStack.removeAll()
        return true
    }
    mutating func cancelChange() {
        if let pending { restore(pending) }
        pending = nil
    }
    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }
    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }
    private mutating func restore(_ state: Snapshot) {
        annotations = state.annotations
        crop = state.crop
    }
    mutating func add(_ annotation: Annotation) { annotations.append(annotation) }
    mutating func remove(_ id: UUID) { annotations.removeAll { $0.id == id } }
    mutating func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&annotations[index])
    }
    mutating func setCrop(_ rect: CGRect?) {
        guard let rect else {
            crop = nil
            return
        }
        let clipped = rect.standardized.intersection(bounds).integral.intersection(bounds)
        crop = clipped.width >= 16 && clipped.height >= 16 ? clipped : nil
    }
    func render() -> NSImage { AnnotationRenderer.export(self) }
}
