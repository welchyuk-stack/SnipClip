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
            case .capture, .toggleRecording: return UInt32(cmdKey | shiftKey | optionKey)
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

    /// Human-readable form, e.g. "⌥⇧⌘S", for menu items and the preferences UI.
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

    /// Must include ⌘, ⌥ or ⌃ — Shift alone is not enough for a global shortcut.
    static func isAcceptable(carbonModifiers: UInt32) -> Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    private static let characterKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]

    private static let functionKeys: [Int: (name: String, scalar: Int)] = [
        kVK_F1: ("F1", NSF1FunctionKey), kVK_F2: ("F2", NSF2FunctionKey),
        kVK_F3: ("F3", NSF3FunctionKey), kVK_F4: ("F4", NSF4FunctionKey),
        kVK_F5: ("F5", NSF5FunctionKey), kVK_F6: ("F6", NSF6FunctionKey),
        kVK_F7: ("F7", NSF7FunctionKey), kVK_F8: ("F8", NSF8FunctionKey),
        kVK_F9: ("F9", NSF9FunctionKey), kVK_F10: ("F10", NSF10FunctionKey),
        kVK_F11: ("F11", NSF11FunctionKey), kVK_F12: ("F12", NSF12FunctionKey),
        kVK_F13: ("F13", NSF13FunctionKey), kVK_F14: ("F14", NSF14FunctionKey),
        kVK_F15: ("F15", NSF15FunctionKey), kVK_F16: ("F16", NSF16FunctionKey),
        kVK_F17: ("F17", NSF17FunctionKey), kVK_F18: ("F18", NSF18FunctionKey),
        kVK_F19: ("F19", NSF19FunctionKey), kVK_F20: ("F20", NSF20FunctionKey),
        kVK_LeftArrow: ("←", NSLeftArrowFunctionKey), kVK_RightArrow: ("→", NSRightArrowFunctionKey),
        kVK_UpArrow: ("↑", NSUpArrowFunctionKey), kVK_DownArrow: ("↓", NSDownArrowFunctionKey),
    ]

    private static let otherKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static func keyCodeToString(_ keyCode: UInt32) -> String {
        let k = Int(keyCode)
        return characterKeys[k] ?? functionKeys[k]?.name ?? otherKeys[k] ?? "?"
    }

    /// (keyEquivalent, modifierMask) for NSMenuItem, or nil if not representable.
    func menuKeyEquivalent(for slot: Slot) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let k = Int(keyCode(for: slot))
        let key: String
        if let c = Self.characterKeys[k] {
            key = c.lowercased()
        } else if let f = Self.functionKeys[k], let scalar = UnicodeScalar(f.scalar) {
            key = String(Character(scalar))
        } else {
            return nil
        }
        let m = modifiers(for: slot)
        var flags: NSEvent.ModifierFlags = []
        if m & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if m & UInt32(optionKey) != 0 { flags.insert(.option) }
        if m & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if m & UInt32(controlKey) != 0 { flags.insert(.control) }
        return (key, flags)
    }

    private init() {}

    private var suspended = false

    /// Registers all slots; retries failures once after 1.5s, then reports on main.
    func start(onFailure: @escaping ([Slot]) -> Void) {
        suspended = false
        let failed = Slot.allCases.filter { !register($0) }
        guard !failed.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let stillFailed = failed.filter { !self.register($0) }
            if !stillFailed.isEmpty { onFailure(stillFailed) }
        }
    }

    /// Validates, persists and re-registers. Reverts and returns false on duplicate or failure.
    @discardableResult
    func update(_ slot: Slot, keyCode: UInt32, modifiers: UInt32) -> Bool {
        for other in Slot.allCases where other != slot {
            if self.keyCode(for: other) == keyCode && self.modifiers(for: other) == modifiers { return false }
        }
        let d = UserDefaults.standard
        let prevKey = d.object(forKey: slot.keyCodeDefaultsKey)
        let prevMods = d.object(forKey: slot.modifiersDefaultsKey)
        d.set(Int(keyCode), forKey: slot.keyCodeDefaultsKey)
        d.set(Int(modifiers), forKey: slot.modifiersDefaultsKey)
        if suspended { return true }
        if register(slot) { return true }
        // Revert.
        if let prevKey { d.set(prevKey, forKey: slot.keyCodeDefaultsKey) } else { d.removeObject(forKey: slot.keyCodeDefaultsKey) }
        if let prevMods { d.set(prevMods, forKey: slot.modifiersDefaultsKey) } else { d.removeObject(forKey: slot.modifiersDefaultsKey) }
        register(slot)
        return false
    }

    func resetToDefault(_ slot: Slot) {
        UserDefaults.standard.removeObject(forKey: slot.keyCodeDefaultsKey)
        UserDefaults.standard.removeObject(forKey: slot.modifiersDefaultsKey)
        if !suspended { register(slot) }
    }

    /// Unregister all hotkeys while the shortcut recorder captures keys.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for slot in Slot.allCases { register(slot) }
    }

    @discardableResult
    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID), nil,
                                            MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, hkID.signature == 0x534E4950,
                  let slot = HotkeyManager.Slot(rawValue: hkID.id) else { return noErr }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: slot.notification, object: nil)
            }
            return noErr
        }, 1, &spec, nil, &eventHandlerRef)
        if status != noErr {
            NSLog("SnipClip: InstallEventHandler failed: \(status)")
            eventHandlerRef = nil
            return false
        }
        return true
    }

    @discardableResult
    private func register(_ slot: Slot) -> Bool {
        guard installEventHandlerIfNeeded() else { return false }
        if let ref = hotKeyRefs[slot] { UnregisterEventHotKey(ref); hotKeyRefs[slot] = nil }

        var hkID = EventHotKeyID(); hkID.signature = 0x534E4950; hkID.id = slot.rawValue
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode(for: slot), modifiers(for: slot), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("SnipClip: RegisterEventHotKey failed for \(slot): \(status)")
            return false
        }
        hotKeyRefs[slot] = ref
        return true
    }

    private func unregisterAll() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    func stop() {
        unregisterAll()
        if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
    }
}

extension Notification.Name {
    static let snipHotkeyFired = Notification.Name("snipHotkeyFired")
    static let snipRecordingHotkeyFired = Notification.Name("snipRecordingHotkeyFired")
}
