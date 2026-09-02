import AppKit
import Carbon.HIToolbox

/// Wraps Carbon global hotkeys (no Accessibility permission needed) so
/// shortcuts can be changed at runtime instead of being hardcoded — which
/// would otherwise silently steal that combo from any frontmost app that
/// uses it while SnipClip is running.
///
/// Supports multiple independent shortcut slots (capture, toggle recording)
/// sharing one Carbon event handler, dispatched by hotkey ID.
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Slot: UInt32, CaseIterable {
        case capture = 1
        case toggleRecording = 2

        var defaultKeyCode: UInt32 {
            switch self {
            case .capture: return UInt32(kVK_ANSI_S)
            case .toggleRecording: return UInt32(kVK_ANSI_R)
            }
        }
        var defaultModifiers: UInt32 {
            switch self {
            case .capture, .toggleRecording: return UInt32(cmdKey | shiftKey)
            }
        }
        var notification: Notification.Name {
            switch self {
            case .capture: return .snipHotkeyFired
            case .toggleRecording: return .snipRecordingHotkeyFired
            }
        }
        fileprivate var keyCodeDefaultsKey: String {
            switch self {
            case .capture: return "snipclip_hotkey_keycode"
            case .toggleRecording: return "snipclip_hotkey_record_keycode"
            }
        }
        fileprivate var modifiersDefaultsKey: String {
            switch self {
            case .capture: return "snipclip_hotkey_modifiers"
            case .toggleRecording: return "snipclip_hotkey_record_modifiers"
            }
        }
    }

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    func keyCode(for slot: Slot) -> UInt32 {
        let stored = UserDefaults.standard.object(forKey: slot.keyCodeDefaultsKey) as? Int
        return stored.map(UInt32.init) ?? slot.defaultKeyCode
    }

    func modifiers(for slot: Slot) -> UInt32 {
        let stored = UserDefaults.standard.object(forKey: slot.modifiersDefaultsKey) as? Int
        return stored.map(UInt32.init) ?? slot.defaultModifiers
    }

    /// Human-readable form, e.g. "⌘⇧S", for menu items and the preferences UI.
    func displayString(for slot: Slot) -> String {
        Self.displayString(keyCode: keyCode(for: slot), carbonModifiers: modifiers(for: slot))
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
    /// actually pick for a shortcut.
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
        for slot in Slot.allCases { register(slot) }
    }

    /// Changes a shortcut, persists it, and re-registers immediately.
    func update(_ slot: Slot, keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: slot.keyCodeDefaultsKey)
        UserDefaults.standard.set(Int(modifiers), forKey: slot.modifiersDefaultsKey)
        register(slot)
    }

    func resetToDefault(_ slot: Slot) {
        UserDefaults.standard.removeObject(forKey: slot.keyCodeDefaultsKey)
        UserDefaults.standard.removeObject(forKey: slot.modifiersDefaultsKey)
        register(slot)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID), nil,
                                            MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, let slot = HotkeyManager.Slot(rawValue: hkID.id) else { return noErr }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: slot.notification, object: nil)
            }
            return noErr
        }, 1, &spec, nil, &eventHandlerRef)
        assert(installStatus == noErr, "InstallEventHandler failed: \(installStatus)")
    }

    private func register(_ slot: Slot) {
        installEventHandlerIfNeeded()

        if let ref = hotKeyRefs[slot] { UnregisterEventHotKey(ref); hotKeyRefs[slot] = nil }

        var hkID = EventHotKeyID(); hkID.signature = 0x534E4950; hkID.id = slot.rawValue
        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(keyCode(for: slot), modifiers(for: slot), hkID,
                                            GetApplicationEventTarget(), 0, &ref)
        assert(regStatus == noErr, "RegisterEventHotKey failed: \(regStatus)")
        hotKeyRefs[slot] = ref
    }

    func stop() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
    }
}

extension Notification.Name {
    static let snipHotkeyFired = Notification.Name("snipHotkeyFired")
    static let snipRecordingHotkeyFired = Notification.Name("snipRecordingHotkeyFired")
}
