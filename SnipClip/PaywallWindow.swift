import AppKit

// MARK: - Controller

final class PaywallController {
    static let shared = PaywallController()
    private var window: PaywallWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = PaywallWindow()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - Window

final class PaywallWindow: NSWindow {

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
            : "Your free trial has ended."
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

        // ── CTA button ──
        let buyBtn = NSButton()
        buyBtn.title = "Unlock SnipClip — \(pm.displayPrice)"
        buyBtn.bezelStyle = .regularSquare
        buyBtn.isBordered = false
        buyBtn.wantsLayer = true
        buyBtn.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        buyBtn.layer?.cornerRadius = 8
        buyBtn.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        buyBtn.contentTintColor = .white
        buyBtn.translatesAutoresizingMaskIntoConstraints = false
        buyBtn.heightAnchor.constraint(equalToConstant: 40).isActive = true
        buyBtn.widthAnchor.constraint(equalToConstant: 280).isActive = true
        buyBtn.target = self
        buyBtn.action = #selector(didTapBuy)
        stack.addArrangedSubview(buyBtn)
        stack.setCustomSpacing(10, after: buyBtn)

        // ── Restore link ──
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

    @objc private func didTapBuy() {
        Task { @MainActor in
            do {
                let success = try await PurchaseManager.shared.purchase()
                if success { self.close() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Purchase failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func didTapRestore() {
        Task { @MainActor in
            await PurchaseManager.shared.restore()
            if PurchaseManager.shared.isUnlocked { self.close() }
        }
    }

    override var canBecomeKey: Bool { true }
}
