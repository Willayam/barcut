import SwiftUI

struct ImageHistoryView: View {
    static let width: CGFloat = 280
    static let headerHeight: CGFloat = 43
    static let rowHeight: CGFloat = 156
    static let rowSpacing: CGFloat = 8
    static let listPadding: CGFloat = 8
    static let emptyStateHeight: CGFloat = 118

    @ObservedObject var monitor: ClipboardMonitor
    let onAnnotate: (NSImage, AnnotationTool) -> Void

    static func preferredContentHeight(for imageCount: Int) -> CGFloat {
        if imageCount == 0 {
            return headerHeight + emptyStateHeight
        }

        let visibleRows = min(imageCount, 3)
        let listHeight = listPadding * 2
            + CGFloat(visibleRows) * rowHeight
            + CGFloat(max(visibleRows - 1, 0)) * rowSpacing
        return headerHeight + listHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if monitor.images.isEmpty {
                emptyState
            } else {
                imageList
            }
        }
        .frame(
            width: Self.width,
            height: Self.preferredContentHeight(for: monitor.images.count)
        )
    }

    private var header: some View {
        HStack {
            Text("BarCut")
                .font(.headline)
            Spacer()
            if !monitor.images.isEmpty {
                Button("Clear") {
                    monitor.clearHistory()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: Self.headerHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No images yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Take a screenshot to get started")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.emptyStateHeight)
    }

    private var imageList: some View {
        ScrollView {
            LazyVStack(spacing: Self.rowSpacing) {
                ForEach(monitor.images) { entry in
                    ImageHistoryRow(
                        image: entry.image,
                        isCopied: monitor.lastCopiedID == entry.id,
                        onCopy: {
                            monitor.copyAndFlash(entry)
                        },
                        onAnnotate: { tool in
                            onAnnotate(entry.image, tool)
                        }
                    )
                }
            }
            .padding(Self.listPadding)
        }
        .frame(height: Self.preferredContentHeight(for: monitor.images.count) - Self.headerHeight)
    }
}

private struct ImageHistoryRow: View {
    let image: NSImage
    let isCopied: Bool
    let onCopy: () -> Void
    let onAnnotate: (AnnotationTool) -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, minHeight: ImageHistoryView.rowHeight, maxHeight: ImageHistoryView.rowHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture(perform: onCopy)
                .help("Click to copy to clipboard")

            if isCopied {
                copiedOverlay
                    .allowsHitTesting(false)
            }

            if isHovering {
                hoverToolbar
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var copiedOverlay: some View {
        ZStack {
            Text("Copied!")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassRounded(cornerRadius: 8)
    }

    private var hoverToolbar: some View {
        HStack(spacing: 4) {
            toolbarButton(systemName: "doc.on.doc", help: "Copy") {
                onCopy()
            }

            toolbarButton(systemName: "textformat", help: "Annotate with text") {
                onAnnotate(.text)
            }

            toolbarButton(systemName: "arrow.up.right", help: "Annotate with arrow") {
                onAnnotate(.arrow)
            }
        }
        .padding(6)
        .clearLiquidGlassCapsule(interactive: true)
    }

    private func toolbarButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))
                    .blur(radius: 1.2)

                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.65), radius: 1.6, y: 0.5)
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
