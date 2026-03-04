import Cocoa
import CoreGraphics

final class ScreenshotInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let monitor: ClipboardMonitor

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
        setupEventTap()
    }

    private func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<ScreenshotInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return interceptor.handleEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            print("BarCut: grant Accessibility access in System Settings > Privacy & Security > Accessibility")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if system disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasCtrl = flags.contains(.maskControl)

        // Only intercept Cmd+Shift (without Control — leave Cmd+Ctrl+Shift alone)
        guard hasCmd && hasShift && !hasCtrl else {
            return Unmanaged.passUnretained(event)
        }

        switch keycode {
        case 21: // 4 — selection capture
            captureScreenshot(interactive: true)
            return nil
        case 20: // 3 — full screen capture
            captureScreenshot(interactive: false)
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func captureScreenshot(interactive: Bool) {
        // Suppress clipboard & directory watchers before screencapture runs
        monitor.beginCapture()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

            var args = ["-c", "-x"] // clipboard, no sound
            if interactive { args.insert("-i", at: 0) }
            process.arguments = args

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    DispatchQueue.main.async { self?.monitor.endCapture() }
                    return
                }
                DispatchQueue.main.async { self?.processCapture() }
            } catch {
                DispatchQueue.main.async { self?.monitor.endCapture() }
            }
        }
    }

    private func processCapture() {
        let pasteboard = NSPasteboard.general
        guard let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil),
              let image = objects.first as? NSImage else { return }

        // Save to screenshot directory and register the path so the
        // directory watcher doesn't pick it up a second time.
        let savedPath = saveToDesktop(image)
        monitor.addScreenshot(image, savedPath: savedPath)
    }

    private func saveToDesktop(_ image: NSImage) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Screenshot \(formatter.string(from: Date())).png"
        let path = (monitor.screenshotDir as NSString).appendingPathComponent(filename)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        try? png.write(to: URL(fileURLWithPath: path))
        return path
    }
}
