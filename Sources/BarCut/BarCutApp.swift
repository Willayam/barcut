import Combine
import SwiftUI

@main
enum BarCutApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = ClipboardMonitor()
    private var interceptor: ScreenshotInterceptor?
    private var editorWindows: [NSWindow] = []
    private var monitorCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        interceptor = ScreenshotInterceptor(monitor: monitor)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "BarCut")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: ImageHistoryView.preferredContentHeight(for: monitor.images.count))
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ImageHistoryView(monitor: monitor) { [weak self] image, tool in
                self?.openAnnotationEditor(image: image, initialTool: tool)
            }
        )

        monitorCancellable = monitor.$images.sink { [weak self] images in
            self?.popover.contentSize = NSSize(
                width: ImageHistoryView.width,
                height: ImageHistoryView.preferredContentHeight(for: images.count)
            )
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentSize = NSSize(width: 280, height: ImageHistoryView.preferredContentHeight(for: monitor.images.count))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openAnnotationEditor(image: NSImage, initialTool: AnnotationTool) {
        let contentSize = editorContentSize(for: image)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Annotate Screenshot"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: AnnotationEditorView(
                image: image,
                initialTool: initialTool,
                onPreviewChanged: { [weak self] renderedImage in
                    self?.monitor.copyLiveAnnotatedImage(renderedImage)
                },
                onComplete: { [weak self, weak window] renderedImage in
                    self?.monitor.addAnnotatedImage(renderedImage)
                    window?.close()
                },
                onCancel: { [weak window] in
                    window?.close()
                }
            )
        )

        editorWindows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func editorContentSize(for image: NSImage) -> NSSize {
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxSize = NSSize(
            width: min(screenSize.width * 0.82, 1100),
            height: min(screenSize.height * 0.82, 800)
        )

        guard image.size.width > 0, image.size.height > 0 else {
            return NSSize(width: 760, height: 520)
        }

        let imageScale = min(
            (maxSize.width - 32) / image.size.width,
            (maxSize.height - 32) / image.size.height,
            1.0
        )
        let width = max(640, image.size.width * imageScale + 32)
        let height = max(420, image.size.height * imageScale + 32)

        return NSSize(width: width, height: height)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        editorWindows.removeAll { $0 === closingWindow }
    }
}
