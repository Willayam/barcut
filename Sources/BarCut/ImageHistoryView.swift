import SwiftUI

struct ImageHistoryView: View {
    @ObservedObject var monitor: ClipboardMonitor

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
        .frame(width: 280)
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
        .padding(.vertical, 24)
    }

    private var imageList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(monitor.images.enumerated()), id: \.offset) { index, entry in
                    Button {
                        monitor.copyAndFlash(entry.image, index: index)
                    } label: {
                        ZStack {
                            Image(nsImage: entry.image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )

                            if monitor.lastCopiedIndex == index {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.ultraThinMaterial)
                                Text("Copied!")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy to clipboard")
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 400)
    }
}
