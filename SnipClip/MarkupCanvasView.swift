import AppKit

protocol MarkupCanvasDelegate: AnyObject {
    func canvasDidChange()
}

final class MarkupCanvasView: NSView {
    weak var delegate: MarkupCanvasDelegate?

    var backgroundImage: NSImage? { didSet { needsDisplay = true } }
    var items: [MarkupItem] = [] { didSet { needsDisplay = true } }

    var currentTool: MarkupTool = .pen
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 3.0

    // In-progress state
    private var activePoints: [NSPoint] = []
    private var dragStart: NSPoint = .zero
    private var dragEnd: NSPoint = .zero
    private var isPressing = false

    // Text input overlay
    private var textField: NSTextField?
    private var textOrigin: NSPoint = .zero

    // Canvas is flipped: origin top-left, y increases downward (natural for images)
    override var isFlipped: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let img = backgroundImage {
            img.draw(in: bounds)
        }

        for item in items { item.draw() }

        guard isPressing else { return }
        drawPreview()
    }

    private func drawPreview() {
        switch currentTool {
        case .pen:
            guard activePoints.count > 1 else { return }
            currentColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = currentLineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: activePoints[0])
            activePoints.dropFirst().forEach { path.line(to: $0) }
            path.stroke()

        case .arrow:
            MarkupItem(.arrow(dragStart, dragEnd), color: currentColor, lineWidth: currentLineWidth).draw()

        case .rect:
            currentColor.setStroke()
            let path = NSBezierPath(rect: NSRect(from: dragStart, to: dragEnd))
            path.lineWidth = currentLineWidth
            path.stroke()

        case .rectangle:
            currentColor.setStroke()
            let path = NSBezierPath(ovalIn: NSRect(from: dragStart, to: dragEnd))
            path.lineWidth = currentLineWidth
            path.stroke()

        case .highlight:
            currentColor.withAlphaComponent(0.38).setFill()
            NSBezierPath(rect: NSRect(from: dragStart, to: dragEnd)).fill()

        case .text:
            break
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if currentTool == .text {
            commitPendingText()
            showTextField(at: pt)
            return
        }

        isPressing = true
        dragStart = pt
        dragEnd = pt
        activePoints = [pt]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        dragEnd = pt
        if currentTool == .pen { activePoints.append(pt) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        dragEnd = pt
        isPressing = false

        let shape: MarkupItem.Shape
        switch currentTool {
        case .pen:
            guard activePoints.count > 1 else { needsDisplay = true; return }
            shape = .pen(activePoints)
        case .arrow:
            guard dist(dragStart, dragEnd) > 5 else { needsDisplay = true; return }
            shape = .arrow(dragStart, dragEnd)
        case .rect:
            guard dist(dragStart, dragEnd) > 5 else { needsDisplay = true; return }
            shape = .rect(NSRect(from: dragStart, to: dragEnd))
        case .rectangle:
            guard dist(dragStart, dragEnd) > 5 else { needsDisplay = true; return }
            shape = .rectangle(NSRect(from: dragStart, to: dragEnd))
        case .highlight:
            guard dist(dragStart, dragEnd) > 5 else { needsDisplay = true; return }
            shape = .highlight(NSRect(from: dragStart, to: dragEnd))
        case .text:
            return
        }

        items.append(MarkupItem(shape, color: currentColor, lineWidth: currentLineWidth))
        activePoints = []
        delegate?.canvasDidChange()
        needsDisplay = true
    }

    // MARK: Text

    private func showTextField(at point: NSPoint) {
        let tf = NSTextField(frame: NSRect(x: point.x, y: point.y, width: 220, height: 32))
        tf.stringValue = ""
        tf.isBordered = false
        tf.drawsBackground = false
        tf.textColor = currentColor
        tf.font = NSFont.systemFont(ofSize: max(14, currentLineWidth * 4), weight: .bold)
        tf.focusRingType = .none
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        textOrigin = point
    }

    func commitPendingText() {
        guard let tf = textField else { return }
        let str = tf.stringValue
        tf.removeFromSuperview()
        textField = nil
        guard !str.isEmpty else { return }
        items.append(MarkupItem(.text(textOrigin, str), color: currentColor, lineWidth: currentLineWidth))
        delegate?.canvasDidChange()
        needsDisplay = true
    }

    // MARK: Helpers

    private func dist(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - NSTextFieldDelegate

extension MarkupCanvasView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) || selector == #selector(cancelOperation(_:)) {
            commitPendingText()
            return true
        }
        return false
    }
}

// MARK: - NSRect helper

private extension NSRect {
    init(from a: NSPoint, to b: NSPoint) {
        self.init(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
    }
}
