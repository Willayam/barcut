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
            rootView: ImageHistoryView(monitor: monitor, panel: panel) { [weak self] entry, tool in
                Task { @MainActor in
                    guard let self, let image = await self.monitor.fullImage(for: entry) else { return }
                    self.openAnnotationEditor(image: image, initialTool: tool)
                }
            }
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
                    self?.hotKey = enabled ? GlobalHotKey.openHistory { self?.togglePopover(fromKeyboard: true) } : nil
                }
                .store(in: &cancellables)
        }
    }

    @objc private func statusItemClicked() {
        togglePopover(fromKeyboard: false)
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

    private func handlePopoverKey(_ event: NSEvent) -> Bool {
        let images = monitor.images
        let selectedIndex = images.firstIndex { $0.id == panel.selectedID }

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            panel.selectedID = images[safe: (selectedIndex ?? -1) + 1]?.id ?? panel.selectedID
        case kVK_UpArrow:
            panel.selectedID = images[safe: (selectedIndex ?? 1) - 1]?.id ?? panel.selectedID
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let entry = images[safe: selectedIndex ?? 0] else { return false }
            monitor.copy(entry)
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
