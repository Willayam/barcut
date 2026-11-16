import AppKit
import SwiftUI

struct AnnotationEditorView: View {
    @StateObject private var editor: AnnotationEditor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        image: NSImage, initialTool: AnnotationTool, onPreviewChanged: @escaping (NSImage) -> Void,
        onComplete: @escaping (NSImage) -> Void, onCancel: @escaping () -> Void
    ) {
        _editor = StateObject(
            wrappedValue: AnnotationEditor(
                image: image, tool: initialTool, onPreviewChanged: onPreviewChanged, onComplete: onComplete,
                onCancel: onCancel))
    }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                AnnotationViewport(editor: editor, region: editor.region)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: editor.region)
                AnnotationToolbar(editor: editor)
                    .frame(maxWidth: .infinity)
                    .position(x: proxy.size.width / 2, y: proxy.size.height - AnnotationLayout.toolbarBand / 2)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onDisappear { editor.publishWork?.cancel() }
    }
}

private struct AnnotationViewport: View, Animatable {
    @ObservedObject var editor: AnnotationEditor
    var region: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(region.origin.x, region.origin.y), .init(region.width, region.height)) }
        set {
            region = CGRect(
                x: newValue.first.first, y: newValue.first.second, width: newValue.second.first,
                height: newValue.second.second)
        }
    }
    var body: some View {
        GeometryReader { proxy in
            let projection = AnnotationProjection(visibleRegion: region, viewportSize: proxy.size)
            ZStack(alignment: .topLeading) {
                AnnotationCanvas(
                    document: editor.document, selectedID: editor.selectedID, editingID: editor.editingID,
                    cropTool: editor.tool == .crop, region: region
                )
                .allowsHitTesting(false)
                AnnotationInput(editor: editor, projection: projection)
                if let id = editor.editingID, let item = editor.document.annotations.first(where: { $0.id == id }),
                    case .text(let text) = item.shape
                {
                    textField(text, color: item.color, projection: projection)
                }
            }
        }
    }
    private func textField(_ text: TextLabel, color: AnnotationColor, projection: AnnotationProjection) -> some View {
        let rect = projection.viewRect(for: AnnotationRenderer.textRect(text, bounds: editor.document.bounds))
        return AnnotationTextField(
            value: text.string, fontSize: text.fontSize * projection.scale, color: color, onChange: editor.updateText
        )
        .padding(.horizontal, text.fontSize * 0.45 * projection.scale)
        .padding(.vertical, text.fontSize * 0.2 * projection.scale)
        .frame(width: max(rect.width, 30), height: rect.height)
        .background(
            Color(nsColor: color.nsColor), in: RoundedRectangle(cornerRadius: text.fontSize * 0.3 * projection.scale)
        )
        .position(x: rect.midX, y: rect.midY)
    }
}

private struct AnnotationTextField: NSViewRepresentable {
    var value: String
    var fontSize: CGFloat
    var color: AnnotationColor
    var onChange: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField(string: value)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.setAccessibilityLabel("Annotation text")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color.textColor
        if field.stringValue != value { field.stringValue = value }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { onChange(field.stringValue) }
        }
    }
}

/// Takes the keyboard the moment it joins the window. Keys typed before that go through
/// AnnotationEditor.key, so no key falls between the two.
private final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: stringValue.utf16.count, length: 0)
    }
}

private struct AnnotationCanvas: View {
    var document: AnnotationDocument
    var selectedID: UUID?
    var editingID: UUID?
    var cropTool: Bool
    var region: CGRect
    var body: some View {
        Canvas { context, size in
            let p = AnnotationProjection(visibleRegion: region, viewportSize: size)
            // Gives a white image an edge against the window background.
            var edge = context
            edge.addFilter(.shadow(color: .black.opacity(0.18), radius: 14, y: 5))
            edge.fill(Path(p.imageRect), with: .color(.white))
            context.withCGContext { cg in
                cg.saveGState()
                cg.clip(to: p.imageRect)
                cg.translateBy(x: p.imageRect.minX, y: p.imageRect.minY)
                cg.scaleBy(x: p.scale, y: p.scale)
                cg.translateBy(x: -region.minX, y: -region.minY)
                AnnotationRenderer.drawBase(document.baseImage, bounds: document.bounds, in: cg)
                AnnotationRenderer.draw(document, in: cg, skipping: editingID)
                cg.restoreGState()
            }
            if cropTool, let crop = document.crop {
                let rect = p.viewRect(for: crop)
                var dim = Path(p.imageRect)
                dim.addRect(rect)
                context.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                var border = context
                border.addFilter(.shadow(color: .black.opacity(0.35), radius: 2, y: 1))
                border.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
                var brackets = Path()
                for (index, corner) in rect.corners.enumerated() {
                    let x: CGFloat = index == 0 || index == 3 ? 1 : -1
                    let y: CGFloat = index < 2 ? 1 : -1
                    brackets.move(to: corner + CGPoint(x: x * 16, y: 0))
                    brackets.addLine(to: corner)
                    brackets.addLine(to: corner + CGPoint(x: 0, y: y * 16))
                }
                border.stroke(brackets, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                for point in rect.cropHandles.dropFirst(4) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                        with: .color(.white))
                }
                let label = Text(verbatim: "\(Int(crop.width)) × \(Int(crop.height))").font(
                    .system(size: 11, weight: .medium)
                )
                .foregroundColor(.white)
                let y = rect.maxY + 26 < p.imageRect.maxY ? rect.maxY + 15 : rect.maxY - 15
                let width = context.resolve(label).measure(in: CGSize(width: 200, height: 30)).width + 16
                let labelRect = CGRect(x: rect.midX - width / 2, y: y - 10, width: width, height: 20)
                context.fill(Path(roundedRect: labelRect, cornerRadius: 10), with: .color(.black.opacity(0.75)))
                context.draw(label, at: CGPoint(x: rect.midX, y: y))
            } else if let selected = document.annotations.first(where: { $0.id == selectedID }), editingID == nil {
                if case .text(let text) = selected.shape {
                    let rect = p.viewRect(for: AnnotationRenderer.textRect(text, bounds: document.bounds))
                    context.stroke(
                        Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: text.fontSize * 0.3 * p.scale),
                        with: .color(.white), lineWidth: 1)
                }
                for (_, point) in selected.handles {
                    let point = p.viewPoint(for: point)
                    let path = Path(ellipseIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
                    var shadow = context
                    shadow.addFilter(.shadow(color: .black.opacity(0.35), radius: 2, y: 1))
                    shadow.fill(path, with: .color(.white))
                    context.stroke(path, with: .color(.black.opacity(0.65)), lineWidth: 0.75)
                }
            }
        }
    }
}
