import AppKit

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Runs `action` once Screen Recording access is available, explaining
    /// the request first and guiding the user to System Settings if needed.
    static func ensureScreenRecording(then action: @escaping () -> Void) {
        if CGPreflightScreenCaptureAccess() { action(); return }

        NSApp.activate(ignoringOtherApps: true)
        let explain = NSAlert()
        explain.messageText = "Screen Recording Access Needed"
        explain.informativeText = "SnipClip needs Screen Recording access to capture your screen. macOS will ask you to allow it."
        explain.alertStyle = .informational
        explain.addButton(withTitle: "Continue")
        explain.addButton(withTitle: "Cancel")
        guard explain.runModal() == .alertFirstButtonReturn else { return }

        if CGRequestScreenCaptureAccess() { action(); return }

        openScreenRecordingSettings()

        let relaunchAlert = NSAlert()
        relaunchAlert.messageText = "Allow SnipClip in System Settings"
        relaunchAlert.informativeText = "After switching SnipClip on in System Settings, relaunch SnipClip to finish setting up."
        relaunchAlert.alertStyle = .informational
        relaunchAlert.addButton(withTitle: "Relaunch SnipClip")
        relaunchAlert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if relaunchAlert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    static func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
