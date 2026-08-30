import AppKit
import Carbon.HIToolbox

/// Wraps the Carbon global hotkey (no Accessibility permission needed) so the
/// shortcut can be changed at runtime instead of being hardcoded to ⌘⇧S —
/// which otherwise silently steals "Save As" from any frontmost app that uses
/// the same combo while SnipClip is running.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private let keyCodeKey = "snipclip_hotkey_keycode"
    private let modifiersKey = "snipclip_hotkey_modifiers"

    /// Default: ⌘⇧S
    private let defaultKeyCode = UInt32(kVK_ANSI_S)
    private let defaultModifiers = UInt32(cmdKey | shiftKey)

    var keyCode: UInt32 {
        let stored = UserDefaults.standard.object(forKey: keyCodeKey) as? Int
        return stored.map(UInt32.init) ?? defaultKeyCode
    }

    var modifiers: UInt32 {
        let stored = UserDefaults.standard.object(forKey: modifiersKey) as? Int
        return stored.map(UInt32.init) ?? defaultModifiers
    }

    /// Human-readable form, e.g. "⌘⇧S", for menu items and the preferences UI.
    var displayString: String {
        Self.displayString(keyCode: keyCode, carbonModifiers: modifiers)
    }

    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyCodeToString(keyCode)
        return s
    }

    /// Minimal keyCode → letter/number mapping covering the keys people
    /// actually pick for a capture shortcut.
    private static func keyCodeToString(_ keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
            12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        ]
        return map[keyCode] ?? "?"
    }

    private init() {}

    func start() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(relayNotification),
            name: .snipHotkeyFiredInternal, object: nil)
        register()
    }

    /// Changes the shortcut, persists it, and re-registers immediately.
    func update(keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: modifiersKey)
        register()
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: keyCodeKey)
        UserDefaults.standard.removeObject(forKey: modifiersKey)
        register()
    }

    private func register() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }

        if eventHandlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            // Dispatch to main thread: Carbon events are typically delivered on the
            // main thread via GetApplicationEventTarget, but this guarantees it.
            let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .snipHotkeyFiredInternal, object: nil)
                }
                return noErr
            }, 1, &spec, nil, &eventHandlerRef)
            assert(installStatus == noErr, "InstallEventHandler failed: \(installStatus)")
        }

        var hkID = EventHotKeyID(); hkID.signature = 0x534E4950; hkID.id = 1
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        assert(regStatus == noErr, "RegisterEventHotKey failed: \(regStatus)")
    }

    func stop() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
    }

    @objc private func relayNotification() {
        NotificationCenter.default.post(name: .snipHotkeyFired, object: nil)
    }
}

extension Notification.Name {
    static let snipHotkeyFired = Notification.Name("snipHotkeyFired")
    fileprivate static let snipHotkeyFiredInternal = Notification.Name("snipHotkeyFiredInternal")
}
