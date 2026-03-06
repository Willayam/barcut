import Cocoa
import CoreGraphics

final class ScreenshotInterceptor {
    private static let keycode3: Int64 = 20  // "3" key — full screen capture
    private static let keycode4: Int64 = 21  // "4" key — selection capture

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

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
        case Self.keycode4:
            captureScreenshot(interactive: true)
            return nil
        case Self.keycode3:
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

            let succeeded = (try? process.run()).map { process.waitUntilExit(); return process.terminationStatus == 0 } ?? false

            DispatchQueue.main.async {
                if succeeded { self?.processCapture() }
                else { self?.monitor.endCapture() }
            }
        }
    }

    private func processCapture() {
        guard let image = monitor.imageFromClipboard() else {
            monitor.endCapture()
            return
        }

        let savedPath = saveToDesktop(image)
        monitor.addScreenshot(image, savedPath: savedPath)
    }

    private func saveToDesktop(_ image: NSImage) -> String? {
        let filename = "Screenshot \(Self.filenameFormatter.string(from: Date())).png"
        let path = (monitor.screenshotDir as NSString).appendingPathComponent(filename)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        try? png.write(to: URL(fileURLWithPath: path))
        return path
    }
}
