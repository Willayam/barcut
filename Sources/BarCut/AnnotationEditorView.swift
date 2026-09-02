import AppKit
import SwiftUI

struct AnnotationEditorView: View {
    let onPreviewChanged: (NSImage) -> Void
    let onComplete: (NSImage) -> Void
    let onCancel: () -> Void

    @State private var document: AnnotationDocument
    @State private var tool: AnnotationTool
    @State private var textPublishWorkItem: DispatchWorkItem?
    @FocusState private var focusedTextID: UUID?

    init(
        image: NSImage,
        initialTool: AnnotationTool,
        onPreviewChanged: @escaping (NSImage) -> Void,
        onComplete: @escaping (NSImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onPreviewChanged = onPreviewChanged
        self.onComplete = onComplete
        self.onCancel = onCancel
        _document = State(initialValue: AnnotationDocument(baseImage: image))
        _tool = State(initialValue: initialTool)
    }

    var body: some View {
        GeometryReader { proxy in
            let projection = document.projection(in: proxy.size)
            let rect = projection.imageRect

            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)

                Image(nsImage: document.baseImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 5)

                annotationLayer(using: projection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                toolbar
                    .position(x: rect.maxX - 96, y: rect.maxY - 28)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            editorButton(systemName: "checkmark", help: "Done") {
                textPublishWorkItem?.cancel()
                onComplete(document.render())
            }

            editorButton(systemName: "textformat", help: "Text", isActive: tool == .text) {
                tool = .text
            }

            editorButton(systemName: "arrow.up.right", help: "Arrow", isActive: tool == .arrow) {
                tool = .arrow
            }

            editorButton(systemName: "xmark", help: "Close") {
                textPublishWorkItem?.cancel()
                onCancel()
            }
        }
        .padding(6)
        .liquidGlassCapsule(interactive: true)
    }

    private func editorButton(
        systemName: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .frame(width: 28, height: 28)
                .background(isActive ? Color.accentColor.opacity(0.72) : Color.clear, in: Circle())
                .liquidGlassCircle(interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func annotationLayer(using projection: AnnotationProjection) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(annotationGesture(using: projection))

            Canvas { context, _ in
                // FIXME: Preview drawing uses SwiftUI Canvas while final rendering uses AppKit in AnnotationDocument.
                for arrow in document.arrows {
                    drawPreviewArrow(arrow, using: projection, context: &context)
                }

                if let pendingArrow = document.pendingArrow {
                    drawPreviewArrow(pendingArrow, using: projection, context: &context)
                }
            }
            .allowsHitTesting(false)

            ForEach(document.texts) { text in
                TextField("", text: textBinding(for: text.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: projection.displayFontSize(for: text), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .focused($focusedTextID, equals: text.id)
                    .position(projection.viewPoint(for: text.position))
            }
        }
        .clipped()
    }

    private func annotationGesture(using projection: AnnotationProjection) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard projection.containsViewPoint(value.location) else { return }

                if tool == .arrow {
                    document.updateArrow(to: projection.imagePoint(from: value.location))
                }
            }
            .onEnded { value in
                guard projection.containsViewPoint(value.location) else {
                    document.cancelPendingArrow()
                    return
                }

                switch tool {
                case .text:
                    addText(at: projection.imagePoint(from: value.location))
                case .arrow:
                    if document.finishArrow() {
                        publishLiveCopy()
                    }
                }
            }
    }

    private func addText(at point: CGPoint) {
        let textID = document.addText(at: point)
        publishLiveCopy()
        DispatchQueue.main.async {
            focusedTextID = textID
        }
    }

    private func textBinding(for id: TextAnnotation.ID) -> Binding<String> {
        Binding(
            get: {
                document.texts.first(where: { $0.id == id })?.value ?? ""
            },
            set: { value in
                document.updateText(id: id, value: value)
                scheduleTextLiveCopy()
            }
        )
    }

    private func publishLiveCopy() {
        textPublishWorkItem?.cancel()
        onPreviewChanged(document.render())
    }

    private func scheduleTextLiveCopy() {
        textPublishWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            onPreviewChanged(document.render())
        }

        textPublishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func drawPreviewArrow(
        _ arrow: ArrowAnnotation,
        using projection: AnnotationProjection,
        context: inout GraphicsContext
    ) {
        let start = projection.viewPoint(for: arrow.start)
        let end = projection.viewPoint(for: arrow.end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 18
        let headAngle = CGFloat.pi / 7

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(.red), lineWidth: 4)

        let firstHeadPoint = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let secondHeadPoint = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        var head = Path()
        head.move(to: firstHeadPoint)
        head.addLine(to: end)
        head.addLine(to: secondHeadPoint)
        context.stroke(head, with: .color(.red), lineWidth: 4)
    }
}
