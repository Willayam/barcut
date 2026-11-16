import AppKit
import SwiftUI

struct CropDrag {
    enum Mode { case new, move, resize(Int) }
    var mode: Mode
    var start: CGPoint
    var original: CGRect
}

enum Interaction {
    case idle
    case drawing(Annotation.ID)
    case moving(Annotation.ID, last: CGPoint)
    case adjusting(Annotation.ID, Handle)
    case editingText(Annotation.ID)
    case cropping(CropDrag)
}

@MainActor
final class AnnotationEditor: ObservableObject {
    @Published var document: AnnotationDocument
    @Published var interaction: Interaction = .idle
    @Published var selectedID: UUID?
    @Published var tool: AnnotationTool
    @Published var color =
        AnnotationColor(rawValue: UserDefaults.standard.string(forKey: "annotationColor") ?? "") ?? .red
    var pointer: CGPoint?
    var pressPoint: CGPoint?
    var initialAnnotation: Annotation?
    var publishWork: DispatchWorkItem?
    let onPreviewChanged: (NSImage) -> Void
    let onComplete: (NSImage) -> Void
    let onCancel: () -> Void

    init(
        image: NSImage, tool: AnnotationTool, onPreviewChanged: @escaping (NSImage) -> Void,
        onComplete: @escaping (NSImage) -> Void, onCancel: @escaping () -> Void
    ) {
        document = AnnotationDocument(baseImage: image)
        self.tool = tool
        self.onPreviewChanged = onPreviewChanged
        self.onComplete = onComplete
        self.onCancel = onCancel
    }
    var editingID: UUID? {
        if case .editingText(let id) = interaction { return id }
        return nil
    }
    var selection: Annotation? { document.annotations.first { $0.id == selectedID } }
    var region: CGRect { tool == .crop ? document.bounds : document.visibleRegion }
    func publish() {
        publishWork?.cancel()
        onPreviewChanged(document.render())
    }
    func commit() { if document.commitChange() { publish() } }
    func done() {
        endText()
        publishWork?.cancel()
        onComplete(document.render())
    }
    func chooseTool(_ value: AnnotationTool) {
        endText()
        tool = value
        selectedID = nil
    }
    func chooseColor(_ value: AnnotationColor) {
        let target = editingID ?? selectedID
        endText()
        color = value
        UserDefaults.standard.set(value.rawValue, forKey: "annotationColor")
        guard let target, document.annotations.contains(where: { $0.id == target }) else { return }
        document.beginChange()
        document.update(target) { $0.color = value }
        commit()
    }
    func undo(_ redo: Bool = false) {
        endText()
        document.cancelChange()
        interaction = .idle
        if redo { document.redo() } else { document.undo() }
        selectedID = nil
        publish()
    }
    func beginText(at point: CGPoint, anchor: UnitPoint = .center, string: String = "", color: AnnotationColor? = nil) {
        document.beginChange()
        let item = Annotation(
            color: color ?? self.color,
            shape: .text(
                .init(position: point, anchor: anchor, string: string, fontSize: document.creationSizes.fontSize)))
        document.add(item)
        selectedID = item.id
        interaction = .editingText(item.id)
        if !string.isEmpty { updateText(string) }
    }
    func updateText(_ value: String) {
        guard let id = editingID else { return }
        document.update(id) {
            if case .text(var text) = $0.shape {
                text.string = value
                $0.shape = .text(text)
            }
        }
        publishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publish() }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func appendText(_ typed: String) {
        guard let id = editingID, let item = document.annotations.first(where: { $0.id == id }),
            case .text(let text) = item.shape
        else { return }
        updateText(text.string + typed)
    }
    func endText() {
        guard let id = editingID else { return }
        if let item = document.annotations.first(where: { $0.id == id }), case .text(let t) = item.shape,
            t.string.isEmpty
        {
            document.remove(id)
        }
        interaction = .idle
        selectedID = nil
        commit()
    }
    func mouseDown(_ viewPoint: CGPoint, projection p: AnnotationProjection, clicks: Int) {
        if editingID != nil {
            endText()
            pressPoint = nil
            return
        }
        pressPoint = nil
        guard p.containsViewPoint(viewPoint) else { return }
        let point = p.imagePoint(from: viewPoint)
        pressPoint = point
        document.beginChange()
        if tool == .crop {
            selectedID = nil
            let crop = document.crop
            let handle = crop?.cropHandles.firstIndex { ($0 - point).length < 8 / p.scale }
            let mode: CropDrag.Mode = handle.map { .resize($0) } ?? (crop?.contains(point) == true ? .move : .new)
            interaction = .cropping(.init(mode: mode, start: point, original: crop ?? .zero))
            return
        }
        if let selected = selection, let handle = selected.handles.first(where: { ($0.1 - point).length < 8 / p.scale })
        {
            initialAnnotation = selected
            interaction = .adjusting(selected.id, handle.0)
            return
        }
        if let hit = document.annotations.reversed().first(where: {
            $0.hit(point, slack: 5 / p.scale, imageBounds: document.bounds)
        }) {
            selectedID = hit.id
            if clicks == 2, case .text = hit.shape {
                interaction = .editingText(hit.id)
            } else {
                interaction = .moving(hit.id, last: point)
            }
            return
        }
        selectedID = nil
        if tool == .text {
            beginText(at: point)
            return
        }
        let weight = document.creationSizes.weight
        let item = Annotation(
            color: color,
            shape: tool == .arrow
                ? .arrow(.init(tail: point, head: point, bend: 0, weight: weight))
                : .box(.init(rect: .init(origin: point, size: .zero), weight: weight)))
        document.add(item)
        interaction = .drawing(item.id)
    }
    func mouseDragged(_ viewPoint: CGPoint, projection p: AnnotationProjection, shift: Bool) {
        guard let start = pressPoint else { return }
        let point = p.imagePoint(from: viewPoint)
        let region = self.region
        let initialAnnotation = self.initialAnnotation
        switch interaction {
        case .drawing(let id):
            document.update(id) { item in
                switch item.shape {
                case .arrow(var a):
                    a.head = Self.snapped(point, from: a.tail, shift: shift).clampedAlongRay(from: a.tail, to: region)
                    item.shape = .arrow(a)
                case .box(var b):
                    b.rect = .between(
                        start, Self.square(point, from: start, shift: shift).clampedAlongRay(from: start, to: region))
                    item.shape = .box(b)
                case .text: break
                }
            }
        case .moving(let id, let last):
            guard document.hasPendingEdits || (point - start).length * p.scale > 3 else { return }
            let delta = point - last
            document.update(id) { $0.move(by: delta, inside: region) }
            interaction = .moving(id, last: point)
        case .adjusting(let id, let handle):
            document.update(id) { item in
                switch item.shape {
                case .arrow(var a):
                    if handle == .tail {
                        a.tail = Self.snapped(point, from: a.head, shift: shift).clampedAlongRay(
                            from: a.head, to: region)
                    }
                    if handle == .head {
                        a.head = Self.snapped(point, from: a.tail, shift: shift).clampedAlongRay(
                            from: a.tail, to: region)
                    }
                    if handle == .bend {
                        let chord = a.head - a.tail, offset = point - (a.tail + a.head) * 0.5
                        let normal = chord.unit.normal
                        a.bend = min(0.6, max(-0.6, (offset.x * normal.x + offset.y * normal.y) / max(1, chord.length)))
                        if abs(a.bend) < 0.03 { a.bend = 0 }
                    }
                    item.shape = .arrow(a)
                case .box(var b):
                    if case .corner(let index) = handle {
                        let original: CGRect
                        if let initialAnnotation, case .box(let box) = initialAnnotation.shape {
                            original = box.rect
                        } else {
                            original = b.rect
                        }
                        let opposite = original.corners[(index + 2) % 4]
                        b.rect = .between(
                            opposite,
                            Self.square(point, from: opposite, shift: shift).clampedAlongRay(from: opposite, to: region)
                        )
                    }
                    item.shape = .box(b)
                case .text: break
                }
            }
        case .cropping(let drag):
            let rect: CGRect
            switch drag.mode {
            case .new: rect = .between(drag.start, point)
            case .move: rect = drag.original.translated(by: point - drag.start, inside: document.bounds)
            case .resize(let index):
                var a = drag.original.origin, b = CGPoint(x: drag.original.maxX, y: drag.original.maxY)
                if [0, 3, 7].contains(index) { a.x = point.x }
                if [0, 1, 4].contains(index) { a.y = point.y }
                if [1, 2, 5].contains(index) { b.x = point.x }
                if [2, 3, 6].contains(index) { b.y = point.y }
                rect = .between(a, b)
            }
            document.setCrop(rect)
        default: break
        }
    }
    func mouseUp(_ point: CGPoint, projection p: AnnotationProjection) {
        defer { pressPoint = nil }
        guard pressPoint != nil else { return }
        if case .editingText = interaction { return }
        if case .drawing(let id) = interaction {
            if let start = pressPoint, (p.imagePoint(from: point) - start).length * p.scale < 8 {
                document.cancelChange()
                selectedID = nil
            } else {
                selectedID = id
            }
        }
        interaction = .idle
        commit()
    }
    static func snapped(_ point: CGPoint, from start: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return point }
        let d = point - start, angle = (atan2(d.y, d.x) / (.pi / 4)).rounded() * (.pi / 4)
        return start + CGPoint(x: cos(angle), y: sin(angle)) * d.length
    }
    static func square(_ point: CGPoint, from start: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return point }
        let d = point - start, side = max(abs(d.x), abs(d.y))
        return start + CGPoint(x: d.x < 0 ? -side : side, y: d.y < 0 ? -side : side)
    }
}
