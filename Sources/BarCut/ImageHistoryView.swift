import SwiftUI

struct ImageHistoryView: View {
    static let width: CGFloat = 280
    static let headerHeight: CGFloat = 43
    static let rowHeight: CGFloat = 156
    static let rowSpacing: CGFloat = 8
    static let listPadding: CGFloat = 8
    static let emptyStateHeight: CGFloat = 118

    @ObservedObject var monitor: ClipboardMonitor
    let onAnnotate: (ImageHistoryEntry, AnnotationTool) -> Void
    @State private var loginItemEnabled = LoginItem.isEnabled

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
            Menu {
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { enabled in
                        LoginItem.setEnabled(enabled)
                        loginItemEnabled = LoginItem.isEnabled
                    }
                ))
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(monitor.images) { entry in
                        ImageHistoryRow(
                            thumbnail: entry.thumbnail,
                            isCopied: monitor.lastCopiedID == entry.id,
                            onCopy: {
                                monitor.copy(entry)
                            },
                            onAnnotate: { tool in
                                onAnnotate(entry, tool)
                            }
                        )
                        .id(entry.id)
                    }
                }
                .padding(Self.listPadding)
            }
            // The newest image is the one the user opens the popover for, so each open starts there.
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
                if let newest = monitor.images.first {
                    proxy.scrollTo(newest.id, anchor: .top)
                }
            }
        }
        .frame(height: Self.preferredContentHeight(for: monitor.images.count) - Self.headerHeight)
    }
}

/// The whole row copies. Annotation sits in a corner so a near miss still copies.
private struct ImageHistoryRow: View {
    let thumbnail: CGImage
    let isCopied: Bool
    let onCopy: () -> Void
    let onAnnotate: (AnnotationTool) -> Void

    @State private var isHovering = false

    private static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Button(action: onCopy) {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: fillsCard ? .fill : .fit)
                .frame(maxWidth: .infinity, minHeight: ImageHistoryView.rowHeight, maxHeight: ImageHistoryView.rowHeight)
                .background(Color.primary.opacity(0.06))
                .overlay(Color.black.opacity(isActive ? 0.14 : 0))
                .overlay {
                    if isActive {
                        copyBadge
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .clipShape(Self.shape)
                .overlay(
                    Self.shape.stroke(Color.white.opacity(isHovering ? 0.5 : 0.22), lineWidth: 0.8)
                )
                .contentShape(Self.shape)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("Copy image")
        .overlay(alignment: .topTrailing) {
            if isHovering {
                annotateButtons
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        // The popover can close with the pointer still inside, and no exit event follows.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            isHovering = false
        }
        .animation(.easeOut(duration: 0.12), value: isCopied)
    }

    private var isActive: Bool {
        isHovering || isCopied
    }

    /// A thumbnail close to the card's proportions fills it, which crops a sliver instead of leaving thin bars.
    private var fillsCard: Bool {
        let card = (ImageHistoryView.width - 2 * ImageHistoryView.listPadding) / ImageHistoryView.rowHeight
        let image = CGFloat(thumbnail.width) / CGFloat(max(thumbnail.height, 1))
        return max(card / image, image / card) < 1.12
    }

    private var copyBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(isCopied ? "Copied" : "Copy")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .darkLiquidGlassCapsule()
    }

    private var annotateButtons: some View {
        HStack(spacing: 2) {
            annotateButton(systemName: "textformat", help: "Annotate with text", tool: .text)
            annotateButton(systemName: "arrow.up.right", help: "Annotate with arrow", tool: .arrow)
        }
        .padding(2)
        .darkLiquidGlassCapsule()
    }

    private func annotateButton(systemName: String, help: String, tool: AnnotationTool) -> some View {
        Button {
            onAnnotate(tool)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
