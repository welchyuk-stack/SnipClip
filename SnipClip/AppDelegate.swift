import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var recentCapturesItem: NSMenuItem!
    private var recordFullItem: NSMenuItem!
    private var recordRegionItem: NSMenuItem!
    private var stopRecordingItem: NSMenuItem!
    private var recordingScopedFolder: URL?
    private var statusButton: NSStatusBarButton?
    private var recordingStart: Date?
    private var recordingTimer: Timer?

    private static let welcomeKey = "snipclip_welcome_shown_v1"
    private static let reviewURL = URL(string: "macappstore://apps.apple.com/app/id6789209242?action=write-review")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(hotkeyCapture),
                                               name: HotkeyManager.Slot.capture.notification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hotkeyToggleRecording),
                                               name: HotkeyManager.Slot.toggleRecording.notification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutChanged),
                                               name: .snipShortcutChanged, object: nil)

        ScreenRecorder.shared.onUnexpectedStop = { [weak self] url, error in
            DispatchQueue.main.async { self?.handleUnexpectedStop(url: url, error: error) }
        }

        HotkeyManager.shared.start { [weak self] failed in
            DispatchQueue.main.async { self?.reportHotkeyFailures(failed) }
        }

        // Screen Recording access is deliberately NOT requested at launch
        // (silent login launches shouldn't prompt); each action asks via
        // Permissions.ensureScreenRecording when the user actually uses it.
        if !UserDefaults.standard.bool(forKey: AppDelegate.welcomeKey) {
            UserDefaults.standard.set(true, forKey: AppDelegate.welcomeKey)
            WelcomeWindowController.shared.show()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScreenRecorder.shared.isActive else { return .terminateNow }
        endRecordingIndicator()
        ScreenRecorder.shared.stop { [weak self] _, _ in
            if let folder = self?.recordingScopedFolder {
                folder.stopAccessingSecurityScopedResource()
                self?.recordingScopedFolder = nil
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
    }

    private func reportHotkeyFailures(_ slots: [HotkeyManager.Slot]) {
        for slot in slots {
            let alert = NSAlert()
            alert.messageText = "Shortcut Unavailable"
            alert.informativeText = "\(HotkeyManager.shared.displayString(for: slot)) is being used by another app, so SnipClip can't use it. Choose a different shortcut in Settings."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                showSettings()
                return
            }
        }
    }

    // MARK: - Status bar

    private func makeItem(_ title: String, _ action: Selector?, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = AppDelegate.idleIcon
            btn.imagePosition = .imageLeading
            statusButton = btn
        }

        let menu = NSMenu()
        captureItem = makeItem("Capture Region", #selector(startCapture))
        menu.addItem(captureItem)
        menu.addItem(makeItem("Capture Full Screen", #selector(startFullScreenCapture)))

        let timed = NSMenuItem(title: "Timed Capture", action: nil, keyEquivalent: "")
        let timedSubmenu = NSMenu()
        for seconds in [3, 5, 10] {
            timedSubmenu.addItem(makeItem("\(seconds) Seconds", #selector(startTimedCapture(_:)), tag: seconds))
        }
        timed.submenu = timedSubmenu
        menu.addItem(timed)
        menu.addItem(makeItem("Scrolling Capture", #selector(startScrollingCapture)))

        menu.addItem(.separator())
        recordFullItem = makeItem("Record Full Screen", #selector(recordFullScreen))
        recordRegionItem = makeItem("Record Selected Region", #selector(recordSelectedRegion))
        stopRecordingItem = makeItem("Stop Recording", #selector(stopRecordingAction))
        stopRecordingItem.isHidden = true
        menu.addItem(recordFullItem)
        menu.addItem(recordRegionItem)
        menu.addItem(stopRecordingItem)

        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu()
        menu.addItem(recent)
        recentCapturesItem = recent

        menu.addItem(.separator())
        let settings = makeItem("Settings…", #selector(showSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(makeItem("Welcome Guide", #selector(showWelcome)))
        menu.addItem(makeItem("Rate SnipClip…", #selector(rateApp)))
        menu.addItem(makeItem("Support", #selector(openSupport)))
        menu.addItem(makeItem("Privacy Policy", #selector(openPrivacyPolicy)))
        menu.addItem(makeItem("About SnipClip", #selector(showAbout)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SnipClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
        applyShortcuts()
    }

    private func applyShortcut(_ slot: HotkeyManager.Slot, to item: NSMenuItem, title: String) {
        if let eq = HotkeyManager.shared.menuKeyEquivalent(for: slot) {
            item.title = title
            item.keyEquivalent = eq.key
            item.keyEquivalentModifierMask = eq.modifiers
        } else {
            item.keyEquivalent = ""
            let display = HotkeyManager.shared.displayString(for: slot)
            item.title = display.isEmpty ? title : "\(title)  \(display)"
        }
    }

    private func applyShortcuts() {
        applyShortcut(.capture, to: captureItem, title: "Capture Region")
        applyShortcut(.toggleRecording, to: recordFullItem, title: "Record Full Screen")
        applyShortcut(.toggleRecording, to: stopRecordingItem, title: "Stop Recording")
        updateRecordingTitle()
    }

    @objc private func shortcutChanged() {
        applyShortcuts()
    }

    // MARK: - Recent Captures

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        rebuildRecentCaptures()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func thumbnail(for image: NSImage) -> NSImage? {
        let src = image.size
        guard src.width > 0, src.height > 0 else { return nil }
        let box: CGFloat = 32
        let scale = min(box / src.width, box / src.height)
        let size = NSSize(width: max(1, src.width * scale), height: max(1, src.height * scale))
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    private func rebuildRecentCaptures() {
        let submenu = recentCapturesItem.submenu!
        submenu.removeAllItems()

        let entries = CaptureHistory.shared.entries
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Captures", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        for (index, entry) in entries.enumerated() {
            let time = AppDelegate.timeFormatter.string(from: entry.date)
            let title = "\(time) · \(Int(entry.pixelSize.width)) × \(Int(entry.pixelSize.height))"
            let item = makeItem(title, #selector(reopenRecentCapture(_:)), tag: index)
            if let img = entry.image { item.image = thumbnail(for: img) }
            submenu.addItem(item)

            let copy = makeItem("Copy \(time)", #selector(copyRecentCapture(_:)), tag: index)
            copy.isAlternate = true
            copy.keyEquivalentModifierMask = .option
            copy.image = item.image
            submenu.addItem(copy)
        }
        submenu.addItem(.separator())
        submenu.addItem(makeItem("Clear Recent Captures", #selector(clearRecentCaptures)))
    }

    private func entry(at tag: Int) -> CaptureHistory.Entry? {
        let entries = CaptureHistory.shared.entries
        return entries.indices.contains(tag) ? entries[tag] : nil
    }

    @objc private func reopenRecentCapture(_ sender: NSMenuItem) {
        guard let entry = entry(at: sender.tag) else { return }
        guard let image = entry.image else {
            AppAlert.show(title: "Capture Unavailable", message: "This capture could no longer be loaded.")
            return
        }
        MarkupEditorController.shared.show(image: image, entry: entry)
    }

    @objc private func copyRecentCapture(_ sender: NSMenuItem) {
        guard let image = entry(at: sender.tag)?.image else {
            AppAlert.show(title: "Capture Unavailable", message: "This capture could no longer be loaded.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func clearRecentCaptures() {
        CaptureHistory.shared.clear()
    }

    // MARK: - App items

    @objc func showSettings() {
        PreferencesController.shared.show()
    }

    @objc private func showWelcome() {
        WelcomeWindowController.shared.show()
    }

    @objc private func rateApp() {
        NSWorkspace.shared.open(AppDelegate.reviewURL)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openPrivacyPolicy() {
        NSWorkspace.shared.open(URL(string: "https://macbound.com/snipclip/privacy/")!)
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(URL(string: "https://macbound.com/snipclip/support/")!)
    }

    // MARK: - Capture

    private var lastCaptureRequest: Date = .distantPast
    private var lastRecordingToggle: Date = .distantPast

    /// Carbon can deliver a hotkey event twice for one keypress.
    @objc private func hotkeyCapture() {
        let now = Date()
        guard now.timeIntervalSince(lastCaptureRequest) > 0.5 else { return }
        lastCaptureRequest = now
        startCapture()
    }

    @objc private func hotkeyToggleRecording() {
        let now = Date()
        guard now.timeIntervalSince(lastRecordingToggle) > 0.5 else { return }
        lastRecordingToggle = now
        if ScreenRecorder.shared.isActive { stopRecording() } else { recordFullScreen() }
    }

    @objc func startCapture() {
        Permissions.ensureScreenRecording {
            // Let the status menu finish closing before the overlay appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SelectionOverlayController.shared.begin(purpose: .capture) { selection in
                    guard let image = selection?.image else { return }
                    CaptureDelivery.deliver(image)
                }
            }
        }
    }

    @objc private func startFullScreenCapture() {
        Permissions.ensureScreenRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task { @MainActor in
                    if let image = await ScreenCapture.captureFullScreen() {
                        CaptureDelivery.deliver(image)
                    } else {
                        AppAlert.show(title: "Capture Failed", message: "SnipClip couldn't capture the screen. Please try again.")
                    }
                }
            }
        }
    }

    @objc private func startTimedCapture(_ sender: NSMenuItem) {
        let delay = sender.tag
        Permissions.ensureScreenRecording { TimedCaptureController.shared.start(delay: delay) }
    }

    @objc private func startScrollingCapture() {
        Permissions.ensureScreenRecording { ScrollingCaptureController.shared.start() }
    }

    // MARK: - Screen Recording

    @objc private func recordFullScreen() {
        guard !ScreenRecorder.shared.isActive else { stopRecording(); return }
        Permissions.ensureScreenRecording { [weak self] in
            self?.withRecordingFolder { folder in
                self?.record(in: folder, screen: ScreenCapture.screenUnderMouse(), region: nil)
            }
        }
    }

    @objc private func recordSelectedRegion() {
        guard !ScreenRecorder.shared.isActive else { stopRecording(); return }
        Permissions.ensureScreenRecording { [weak self] in
            self?.withRecordingFolder { folder in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    SelectionOverlayController.shared.begin(purpose: .recording) { selection in
                        guard let selection else { return }
                        self?.record(in: folder, screen: selection.screen, region: selection.rect)
                    }
                }
            }
        }
    }

    @objc private func stopRecordingAction() {
        stopRecording()
    }

    private func withRecordingFolder(_ then: @escaping (URL) -> Void) {
        if let folder = RecordingFolderManager.shared.folderURL {
            then(folder)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose a Recordings Folder"
        alert.informativeText = "Choose a folder for your recordings. SnipClip will save every screen recording there, and you can change it any time in Settings."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RecordingFolderManager.shared.choose { url in
            guard let url else { return }
            then(url)
        }
    }

    private func record(in folder: URL, screen: NSScreen, region: NSRect?) {
        guard !ScreenRecorder.shared.isActive else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        let destination = folder.appendingPathComponent(
            AppSettings.timestampedFileName(prefix: "SnipClip Recording", ext: "mp4"))

        ScreenRecorder.shared.start(to: destination, screen: screen, region: region,
                                    captureAudio: AppSettings.recordSystemAudio) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    if scoped { folder.stopAccessingSecurityScopedResource() }
                    self.recordingScopedFolder = nil
                    self.endRecordingIndicator()
                    AppAlert.show(error: error, title: "Couldn't Start Recording")
                    return
                }
                self.recordingScopedFolder = scoped ? folder : nil
                self.beginRecordingIndicator()
            }
        }
    }

    private func stopRecording() {
        endRecordingIndicator()
        ScreenRecorder.shared.stop { [weak self] url, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // Reveal *before* releasing the folder's security scope —
                // Finder needs the sandbox extension held to open the path.
                if let error {
                    AppAlert.show(error: error, title: "Recording Failed")
                } else if let url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                self.releaseScopeLater()
            }
        }
    }

    private func releaseScopeLater() {
        guard let folder = recordingScopedFolder else { return }
        recordingScopedFolder = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            folder.stopAccessingSecurityScopedResource()
        }
    }

    private func handleUnexpectedStop(url: URL?, error: Error) {
        endRecordingIndicator()
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        releaseScopeLater()
        let partial = url != nil ? " The part recorded so far has been saved." : ""
        AppAlert.show(title: "Recording Stopped Unexpectedly",
                      message: error.localizedDescription + partial)
    }

    private static let idleIcon: NSImage = {
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnipClip")!
        img.isTemplate = true
        return img
    }()

    /// A genuinely non-template red image — contentTintColor proved unreliable.
    private static let recordingIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)])
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnipClip — Recording")!
            .withSymbolConfiguration(config)!
        img.isTemplate = false
        return img
    }()

    private func beginRecordingIndicator() {
        statusButton?.image = AppDelegate.recordingIcon
        recordingStart = Date()
        recordFullItem.isHidden = true
        recordRegionItem.isHidden = true
        stopRecordingItem.isHidden = false
        updateRecordingTitle()

        recordingTimer?.invalidate()
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
        recordFullItem.isHidden = false
        recordRegionItem.isHidden = false
        stopRecordingItem.isHidden = true
    }

    private func updateRecordingTitle() {
        guard let start = recordingStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        statusButton?.title = " \(text)"
        applyShortcut(.toggleRecording, to: stopRecordingItem, title: "Stop Recording (\(text))")
    }
}
