import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var recentCapturesItem: NSMenuItem!
    private var recordingItem: NSMenuItem!
    private var recordingScopedFolder: URL?
    private var statusButton: NSStatusBarButton?
    private var recordingStart: Date?
    private var recordingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NotificationCenter.default.addObserver(self,
            selector: #selector(startCapture), name: .snipHotkeyFired, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(toggleRecording), name: .snipRecordingHotkeyFired, object: nil)
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
            btn.image = AppDelegate.idleIcon
            statusButton = btn
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

        let timed = NSMenuItem(title: "Timed Full-Screen Capture", action: nil, keyEquivalent: "")
        let timedSubmenu = NSMenu()
        for seconds in [3, 5, 10] {
            let item = NSMenuItem(title: "\(seconds) Second Delay…",
                                  action: #selector(startTimedCapture(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            timedSubmenu.addItem(item)
        }
        timed.submenu = timedSubmenu
        menu.addItem(timed)

        let scrolling = NSMenuItem(title: "Scrolling Capture", action: #selector(startScrollingCapture), keyEquivalent: "")
        scrolling.target = self
        menu.addItem(scrolling)

        let recording = NSMenuItem(title: recordingIdleTitle(), action: #selector(toggleRecording), keyEquivalent: "")
        recording.target = self
        menu.addItem(recording)
        recordingItem = recording

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
        "Capture Area  \(HotkeyManager.shared.displayString(for: .capture))"
    }

    private func recordingIdleTitle() -> String {
        "Start Screen Recording  \(HotkeyManager.shared.displayString(for: .toggleRecording))"
    }

    @objc private func shortcutChanged() {
        captureItem.title = captureTitle()
        // Only touch the recording item's title when idle — while recording
        // it's showing the live elapsed-time counter instead.
        if !ScreenRecorder.shared.isRecording {
            recordingItem.title = recordingIdleTitle()
        }
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
            guard let thumb = entry.image.copy() as? NSImage else { continue }
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

        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecordingAccess {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    SelectionOverlayController.shared.show()
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            SelectionOverlayController.shared.show()
        }
    }

    @objc private func startTimedCapture(_ sender: NSMenuItem) {
        let delay = sender.tag
        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecordingAccess { TimedCaptureController.shared.start(delay: delay) }
            return
        }
        TimedCaptureController.shared.start(delay: delay)
    }

    @objc private func startScrollingCapture() {
        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecordingAccess { ScrollingCaptureController.shared.start() }
            return
        }
        ScrollingCaptureController.shared.start()
    }

    // MARK: - Screen Recording

    @objc private func toggleRecording() {
        if ScreenRecorder.shared.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecordingAccess { [weak self] in self?.beginRecording() }
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        if let folder = RecordingFolderManager.shared.folderURL {
            record(in: folder)
        } else {
            RecordingFolderManager.shared.choose { [weak self] url in
                guard let url else { return }
                self?.record(in: url)
            }
        }
    }

    private func record(in folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let destination = folder.appendingPathComponent("SnipClip Recording \(formatter.string(from: Date())).mp4")

        ScreenRecorder.shared.start(to: destination) { [weak self] error in
            guard let self else { return }
            if let error {
                if scoped { folder.stopAccessingSecurityScopedResource() }
                NSAlert(error: error).runModal()
                return
            }
            self.recordingScopedFolder = scoped ? folder : nil
            self.beginRecordingIndicator()
        }
    }

    private func stopRecording() {
        endRecordingIndicator()
        ScreenRecorder.shared.stop { [weak self] url, error in
            guard let self else { return }

            // Reveal the file *before* releasing the folder's security scope —
            // Finder needs that sandbox extension still held to open the path
            // at all, otherwise it fails with "client lacks entitlements".
            // activateFileViewerSelecting hands off to Finder over an Apple
            // Event and returns immediately, so give it a moment to actually
            // act on it before we let the scope go.
            if let error {
                NSAlert(error: error).runModal()
            } else if let url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

            if let folder = self.recordingScopedFolder {
                self.recordingScopedFolder = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
        }
    }

    /// Full-color icon in place of the template one, since a status item's
    /// contentTintColor has proven unreliable — it rendered as near-black on
    /// test hardware regardless of the color used. Swapping the actual image
    /// for a genuinely non-template one sidesteps that entirely.
    private static let idleIcon: NSImage = {
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnipClip")!
        img.isTemplate = true
        return img
    }()

    private static let recordingIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)])
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnipClip — Recording")!
            .withSymbolConfiguration(config)!
        img.isTemplate = false
        return img
    }()

    /// Red icon + a live "mm:ss" elapsed time, both in the menu bar itself
    /// and in the menu item — a basic but visible recording indicator.
    private func beginRecordingIndicator() {
        statusButton?.image = AppDelegate.recordingIcon
        recordingStart = Date()
        updateRecordingTitle()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateRecordingTitle()
        }
        RunLoop.main.add(t, forMode: .common)
        recordingTimer = t
    }

    private func endRecordingIndicator() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStart = nil
        statusButton?.image = AppDelegate.idleIcon
        statusButton?.title = ""
        recordingItem.title = recordingIdleTitle()
    }

    private func updateRecordingTitle() {
        guard let start = recordingStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        statusButton?.title = " \(text)"
        recordingItem.title = "Stop Screen Recording (\(text))"
    }

    /// Always surfaces visible feedback — never fails silently, even if the
    /// system permission prompt or Settings deep link doesn't fire (seen on
    /// some macOS versions where the prompt is suppressed for the first call).
    /// - Parameter onGranted: run immediately if access turns out to already
    ///   be granted (a stale preflight check). Not called if the user has to
    ///   go grant it in Settings — that always requires a relaunch anyway.
    private func requestScreenRecordingAccess(onGranted: @escaping () -> Void = {}) {
        NSApp.activate(ignoringOtherApps: true)
        let alreadyGranted = CGRequestScreenCaptureAccess()
        if alreadyGranted {
            onGranted()
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
