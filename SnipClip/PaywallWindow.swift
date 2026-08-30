import AppKit

// MARK: - Controller

final class PaywallController: NSObject, NSWindowDelegate {
    static let shared = PaywallController()
    private var window: PaywallWindow?

    private override init() { super.init() }

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = PaywallWindow()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Window

final class PaywallWindow: NSWindow {
    private var storeBtn: NSButton?
    private var appearanceObserver: NSKeyValueObservation?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 468),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "SnipClip"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        center()
        buildUI()
        // Keep the button's layer background in sync with the accent colour across
        // Light/Dark mode switches — CGColor captured at init time is static.
        appearanceObserver = observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.updateStoreBtnColor()
        }
    }

    private func updateStoreBtnColor() {
        storeBtn?.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    private func buildUI() {
        let blur = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        contentView = blur

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor, constant: -4),
            stack.widthAnchor.constraint(equalToConstant: 300),
        ])

        // ── Icon ──
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .light))
        iconView.contentTintColor = .controlAccentColor
        iconView.imageAlignment = .alignCenter
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.heightAnchor.constraint(equalToConstant: 58).isActive = true
        stack.addArrangedSubview(iconView)
        stack.setCustomSpacing(10, after: iconView)

        // ── App name ──
        let nameLabel = label("SnipClip", size: 22, weight: .bold, color: .labelColor)
        stack.addArrangedSubview(nameLabel)
        stack.setCustomSpacing(6, after: nameLabel)

        // ── Subtitle ──
        let pm = PurchaseManager.shared
        let subText = pm.trialActive
            ? "Your free trial ends in \(pm.trialTimeString)."
            : "Your free trial has ended. SnipClip is now a paid app — new copies are available on the App Store."
        let subLabel = label(subText, size: 13, weight: .regular, color: .secondaryLabelColor)
        subLabel.alignment = .center
        stack.addArrangedSubview(subLabel)
        stack.setCustomSpacing(22, after: subLabel)

        // ── Divider ──
        stack.addArrangedSubview(sep())
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        // ── Feature list ──
        let features = [
            ("camera.viewfinder",    "Capture any area of your screen"),
            ("pencil.and.outline",   "6 markup tools — pen, arrow, shapes, text"),
            ("doc.on.doc",           "Instant clipboard copy as you draw"),
            ("square.and.arrow.down","Save as PNG or JPEG"),
            ("checkmark.seal",       "Native macOS — no subscription, ever"),
        ]
        for (symbol, text) in features {
            stack.addArrangedSubview(featureRow(symbol: symbol, text: text))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Divider ──
        stack.addArrangedSubview(sep())
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── App Store link ──
        let storeBtn = NSButton()
        storeBtn.title = "View SnipClip on the App Store"
        storeBtn.bezelStyle = .regularSquare
        storeBtn.isBordered = false
        storeBtn.wantsLayer = true
        storeBtn.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        storeBtn.layer?.cornerRadius = 8
        storeBtn.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        storeBtn.contentTintColor = .white
        storeBtn.translatesAutoresizingMaskIntoConstraints = false
        storeBtn.heightAnchor.constraint(equalToConstant: 40).isActive = true
        storeBtn.widthAnchor.constraint(equalToConstant: 280).isActive = true
        storeBtn.target = self
        storeBtn.action = #selector(didTapAppStore)
        stack.addArrangedSubview(storeBtn)
        self.storeBtn = storeBtn
        stack.setCustomSpacing(10, after: storeBtn)

        // ── Restore link — for anyone who already bought the (now-retired) unlock ──
        let restoreBtn = NSButton()
        restoreBtn.title = "Restore Purchase"
        restoreBtn.bezelStyle = .inline
        restoreBtn.isBordered = false
        restoreBtn.font = NSFont.systemFont(ofSize: 12)
        restoreBtn.contentTintColor = .tertiaryLabelColor
        restoreBtn.target = self
        restoreBtn.action = #selector(didTapRestore)
        stack.addArrangedSubview(restoreBtn)
    }

    // MARK: Helpers

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.alignment = .center
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 2
        return f
    }

    private func sep() -> NSView {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true
        b.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return b
    }

    private func featureRow(symbol: String, text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        icon.contentTintColor = .controlAccentColor
        icon.imageAlignment = .alignCenter
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.textColor = .labelColor
        lbl.lineBreakMode = .byWordWrapping
        lbl.maximumNumberOfLines = 2

        row.addArrangedSubview(icon)
        row.addArrangedSubview(lbl)
        return row
    }

    // MARK: Actions

    @objc private func didTapAppStore() {
        NSWorkspace.shared.open(URL(string: "https://apps.apple.com/gb/app/snipclip/id6789209242")!)
    }

    @objc private func didTapRestore() {
        Task { @MainActor in
            await PurchaseManager.shared.restore()
            if PurchaseManager.shared.isUnlocked {
                self.close()
            } else {
                let alert = NSAlert()
                alert.messageText = "Nothing to Restore"
                alert.informativeText = "We couldn't find a previous purchase of SnipClip for this Apple ID."
                alert.alertStyle = .informational
                alert.runModal()
            }
        }
    }

    override var canBecomeKey: Bool { true }
}
