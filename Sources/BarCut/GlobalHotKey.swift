import Carbon.HIToolbox

/// A system-wide key combination. Carbon delivers it without the Accessibility permission.
@MainActor
final class GlobalHotKey {
    /// Next to the macOS screenshot keys ⇧⌘3, ⇧⌘4 and ⇧⌘5.
    static let openHistoryLabel = "⇧⌘2"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    static func openHistory(action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey, action: action)
    }

    private init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: 0x4243_5554, id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard installStatus == noErr, registerStatus == noErr else {
            historyLogger.notice("shortcut unavailable, install \(installStatus) register \(registerStatus)")
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
