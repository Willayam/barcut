import Carbon.HIToolbox
import Combine
import Darwin
import ServiceManagement
import SwiftUI

@main
enum BarCutApp {
    static func main() {
        let storeKey = ProcessInfo.processInfo.environment["BARCUT_STORE_DIR"] ?? "production"
        let lockName = storeKey.replacingOccurrences(of: "/", with: "_")
        let lockPath = NSTemporaryDirectory() + "com.williamlarsten.BarCut.\(lockName).lock"
        let lockDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.williamlarsten.BarCut")
                .first?
                .activate()
            return
        }
        defer { close(lockDescriptor) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = ClipboardMonitor()
    private var editorWindows: [NSWindow] = []
    private let panel = HistoryPanel(
        shortcutEnabled: UserDefaults.standard.object(forKey: "openShortcutEnabled") as? Bool ?? true
    )
    private var cancellables: Set<AnyCancellable> = []
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    /// The app in front when the popover opened. A click or the shortcut makes BarCut the
    /// active app, so this one gets the keyboard back afterwards.
    private var previousApp: NSRunningApplication?
    /// Set while the shortcut opened the history and ⌘ is still down. Letting go copies the
    /// selection, the way ⌘Tab switches apps on release.
    private var browsing: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "BarCut")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ImageHistoryView(
                monitor: monitor,
                panel: panel,
                onAnnotate: { [weak self] entry, tool in
                    Task { @MainActor in
                        guard let self, let image = await self.monitor.fullImage(for: entry) else { return }
                        self.openAnnotationEditor(image: image, initialTool: tool)
                    }
                },
                onClear: { [weak self] in
                    self?.confirmClearHistory()
                }
            )
        )

        monitor.$images
            .sink { [weak self] images in
                self?.popover.contentSize = NSSize(
                    width: ImageHistoryView.width,
                    height: ImageHistoryView.preferredContentHeight(for: images.count)
                )
            }
            .store(in: &cancellables)

        // Copying is the last step in the popover. The keyboard goes back at once, so ⌘V right
        // after the copy reaches the app the user came from. The popover leaves once "Copied" has
        // shown, and a transient popover would close the moment BarCut stops being active.
        let copied = monitor.$lastCopiedID
            .filter { [weak self] id in id != nil && self?.popover.isShown == true }
        copied
            .sink { [weak self] _ in
                self?.browsing = nil
                self?.popover.behavior = .applicationDefined
                self?.returnKeyboard()
            }
            .store(in: &cancellables)
        copied
            .delay(for: .seconds(0.6), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.popover.close()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification, object: popover)
            .sink { [weak self] _ in
                self?.browsing = nil
                self?.popover.behavior = .transient
                self?.previousApp = nil
                self?.panel.selectedID = nil
            }
            .store(in: &cancellables)

        // Key presses reach BarCut only while it is active, which the shortcut arranges.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown,
                  event.window === self.popover.contentViewController?.view.window,
                  self.handlePopoverKey(event) else { return event }
            return nil
        }

        if ProcessInfo.processInfo.environment["BARCUT_SHORTCUT"] != "0" {
            panel.$shortcutEnabled
                .sink { [weak self] enabled in
                    UserDefaults.standard.set(enabled, forKey: "openShortcutEnabled")
                    self?.hotKey = enabled ? GlobalHotKey.openHistory { self?.shortcutPressed() } : nil
                }
                .store(in: &cancellables)
        }
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["BARCUT_ANNOTATE"], FileManager.default.isReadableFile(atPath: path),
           let image = NSImage(contentsOfFile: path) {
            openAnnotationEditor(image: image, initialTool: environment["BARCUT_ANNOTATE_TOOL"] == "crop" ? .crop : .arrow)
        }
    }

    @objc private func statusItemClicked() {
        togglePopover(fromKeyboard: false)
    }

    /// Pressing 2 again with ⇧⌘ still down moves to the next image.
    private func shortcutPressed() {
        if browsing != nil {
            moveSelection(by: 1)
        } else {
            togglePopover(fromKeyboard: true)
        }
    }

    private func togglePopover(fromKeyboard: Bool) {
        if popover.isShown {
            returnKeyboard()
            popover.performClose(nil)
        } else {
            showPopover(fromKeyboard: fromKeyboard)
        }
    }

    private func showPopover(fromKeyboard: Bool) {
        guard let button = statusItem.button else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        if fromKeyboard {
            panel.selectedID = monitor.images.first?.id
            NSApplication.shared.activate(ignoringOtherApps: true)
            // Polls rather than waiting for a key event, because ⌘ can come up before BarCut is
            // active and that event then goes to the other app. Waiting until BarCut is active
            // keeps the copy from handing the keyboard back before BarCut has taken it.
            browsing = Timer.publish(every: 0.03, on: .main, in: .common)
                .autoconnect()
                .filter { _ in NSApplication.shared.isActive && !NSEvent.modifierFlags.contains(.command) }
                .first()
                .sink { [weak self] _ in self?.copySelection() }
        }
        popover.contentSize = NSSize(
            width: ImageHistoryView.width,
            height: ImageHistoryView.preferredContentHeight(for: monitor.images.count)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func returnKeyboard() {
        guard let app = previousApp, NSApplication.shared.isActive else { return }
        previousApp = nil
        app.activate(from: .current, options: [])
    }

    /// Clearing deletes every stored image and cannot be undone, so it asks first.
    private func confirmClearHistory() {
        let count = monitor.images.count
        let returnTo = previousApp
        popover.close()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Clear the image from history?" : "Clear all \(count) images from history?"
        alert.informativeText = "BarCut deletes its saved copies. You can't undo this. Files in your screenshot folder stay where they are."
        let clear = alert.addButton(withTitle: "Clear History")
        clear.hasDestructiveAction = true
        // Return must not clear, so only Escape and a click have an effect.
        clear.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")

        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.clearHistory()
        }
        returnTo?.activate(from: .current, options: [])
    }

    /// Copies the selected image, or the newest when nothing is selected.
    @discardableResult
    private func copySelection() -> Bool {
        browsing = nil
        let images = monitor.images
        guard let entry = images.first(where: { $0.id == panel.selectedID }) ?? images.first else { return false }
        monitor.copy(entry)
        return true
    }

    private func moveSelection(by offset: Int) {
        let images = monitor.images
        guard let index = images.firstIndex(where: { $0.id == panel.selectedID }) else {
            panel.selectedID = images.first?.id
            return
        }
        panel.selectedID = images[safe: index + offset]?.id ?? panel.selectedID
    }

    private func handlePopoverKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            moveSelection(by: 1)
        case kVK_UpArrow:
            moveSelection(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return copySelection()
        case kVK_Escape:
            returnKeyboard()
            popover.performClose(nil)
        default:
            return false
        }
        return true
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

        window.setContentSize(contentSize)
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

        let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let imageSize = pixels.map { CGSize(width: $0.width, height: $0.height) } ?? image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: 760, height: 520)
        }

        let imageScale = min(
            (maxSize.width - 2 * AnnotationLayout.margin) / imageSize.width,
            (maxSize.height - 2 * AnnotationLayout.margin - AnnotationLayout.toolbarBand) / imageSize.height,
            1.0
        )
        let width = max(640, imageSize.width * imageScale + 2 * AnnotationLayout.margin)
        let height = max(420, imageSize.height * imageScale + 2 * AnnotationLayout.margin + AnnotationLayout.toolbarBand)

        return NSSize(width: width, height: height)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        editorWindows.removeAll { $0 === closingWindow }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            historyLogger.notice("login item change failed \(error.localizedDescription, privacy: .public)")
        }
        logStatus()
    }

    private static func logStatus() {
        historyLogger.notice("login item status \(SMAppService.mainApp.status.rawValue) at \(Bundle.main.bundlePath, privacy: .public)")
    }
}
