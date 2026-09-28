import AppKit
import QuartzCore

// MARK: - SidebarControl (shared behaviour)

/// Base for every sidebar control: hover / pressed / selected state, a
/// rounded background pill, accessibility, keyboard focus (when Full
/// Keyboard Access is on), and an optional drag-start hook.
class SidebarControl: NSView {

    var isSelected: Bool = false {
        didSet { refreshAppearance(animated: true); setAccessibilityValue(isSelected ? "selected" : nil) }
    }
    var onAction: (() -> Void)?
    /// Fired once when the mouse moves more than 3pt while pressed; the
    /// click action is then suppressed.
    var onDragStart: ((NSEvent) -> Void)?

    fileprivate let bgLayer = CALayer()
    fileprivate var isHovered = false
    fileprivate var isPressed = false
    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    init(frame: NSRect, tip: String, role: NSAccessibility.Role = .button) {
        super.init(frame: frame)
        wantsLayer = true
        bgLayer.cornerRadius = 7
        layer?.addSublayer(bgLayer)
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(role)
        setAccessibilityLabel(tip)
        rebuildTracking()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    // MARK: Appearance

    /// Subclasses update their own content here, then call super.
    func refreshAppearance(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.12)
                CATransaction.setAnimationTimingFunction(.init(name: .easeInEaseOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            bgLayer.backgroundColor = backgroundColor().cgColor
            CATransaction.commit()
        }
        needsDisplay = true
    }

    func backgroundColor() -> NSColor {
        if isPressed { return NSColor.labelColor.withAlphaComponent(0.13) }
        if isSelected { return NSColor.controlAccentColor.withAlphaComponent(0.18) }
        if isHovered { return NSColor.labelColor.withAlphaComponent(0.07) }
        return .clear
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance(animated: false)
    }

    // MARK: Mouse

    private func rebuildTracking() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; refreshAppearance(animated: true) }
    override func mouseExited(with event: NSEvent) {
        isHovered = false; isPressed = false; refreshAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        didStartDrag = false
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        refreshAppearance(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didStartDrag, let onDragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - start.x, p.y - start.y) > 3 {
            didStartDrag = true
            isPressed = false
            refreshAppearance(animated: true)
            onDragStart(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard isPressed, !didStartDrag else { return }
        isPressed = false
        refreshAppearance(animated: true)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onAction?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Keyboard / focus

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {  // Space, Return, Enter
            onAction?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onAction?()
        return true
    }
}

// MARK: - SidebarIconButton

/// SF Symbol icon button. Default: secondary label colour; hover: grey pill;
/// selected: accent pill + accent icon; pressed: darker pill.
final class SidebarIconButton: SidebarControl {

    var sfSymbolName: String { didSet { applySymbol() } }

    private let iconView = NSImageView()
    private var confirmTimer: Timer?
    private var baseSymbol: String

    init(sfSymbol: String, tip: String = "", isTool: Bool = false) {
        self.sfSymbolName = sfSymbol
        self.baseSymbol = sfSymbol
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36), tip: tip,
                   role: isTool ? .radioButton : .button)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        applySymbol()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        iconView.frame = bounds
    }

    private func applySymbol() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        iconView.image = NSImage(systemSymbolName: sfSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        refreshAppearance(animated: false)
    }

    override func backgroundColor() -> NSColor {
        if confirmTimer != nil { return NSColor.systemGreen.withAlphaComponent(0.14) }
        return super.backgroundColor()
    }

    override func refreshAppearance(animated: Bool) {
        if confirmTimer != nil {
            iconView.contentTintColor = .systemGreen
        } else if isSelected {
            iconView.contentTintColor = .controlAccentColor
        } else if isHovered {
            iconView.contentTintColor = .labelColor
        } else {
            iconView.contentTintColor = .secondaryLabelColor
        }
        super.refreshAppearance(animated: animated)
    }

    /// Green checkmark flash, e.g. after Copy or Save.
    func showConfirmation() {
        confirmTimer?.invalidate()
        confirmTimer = nil
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.confirmTimer = nil
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.iconView.animator().alphaValue = 0
            } completionHandler: {
                self.sfSymbolName = self.baseSymbol
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    self.iconView.animator().alphaValue = 1
                }
            }
        }
        confirmTimer = timer
        sfSymbolName = "checkmark.circle.fill"

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.18, 0.94, 1.0]
        pop.keyTimes = [0, 0.25, 0.65, 1.0]
        pop.duration = 0.28
        layer?.add(pop, forKey: "pop")

        // .common so it fires during menu / tracking loops too.
        RunLoop.main.add(timer, forMode: .common)
    }

    func showCopyConfirmation() { showConfirmation() }
}

// MARK: - SwatchButton

/// A colour circle. With `isCustom`, clicking opens the system colour panel,
/// and it shows a multicolour gradient until a custom colour is picked.
final class SwatchButton: SidebarControl {

    var color: NSColor? { didSet { needsDisplay = true } }
    let isCustom: Bool
    /// Called with the chosen colour (for the custom swatch, on every panel change).
    var onPick: ((NSColor) -> Void)?

    init(color: NSColor?, tip: String, isCustom: Bool = false) {
        self.color = color
        self.isCustom = isCustom
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24), tip: tip, role: .radioButton)
        bgLayer.cornerRadius = 12
        onAction = { [weak self] in self?.activate() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bgLayer.frame = .zero  // swatches draw their own selection ring
    }

    private func activate() {
        if isCustom {
            let panel = NSColorPanel.shared
            if let color { panel.color = color }
            panel.isContinuous = true
            panel.setTarget(self)
            panel.setAction(#selector(panelChanged(_:)))
            panel.orderFront(nil)
            if let color { onPick?(color) }
        } else if let color {
            onPick?(color)
        }
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        color = sender.color
        onPick?(sender.color)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // NSColorPanel's target is unretained — clear it before we go away.
        if newWindow == nil, isCustom {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        if let color {
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
        } else {
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                     .systemTeal, .systemBlue, .systemPurple, .systemPink, .systemRed]
            NSGradient(colors: colors)?.draw(in: NSBezierPath(ovalIn: r), angle: 90)
        }
        NSColor.labelColor.withAlphaComponent(isHovered ? 0.45 : 0.25).setStroke()
        let edge = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()

        if isSelected {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.25, dy: 1.25))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

// MARK: - LineWidthButton

/// Shows a horizontal line of the given thickness.
final class LineWidthButton: SidebarControl {
    let lineWidth: CGFloat

    init(lineWidth: CGFloat, tip: String) {
        self.lineWidth = lineWidth
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24), tip: tip, role: .radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds.insetBy(dx: 1, dy: 1)
        bgLayer.cornerRadius = 6
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = isSelected ? .controlAccentColor : (isHovered ? .labelColor : .secondaryLabelColor)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth * 0.75
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: bounds.minX + 6, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.midY))
        path.stroke()
    }
}
