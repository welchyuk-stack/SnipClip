import AppKit

// MARK: - Controller

final class SelectionOverlayController {
    static let shared = SelectionOverlayController()
    private var window: SelectionOverlayWindow?
    private var isCapturing = false

    func show() {
        guard !isCapturing else { return }
        isCapturing = true
        window?.close()

        // Close any leftover editor window from a previous capture so it
        // can't end up visible in the new screenshot.
        MarkupEditorController.shared.closeIfOpen()

        // Union of all screen frames (NSScreen, origin bottom-left)
        let unionRect = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }

        let win = SelectionOverlayWindow(contentRect: unionRect,
                                         styleMask: .borderless,
                                         backing: .buffered,
                                         defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: unionRect.size))
        view.onComplete = { [weak self] screenNSRect in
            win.orderOut(nil)
            self?.window = nil
            self?.capture(screenRect: screenNSRect)
        }
        view.onCancel = { [weak self] in
            win.orderOut(nil)
            self?.window = nil
            self?.isCapturing = false
        }

        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func capture(screenRect: NSRect) {
        // Brief pause so the overlay is fully gone before we grab pixels
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let image = ScreenCapture.capture(nsScreenRect: screenRect) else {
                self?.isCapturing = false
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            MarkupEditorController.shared.show(image: image)
            self?.isCapturing = false
        }
    }
}

// MARK: - Overlay Window

final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay View

final class SelectionOverlayView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPt: NSPoint = .zero
    private var currentPt: NSPoint = .zero
    private var dragging = false

    // isFlipped = false (default): origin bottom-left, matches NSScreen coords
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Semi-transparent dark veil over everything
        NSColor.black.withAlphaComponent(0.42).setFill()
        NSBezierPath(rect: bounds).fill()

        guard dragging else { return }
        let sel = selectionRect()

        // Punch a transparent hole to show live screen content
        NSGraphicsContext.current?.cgContext.clear(sel)

        // Crisp 1.5pt white border
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()

        // Corner size handles
        let handles: [NSPoint] = [
            NSPoint(x: sel.minX, y: sel.minY),
            NSPoint(x: sel.maxX, y: sel.minY),
            NSPoint(x: sel.minX, y: sel.maxY),
            NSPoint(x: sel.maxX, y: sel.maxY)
        ]
        NSColor.white.setFill()
        for h in handles {
            NSBezierPath(ovalIn: CGRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)).fill()
        }

        // Dimensions label
        let w = Int(sel.width.rounded())
        let h = Int(sel.height.rounded())
        drawLabel("\(w) × \(h)", near: sel)
    }

    private func drawLabel(_ text: String, near rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let padding: CGFloat = 5

        var x = rect.maxX - size.width - padding
        var y = rect.maxY + 6
        if y + size.height + padding * 2 > bounds.maxY { y = rect.minY - size.height - 6 - padding * 2 }
        x = max(4, min(x, bounds.maxX - size.width - 8))

        let bg = NSRect(x: x - padding, y: y - padding, width: size.width + padding * 2, height: size.height + padding * 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: x, y: y))
    }

    private func selectionRect() -> NSRect {
        NSRect(
            x: min(startPt.x, currentPt.x),
            y: min(startPt.y, currentPt.y),
            width: abs(currentPt.x - startPt.x),
            height: abs(currentPt.y - startPt.y)
        )
    }

    override func mouseDown(with event: NSEvent) {
        startPt = convert(event.locationInWindow, from: nil)
        currentPt = startPt
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPt = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPt = convert(event.locationInWindow, from: nil)
        dragging = false
        needsDisplay = true

        let viewRect = selectionRect()
        guard viewRect.width > 4, viewRect.height > 4 else { onCancel?(); return }

        // Convert view rect → window rect → screen rect (NSScreen, bottom-left origin)
        guard let win = window else { return }
        let windowRect = convert(viewRect, to: nil)
        let screenRect = win.convertToScreen(windowRect)
        onComplete?(screenRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
    }

    override var acceptsFirstResponder: Bool { true }
}
