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
        let quitItem = NSMenuItem(title: "Quit SnipClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
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

    @objc func startCapture() {
        guard PurchaseManager.shared.canUse else {
            PaywallController.shared.show()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            SelectionOverlayController.shared.show()
        }
    }
}

private extension Notification.Name {
    static let snipHotkeyFired = Notification.Name("snipHotkeyFired")
}
