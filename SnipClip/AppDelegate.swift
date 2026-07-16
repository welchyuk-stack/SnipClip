import AppKit
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupGlobalHotkey()
        PurchaseManager.shared.start()
        CGRequestScreenCaptureAccess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
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
        let captureItem = NSMenuItem(title: "Capture Area  ⌘⇧S", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        let unlockItem = NSMenuItem(title: "Unlock SnipClip…", action: #selector(showPaywall), keyEquivalent: "")
        unlockItem.target = self
        menu.addItem(unlockItem)
        menu.addItem(.separator())
        let privacyItem = NSMenuItem(title: "Privacy Policy", action: #selector(openPrivacyPolicy), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)
        let supportItem = NSMenuItem(title: "Support", action: #selector(openSupport), keyEquivalent: "")
        supportItem.target = self
        menu.addItem(supportItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SnipClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func showPaywall() {
        PaywallController.shared.show()
    }

    @objc private func openPrivacyPolicy() {
        NSWorkspace.shared.open(URL(string: "https://welchyuk-stack.github.io/SnipClip/privacy.html")!)
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(URL(string: "https://welchyuk-stack.github.io/SnipClip/support.html")!)
    }

    // MARK: - Global hotkey (Carbon — no Accessibility permission needed)

    private func setupGlobalHotkey() {
        // Post a notification from the C callback; observe it here
        NotificationCenter.default.addObserver(self,
            selector: #selector(startCapture),
            name: .snipHotkeyFired, object: nil)

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            NotificationCenter.default.post(name: .snipHotkeyFired, object: nil)
            return noErr
        }, 1, &spec, nil, &eventHandlerRef)

        var hkID = EventHotKeyID(); hkID.signature = 0x534E4950; hkID.id = 1
        RegisterEventHotKey(UInt32(kVK_ANSI_S),
                            UInt32(cmdKey | shiftKey),
                            hkID, GetApplicationEventTarget(),
                            0, &hotKeyRef)
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

private extension Notification.Name {
    static let snipHotkeyFired = Notification.Name("snipHotkeyFired")
}
