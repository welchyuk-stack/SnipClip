import AppKit
import QuartzCore

// MARK: - SidebarIconButton

/// Polished icon button styled after Apple's own tool-palette buttons.
/// Default: icon in secondaryLabelColor, no background.
/// Hover:    subtle grey pill.
/// Selected: accent-tinted pill + accent icon.
/// Pressed:  darker pill + 0.92 scale.
final class SidebarIconButton: NSView {

    // MARK: Public

    var sfSymbolName: String { didSet { applySymbol() } }
    var isSelected: Bool = false { didSet { animateState() } }
    var onAction: (() -> Void)?

    // MARK: Private

    private let iconView = NSImageView()
    private let bgLayer  = CALayer()
    private var trackingArea: NSTrackingArea?

    private var isHovered = false
    private var isPressed = false

    // For copy-confirmation flash
    private var confirmTimer: Timer?
    private var baseSymbol: String = ""

    // MARK: Init

    init(sfSymbol: String, tip: String = "") {
        self.sfSymbolName = sfSymbol
        self.baseSymbol   = sfSymbol
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        toolTip = tip
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func setup() {
        wantsLayer = true

        bgLayer.cornerRadius = 7
        bgLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(bgLayer)

        iconView.imageScaling  = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        addSubview(iconView)

        applySymbol()
        rebuildTracking()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        bgLayer.frame = bounds.insetBy(dx: 3, dy: 3)
        iconView.frame = bounds
    }

    // MARK: Symbol

    private func applySymbol() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        iconView.image = NSImage(systemSymbolName: sfSymbolName,
                                 accessibilityDescription: nil)?
                            .withSymbolConfiguration(cfg)
        syncIconColor()
    }

    private func syncIconColor() {
        if confirmTimer != nil {
            iconView.contentTintColor = NSColor.systemGreen
        } else if isSelected {
            iconView.contentTintColor = .controlAccentColor
        } else if isHovered {
            iconView.contentTintColor = .labelColor
        } else {
            iconView.contentTintColor = .secondaryLabelColor
        }
    }

    private func syncBgColor() -> CGColor {
        if confirmTimer != nil {
            return NSColor.systemGreen.withAlphaComponent(0.14).cgColor
        } else if isPressed {
            return NSColor.labelColor.withAlphaComponent(0.13).cgColor
        } else if isSelected {
            return NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        } else if isHovered {
            return NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
        return NSColor.clear.cgColor
    }

    private func animateState() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(.init(name: .easeInEaseOut))
        bgLayer.backgroundColor = syncBgColor()
        CATransaction.commit()
        syncIconColor()
    }

    // MARK: Copy confirmation

    func showCopyConfirmation() {
        confirmTimer?.invalidate()
        sfSymbolName = "checkmark.circle.fill"

        // Scale-pop
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values   = [1.0, 1.18, 0.94, 1.0]
        pop.keyTimes = [0,   0.25, 0.65, 1.0]
        pop.duration = 0.28
        layer?.add(pop, forKey: "pop")

        animateState()

        confirmTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.confirmTimer = nil
            // Fade out → swap icon → fade back in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.iconView.animator().alphaValue = 0
            } completionHandler: {
                self.sfSymbolName = self.baseSymbol
                self.animateState()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    self.iconView.animator().alphaValue = 1
                }
            }
        }
    }

    // MARK: Mouse

    private func rebuildTracking() {
        if let old = trackingArea { removeTrackingArea(old) }
        trackingArea = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true; animateState()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false; isPressed = false; animateState()
    }
    override func mouseDown(with event: NSEvent) {
        isPressed = true; animateState()
    }
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false; animateState()
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onAction?()
        }
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - ColorPickerButton

/// A small polished circle showing the current colour.
/// Click to open the system colour panel.
final class ColorPickerButton: NSView {

    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }
    var onChange: ((NSColor) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        toolTip = "Colour"
        rebuildTracking()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 8, dy: 8)

        // Subtle drop shadow
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // Ring
        let ringAlpha: CGFloat = isHovered ? 0.4 : 0.22
        NSColor.labelColor.withAlphaComponent(ringAlpha).setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    private func rebuildTracking() {
        if let old = trackingArea { removeTrackingArea(old) }
        trackingArea = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent)  { isHovered = true;  needsDisplay = true }
    override func mouseExited(with event: NSEvent)   { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let panel = NSColorPanel.shared
        panel.color = color
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        color = sender.color
        onChange?(color)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
