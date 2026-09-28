import AppKit

// Shared helpers used across capture, recording, editor and app-shell code.

enum AppAlert {
    /// Modal alert, activating the app first so it never appears behind
    /// another app's windows (SnipClip is an accessory/menu-bar app).
    static func show(title: String, message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func show(error: Error, title: String) {
        show(title: title, message: error.localizedDescription)
    }
}

enum AppSettings {
    private static let copyOnCaptureKey = "snipclip_copy_on_capture"
    private static let recordSystemAudioKey = "snipclip_record_system_audio"
    private static let saveFormatKey = "snipclip_save_format"

    /// Copy each new capture to the clipboard as soon as it's taken.
    static var copyOnCapture: Bool {
        get { UserDefaults.standard.object(forKey: copyOnCaptureKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: copyOnCaptureKey) }
    }

    static var recordSystemAudio: Bool {
        get { UserDefaults.standard.bool(forKey: recordSystemAudioKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordSystemAudioKey) }
    }

    /// "png" or "jpeg" — the format last chosen in a save panel.
    static var saveFormat: String {
        get { UserDefaults.standard.string(forKey: saveFormatKey) ?? "png" }
        set { UserDefaults.standard.set(newValue, forKey: saveFormatKey) }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func timestampedFileName(prefix: String = "SnipClip", ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date())).\(ext)"
    }
}

/// The single hand-off point for every finished still capture (region,
/// window, full screen, timed, scrolling): clipboard, history, editor.
enum CaptureDelivery {
    static func deliver(_ image: NSImage) {
        if AppSettings.copyOnCapture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        let entry = CaptureHistory.shared.record(image)
        MarkupEditorController.shared.show(image: image, entry: entry)
    }
}
