import AppKit

enum MarkupTool: Int, CaseIterable {
    case pen, arrow, rect, rectangle, highlight, text
}

final class MarkupItem {
    enum Shape {
        case pen([NSPoint])
        case arrow(NSPoint, NSPoint)
        case rect(NSRect)
        case rectangle(NSRect)
        case highlight(NSRect)
        case text(NSPoint, String)
    }

    let shape: Shape
    let color: NSColor
    let lineWidth: CGFloat

    init(_ shape: Shape, color: NSColor, lineWidth: CGFloat) {
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }

    func draw() {
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
            path.stroke()

        case .rectangle(let r):
            color.setStroke()
            let path = NSBezierPath(ovalIn: r)
            path.lineWidth = lineWidth
            path.stroke()

        case .highlight(let r):
            color.withAlphaComponent(0.38).setFill()
            NSBezierPath(rect: r).fill()

        case .text(let pt, let str):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18 * (lineWidth / 3.0), weight: .bold),
                .foregroundColor: color,
                .strokeColor: NSColor.black,
                .strokeWidth: NSNumber(value: -2.5)
            ]
            NSAttributedString(string: str, attributes: attrs).draw(at: pt)
        }
    }

    private func drawArrow(from: NSPoint, to: NSPoint) {
        color.setStroke()
        color.setFill()

        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: to)
        shaft.stroke()

        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLen = max(14, lineWidth * 4.5)
        let headAngle: CGFloat = .pi / 6.5

        let p1 = NSPoint(x: to.x - headLen * cos(angle - headAngle),
                         y: to.y - headLen * sin(angle - headAngle))
        let p2 = NSPoint(x: to.x - headLen * cos(angle + headAngle),
                         y: to.y - headLen * sin(angle + headAngle))

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        head.fill()
    }
}
