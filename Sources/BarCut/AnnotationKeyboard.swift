import AppKit
import Carbon.HIToolbox
import SwiftUI

extension AnnotationEditor {
    /// Returns true when the editor used the key, so the window must not see it.
    func key(_ event: NSEvent, textFieldFocused: Bool) -> Bool {
        let code = Int(event.keyCode)
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let isReturn = code == kVK_Return || code == kVK_ANSI_KeypadEnter

        if editingID != nil {
            if isReturn || code == kVK_Escape {
                endText()
                if isReturn && command { done() }
                return true
            }
            // Fast typing outruns the text field, which only takes the keyboard on the next view update.
            guard !textFieldFocused, !command, !event.modifierFlags.contains(.control),
                let typed = event.characters, Self.isPrintable(typed)
            else { return false }
            appendText(typed)
            return true
        }

        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if command && character == "z" {
            undo(shift)
            return true
        }
        if isReturn || (command && character == "c") {
            done()
            return true
        }

        switch code {
        case kVK_Escape:
            escape()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelection()
            return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            let step: CGFloat = shift ? 10 : 1
            nudge(
                by: CGPoint(
                    x: code == kVK_LeftArrow ? -step : code == kVK_RightArrow ? step : 0,
                    y: code == kVK_UpArrow ? -step : code == kVK_DownArrow ? step : 0
                ))
            return true
        default:
            break
        }

        guard !command, !event.modifierFlags.contains(.control) else { return false }
        if let tool = AnnotationTool.allCases.first(where: { $0.details.shortcut == character }) {
            chooseTool(tool)
            return true
        }
        guard let typed = event.characters, Self.isPrintable(typed) else { return false }
        beginTypedText(typed)
        return true
    }

    private func escape() {
        if case .idle = interaction {
            if selectedID != nil {
                selectedID = nil
            } else {
                publishWork?.cancel()
                onCancel()
            }
        } else {
            document.cancelChange()
            interaction = .idle
        }
    }

    private func deleteSelection() {
        document.beginChange()
        if tool == .crop {
            document.setCrop(nil)
        } else if let selectedID {
            document.remove(selectedID)
            self.selectedID = nil
        }
        commit()
    }

    private func nudge(by delta: CGPoint) {
        guard let selectedID else { return }
        let bounds = region
        document.beginChange()
        document.update(selectedID) { $0.move(by: delta, inside: bounds) }
        commit()
    }

    /// Typing right after drawing an arrow labels it.
    private func beginTypedText(_ typed: String) {
        guard let selected = selection, case .arrow(let arrow) = selected.shape else {
            beginText(at: pointer ?? CGPoint(x: region.midX, y: region.midY), string: typed)
            return
        }
        let placement = arrow.labelPlacement(fontSize: document.creationSizes.fontSize, in: region)
        beginText(
            at: placement.position.clamped(to: region),
            anchor: placement.anchor,
            string: typed,
            color: selected.color
        )
    }

    /// Function and arrow keys arrive as private-use scalars from U+F700 up.
    private static func isPrintable(_ string: String) -> Bool {
        !string.isEmpty
            && string.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700
            }
    }
}

struct AnnotationInput: NSViewRepresentable {
    let editor: AnnotationEditor
    var projection: AnnotationProjection

    func makeNSView(context: Context) -> InputView { InputView(editor: editor, projection: projection) }
    func updateNSView(_ view: InputView, context: Context) { view.projection = projection }

    final class InputView: NSView {
        let editor: AnnotationEditor
        var projection: AnnotationProjection
        var keyMonitor: Any?
        var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        init(editor: AnnotationEditor, projection: AnnotationProjection) {
            self.editor = editor
            self.projection = projection
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            guard let window else { return }
            window.makeFirstResponder(self)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, event.window === window else { return event }
                return self.editor.key(event, textFieldFocused: window?.firstResponder is NSText) ? nil : event
            }
        }
        deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            editor.pointer = projection.containsViewPoint(point) ? projection.imagePoint(from: point) : nil
        }
        override func mouseExited(with event: NSEvent) { editor.pointer = nil }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            editor.mouseDown(
                convert(event.locationInWindow, from: nil), projection: projection, clicks: event.clickCount)
        }
        override func mouseDragged(with event: NSEvent) {
            editor.mouseDragged(
                convert(event.locationInWindow, from: nil), projection: projection,
                shift: event.modifierFlags.contains(.shift))
        }
        override func mouseUp(with event: NSEvent) {
            editor.mouseUp(convert(event.locationInWindow, from: nil), projection: projection)
        }
    }
}
