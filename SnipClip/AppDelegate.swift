import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var recentCapturesItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NotificationCenter.default.addObserver(self,
            selector: #selector(startCapture), name: .snipHotkeyFired, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(shortcutChanged), name: .snipShortcutChanged, object: nil)
        HotkeyManager.shared.start()
        CGRequestScreenCaptureAccess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "camera.viewfinder",
                                accessibilityDescription: "SnipClip")
            btn.image?.isTemplate = true
        }

        let menu = NSMenu()
        let capture = NSMenuItem(title: captureTitle(), action: #selector(startCapture), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        captureItem = capture

        let recent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let recentSubmenu = NSMenu()
        recent.submenu = recentSubmenu
        menu.addItem(recent)
        recentCapturesItem = recent

        menu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let privacyItem = NSMenuItem(title: "Privacy Policy", action: #selector(openPrivacyPolicy), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)
        let supportItem = NSMenuItem(title: "Support", action: #selector(openSupport), keyEquivalent: "")
        supportItem.target = self
        menu.addItem(supportItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SnipClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func captureTitle() -> String {
        "Capture Area  \(HotkeyManager.shared.displayString)"
    }

    @objc private func shortcutChanged() {
        captureItem.title = captureTitle()
    }

    // MARK: - Recent Captures

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        rebuildRecentCaptures()
    }

    private func rebuildRecentCaptures() {
        let submenu = recentCapturesItem.submenu!
        submenu.removeAllItems()

        let entries = CaptureHistory.shared.entries
        guard !entries.isEmpty else {
            recentCapturesItem.isEnabled = false
            let empty = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        recentCapturesItem.isEnabled = true

        let formatter = DateFormatter()
        formatter.timeStyle = .short

        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: formatter.string(from: entry.date),
                                  action: #selector(reopenRecentCapture(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            let thumb = entry.image.copy() as! NSImage
            thumb.size = NSSize(width: 32, height: 32 * (thumb.size.height / max(thumb.size.width, 1)))
            item.image = thumb
            submenu.addItem(item)
        }
    }

    @objc private func reopenRecentCapture(_ sender: NSMenuItem) {
        let entries = CaptureHistory.shared.entries
        guard entries.indices.contains(sender.tag) else { return }
        MarkupEditorController.shared.show(image: entries[sender.tag].image)
    }

    @objc private func showPreferences() {
        PreferencesController.shared.show()
    }

    @objc private func openPrivacyPolicy() {
        NSWorkspace.shared.open(URL(string: "https://macbound.com/snipclip/privacy/")!)
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(URL(string: "https://macbound.com/snipclip/support/")!)
    }

    // MARK: - Capture

    private var lastCaptureRequest: Date = .distantPast

    @objc func startCapture() {
        // Carbon can deliver a hotkey-pressed event twice for a single keypress;
        // ignore repeat triggers that arrive within this window.
        let now = Date()
        guard now.timeIntervalSince(lastCaptureRequest) > 0.5 else { return }
        lastCaptureRequest = now

        guard PurchaseManager.shared.canUse else {
            PaywallController.shared.show()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecordingAccess()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            SelectionOverlayController.shared.show()
        }
    }

    /// Always surfaces visible feedback — never fails silently, even if the
    /// system permission prompt or Settings deep link doesn't fire (seen on
    /// some macOS versions where the prompt is suppressed for the first call).
    private func requestScreenRecordingAccess() {
        NSApp.activate(ignoringOtherApps: true)
        let alreadyGranted = CGRequestScreenCaptureAccess()
        if alreadyGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SelectionOverlayController.shared.show()
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Access Needed"
        alert.informativeText = "SnipClip needs Screen Recording permission to capture your screen. Click \"Open Settings\", then enable SnipClip under Privacy & Security → Screen Recording."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for urlString in candidates {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
