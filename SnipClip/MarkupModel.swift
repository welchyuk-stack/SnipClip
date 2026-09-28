import AppKit

enum MarkupTool: Int, CaseIterable {
    case select, pen, arrow, rect, circle, highlight, text, step, blur, crop

    var symbol: String {
        switch self {
        case .select:    return "cursorarrow"
        case .pen:       return "pencil.tip"
        case .arrow:     return "arrow.up.forward"
        case .rect:      return "rectangle"
        case .circle:    return "circle"
        case .highlight: return "highlighter"
        case .text:      return "textformat"
        case .step:      return "1.circle"
        case .blur:      return "checkerboard.rectangle"
        case .crop:      return "crop"
        }
    }

    var name: String {
        switch self {
        case .select:    return "Select & Move"
        case .pen:       return "Pen"
        case .arrow:     return "Arrow"
        case .rect:      return "Rectangle"
        case .circle:    return "Ellipse"
        case .highlight: return "Highlighter"
        case .text:      return "Text"
        case .step:      return "Numbered Step"
        case .blur:      return "Pixelate"
        case .crop:      return "Crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select:    return "v"
        case .pen:       return "p"
        case .arrow:     return "a"
        case .rect:      return "r"
        case .circle:    return "o"
        case .highlight: return "h"
        case .text:      return "t"
        case .step:      return "n"
        case .blur:      return "b"
        case .crop:      return "c"
        }
    }

    var tooltip: String { "\(name)  (\(String(shortcut).uppercased()))" }

    /// Letter shortcuts, plus 1–9 / 0 for the tools in sidebar order.
    static func forKey(_ ch: Character) -> MarkupTool? {
        if let t = allCases.first(where: { $0.shortcut == ch }) { return t }
        if let digit = ch.wholeNumberValue {
            let index = digit == 0 ? 9 : digit - 1
            return allCases.indices.contains(index) ? allCases[index] : nil
        }
        return nil
    }

    var isRectBased: Bool {
        switch self {
        case .rect, .circle, .highlight, .blur, .crop: return true
        default: return false
        }
    }
}

/// Things an item may need at draw time that it doesn't own itself.
struct MarkupDrawContext {
    var pixelated: NSImage?
    var imageSize: NSSize
}

final class MarkupItem {
    enum Shape {
        case pen([NSPoint])
        case arrow(NSPoint, NSPoint)
        case rect(NSRect)
        case circle(NSRect)
        case highlight(NSRect)
        case text(NSPoint, String)
        case step(NSPoint, Int)
        case blur(NSRect)
    }

    private(set) var shape: Shape
    let color: NSColor
    let lineWidth: CGFloat
    let fontSize: CGFloat

    init(_ shape: Shape, color: NSColor, lineWidth: CGFloat, fontSize: CGFloat) {
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }

    func copy() -> MarkupItem {
        MarkupItem(shape, color: color, lineWidth: lineWidth, fontSize: fontSize)
    }

    /// The single source of truth for text styling, shared by the live text
    /// field and committed text so nothing changes size on Return.
    static func textFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .bold)
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: MarkupItem.textFont(size: fontSize), .foregroundColor: color]
    }

    var stepDiameter: CGFloat { fontSize * 1.7 }

    // MARK: Drawing

    func draw(_ ctx: MarkupDrawContext) {
        switch shape {
        case .pen(let pts):
            guard pts.count > 1 else { return }
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.line(to: $0) }
            path.stroke()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to)

        case .rect(let r):
            color.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            path.stroke()

        case .circle(let r):
            color.setStroke()
            let path = NSBezierPath(ovalIn: r)
            path.lineWidth = lineWidth
            path.stroke()

        case .highlight(let r):
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: r).fill()

        case .text(let pt, let str):
            NSAttributedString(string: str, attributes: textAttributes).draw(at: pt)

        case .step(let center, let number):
            let d = stepDiameter
            let circle = NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: d * 0.04, dy: d * 0.04))
            ring.lineWidth = max(1, d * 0.06)
            ring.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
            ]
            let str = NSAttributedString(string: "\(number)", attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))

        case .blur(let r):
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            if let px = ctx.pixelated {
                px.draw(in: NSRect(origin: .zero, size: ctx.imageSize))
            } else {
                NSColor.gray.setFill()
                NSBezierPath(rect: r).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawArrow(from: NSPoint, to: NSPoint) {
        color.setStroke()
        color.setFill()

        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLen = max(12, lineWidth * 4.5)
        let headAngle: CGFloat = .pi / 6.5

        // Stop the shaft short of the tip so a thick round cap doesn't poke
        // out past the arrowhead.
        let shaftEnd = NSPoint(x: to.x - cos(angle) * headLen * 0.6,
                               y: to.y - sin(angle) * headLen * 0.6)
        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: shaftEnd)
        shaft.stroke()

        let p1 = NSPoint(x: to.x - headLen * cos(angle - headAngle),
                         y: to.y - headLen * sin(angle - headAngle))
        let p2 = NSPoint(x: to.x - headLen * cos(angle + headAngle),
                         y: to.y - headLen * sin(angle + headAngle))
        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = max(1, lineWidth * 0.5)
        head.fill()
        head.stroke()
    }

    // MARK: Geometry

    var bounds: NSRect {
        switch shape {
        case .pen(let pts):
            return NSRect.enclosing(pts).insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .arrow(let a, let b):
            let pad = max(12, lineWidth * 4.5)
            return NSRect.enclosing([a, b]).insetBy(dx: -pad / 2, dy: -pad / 2)
        case .rect(let r), .circle(let r):
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .highlight(let r), .blur(let r):
            return r
        case .text(let pt, let str):
            let size = NSAttributedString(string: str, attributes: textAttributes).size()
            return NSRect(origin: pt, size: size)
        case .step(let c, _):
            let d = stepDiameter
            return NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        }
    }

    func hitTest(_ p: NSPoint, tolerance: CGFloat) -> Bool {
        switch shape {
        case .pen(let pts):
            let t = tolerance + lineWidth / 2
            for i in 1..<max(pts.count, 1) where distance(p, pts[i - 1], pts[i]) <= t { return true }
            return pts.count == 1 && hypot(p.x - pts[0].x, p.y - pts[0].y) <= t
        case .arrow(let a, let b):
            return distance(p, a, b) <= tolerance + lineWidth
        case .circle(let r):
            // Near the outline, or anywhere inside for small shapes.
            let inset = r.insetBy(dx: tolerance + lineWidth, dy: tolerance + lineWidth)
            let outer = r.insetBy(dx: -tolerance - lineWidth, dy: -tolerance - lineWidth)
            return NSBezierPath(ovalIn: outer).contains(p)
                && (inset.width < 24 || !NSBezierPath(ovalIn: inset).contains(p))
        case .rect(let r):
            let inset = r.insetBy(dx: tolerance + lineWidth, dy: tolerance + lineWidth)
            let outer = r.insetBy(dx: -tolerance - lineWidth, dy: -tolerance - lineWidth)
            return outer.contains(p) && (inset.width < 24 || inset.height < 24 || !inset.contains(p))
        case .highlight, .blur, .text, .step:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    func offset(by d: NSPoint) {
        func o(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + d.x, y: p.y + d.y) }
        func o(_ r: NSRect) -> NSRect { r.offsetBy(dx: d.x, dy: d.y) }
        switch shape {
        case .pen(let pts):        shape = .pen(pts.map(o))
        case .arrow(let a, let b): shape = .arrow(o(a), o(b))
        case .rect(let r):         shape = .rect(o(r))
        case .circle(let r):       shape = .circle(o(r))
        case .highlight(let r):    shape = .highlight(o(r))
        case .text(let p, let s):  shape = .text(o(p), s)
        case .step(let p, let n):  shape = .step(o(p), n)
        case .blur(let r):         shape = .blur(o(r))
        }
    }

    private func distance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension NSRect {
    init(from a: NSPoint, to b: NSPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func enclosing(_ pts: [NSPoint]) -> NSRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension NSColor {
    /// True for colours where white text/marks would have poor contrast.
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6
    }
}
