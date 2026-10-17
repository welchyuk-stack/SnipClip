import AppKit
import StoreKit

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

// MARK: - Review prompt

/// Asks for an App Store rating via StoreKit after the user has exported
/// from the editor a few times. At most once per app version; macOS applies
/// its own frequency cap on top and may show nothing. No network or tracking.
enum ReviewPrompter {
    private static let exportCountKey = "snipclip_review_export_count"
    private static let lastPromptedVersionKey = "snipclip_review_last_prompted_version"
    private static let requiredExports = 3

    /// Call after a successful Copy or Save from the markup editor.
    static func recordSuccessfulExport() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: exportCountKey) + 1
        defaults.set(count, forKey: exportCountKey)

        let version = AppSettings.appVersion
        guard count >= requiredExports,
              defaults.string(forKey: lastPromptedVersionKey) != version else { return }

        // Let the Copied/Saved confirmation play first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !ScreenRecorder.shared.isActive,
                  defaults.string(forKey: lastPromptedVersionKey) != version else { return }
            defaults.set(version, forKey: lastPromptedVersionKey)
            SKStoreReviewController.requestReview()
        }
    }
}
