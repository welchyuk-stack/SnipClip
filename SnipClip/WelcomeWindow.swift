import AppKit
import ServiceManagement

final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?
    private var permissionRow: NSStackView?
    private var loginCheckbox: NSButton?

    private override init() { super.init() }

    func show() {
        if let window {
            refreshPermissionRow()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to SnipClip"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = buildContent()
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        permissionRow = nil
        loginCheckbox = nil
    }

    private func featureRow(symbol: String, text: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func buildContent() -> NSView {
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 80).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let title = NSTextField(labelWithString: "Welcome to SnipClip")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let hk = HotkeyManager.shared
        let features = NSStackView(views: [
            featureRow(symbol: "viewfinder", text: "Capture a region — \(hk.displayString(for: .capture))"),
            featureRow(symbol: "record.circle", text: "Record your screen — \(hk.displayString(for: .toggleRecording))"),
            featureRow(symbol: "menubar.rectangle", text: "Everything else lives in the menu bar icon"),
            featureRow(symbol: "keyboard", text: "Change shortcuts any time in Settings"),
        ])
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 10

        let perm = NSStackView()
        perm.orientation = .horizontal
        perm.spacing = 8
        permissionRow = perm
        refreshPermissionRow()

        let login = NSButton(checkboxWithTitle: "Launch SnipClip at login", target: self, action: #selector(loginToggled(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginCheckbox = login

        let settings = NSButton(title: "Open Settings…", target: self, action: #selector(openSettings))
        let start = NSButton(title: "Get Started", target: self, action: #selector(getStarted))
        start.keyEquivalent = "\r"
        let buttons = NSStackView(views: [settings, start])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [iconView, title, features, perm, login, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(8, after: iconView)
        stack.setCustomSpacing(22, after: title)
        stack.setCustomSpacing(22, after: login)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 36, bottom: 24, right: 36)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        features.widthAnchor.constraint(lessThanOrEqualToConstant: 388).isActive = true
        return stack
    }

    private func refreshPermissionRow() {
        guard let row = permissionRow else { return }
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if CGPreflightScreenCaptureAccess() {
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            check.contentTintColor = .systemGreen
            let label = NSTextField(labelWithString: "Screen Recording allowed")
            label.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(check)
            row.addArrangedSubview(label)
        } else {
            row.addArrangedSubview(NSButton(title: "Allow Screen Recording…", target: self, action: #selector(allowScreenRecording)))
        }
    }

    @objc private func allowScreenRecording() {
        Permissions.ensureScreenRecording { [weak self] in self?.refreshPermissionRow() }
    }

    @objc private func loginToggled(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            AppAlert.show(error: error, title: "Couldn't Change Login Item")
        }
    }

    @objc private func openSettings() {
        window?.close()
        PreferencesController.shared.show()
    }

    @objc private func getStarted() {
        window?.close()
    }
}
