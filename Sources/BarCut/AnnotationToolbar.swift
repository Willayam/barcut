import SwiftUI

struct AnnotationToolbar: View {
    @ObservedObject var editor: AnnotationEditor

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button {
                        editor.chooseTool(tool)
                    } label: {
                        Image(systemName: tool.details.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(editor.tool == tool ? Color.accentColor.opacity(0.3) : .clear, in: Circle())
                    }
                    .help(tool.details.tooltip)
                    .accessibilityLabel(tool.details.label)
                }
                divider
                ForEach(AnnotationColor.allCases, id: \.self) { color in
                    Button {
                        editor.chooseColor(color)
                    } label: {
                        Circle().fill(Color(nsColor: color.nsColor)).frame(width: 16, height: 16)
                            .padding(3)
                            .overlay(Circle().stroke(editor.color == color ? Color.primary : .clear, lineWidth: 1.5))
                    }
                    .accessibilityLabel(color.rawValue.capitalized)
                    .help(color.rawValue.capitalized)
                }
                divider
                Button {
                    editor.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 30)
                }
                .disabled(!editor.document.canUndo)
                .help("Undo (⌘Z)").accessibilityLabel("Undo")
                Button {
                    editor.done()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 30)
                        .foregroundStyle(.white).background(Color.accentColor, in: Capsule())
                }
                .help("Copy and add to history (Return)").accessibilityLabel("Done")
            }
            .buttonStyle(.plain)
            .padding(8)
            .liquidGlassCapsule(interactive: true)
            Text(editor.tool.details.hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var divider: some View { Rectangle().fill(.secondary.opacity(0.25)).frame(width: 1, height: 22) }
}
