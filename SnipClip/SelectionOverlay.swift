import AppKit

// MARK: - Controller

/// Shows one overlay window per screen over a frozen snapshot of that screen
/// and lets the user drag out a region or click a window.
final class SelectionOverlayController {
    static let shared = SelectionOverlayController()
    private init() {}

    enum Purpose { case capture, scrolling, recording }
    struct Selection { let rect: NSRect; let screen: NSScreen; let image: NSImage? }

    private(set) var purpose: Purpose = .capture
    private var isActive = false
    private var windows: [SelectionOverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private var monitor: Any?
    private var completion: ((Selection?) -> Void)?
    /// Window rects (global NSScreen coords), frontmost first.
    fileprivate var windowRects: [NSRect] = []
    fileprivate var spaceDown = false

    func begin(purpose: Purpose, completion: @escaping (Selection?) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.purpose = purpose
        self.completion = completion
        spaceDown = false
        if purpose == .capture { MarkupEditorController.shared.closeIfOpen() }

        let screens = NSScreen.screens
        Task { @MainActor in
            if #unavailable(macOS 14.0) {
                // CGDisplayCreateImage can't exclude our windows; let them vanish.
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            let images = await Self.captureAll(screens)
            self.windowRects = Self.snapshotWindowRects()
            if purpose == .capture, images.contains(where: { $0 == nil }) {
                self.isActive = false
                self.completion = nil
                AppAlert.show(title: "Capture Failed",
                              message: "SnipClip couldn't capture the screen. Check that Screen Recording permission is enabled in System Settings › Privacy & Security.")
                completion(nil)
                return
            }
            self.present(screens: screens, images: images)
        }
    }

    private static func captureAll(_ screens: [NSScreen]) async -> [CGImage?] {
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, screen) in screens.enumerated() {
                group.addTask {
                    guard let c = await DisplayCapturer.make(for: screen, excludingOwnWindows: true) else { return (i, nil) }
                    return (i, await c.capture())
                }
            }
            var result = [CGImage?](repeating: nil, count: screens.count)
            for await (i, img) in group { result[i] = img }
            return result
        }
    }

    private static func snapshotWindowRects() -> [NSRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return [] }
        let primaryHeight = primary.frame.height
        let pid = Int(getpid())
        var rects: [NSRect] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != pid,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  cg.width >= 20, cg.height >= 20 else { continue }
            rects.append(NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height))
        }
        return rects
    }

    private func present(screens: [NSScreen], images: [CGImage?]) {
        for (i, screen) in screens.enumerated() {
            let win = SelectionOverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                             backing: .buffered, defer: false)
            win.setFrame(screen.frame, display: false)
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = false
            win.isReleasedWhenClosed = false
            win.acceptsMouseMovedEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let size = screen.frame.size
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            if let img = images[i] {
                container.layer?.contents = img
                container.layer?.contentsGravity = .resize
            }
            let view = SelectionOverlayView(frame: container.bounds, screen: screen,
                                            frozen: images[i], controller: self)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            win.contentView = container
            windows.append(win)
            views.append(view)
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .mouseMoved]) { [weak self] event in
            guard let self, self.isActive else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { self.finish(nil); return nil }
                if event.keyCode == 49 { self.spaceDown = true; return nil }
                return nil
            case .keyUp:
                if event.keyCode == 49 { self.spaceDown = false }
                return nil
            case .mouseMoved:
                self.mouseMoved()
                return event
            default:
                return event
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for win in windows { win.orderFrontRegardless() }
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()
        mouseMoved()
    }

    fileprivate func mouseMoved() {
        let loc = NSEvent.mouseLocation
        NSCursor.crosshair.set()
        for (win, view) in zip(windows, views) {
            let inside = NSMouseInRect(loc, win.frame, false)
            view.updateHover(globalMouse: inside ? loc : nil)
            if inside, !win.isKeyWindow { win.makeKey() }
        }
    }

    /// Topmost snapshot window containing a global point.
    fileprivate func windowRect(at global: NSPoint) -> NSRect? {
        windowRects.first { NSMouseInRect(global, $0, false) }
    }

    fileprivate func finish(_ result: (rect: NSRect, view: SelectionOverlayView)?) {
        guard isActive else { return }
        isActive = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for win in windows { win.orderOut(nil) }
        windows = []
        views = []
        NSCursor.arrow.set()
        let done = completion
        completion = nil

        guard let result else { done?(nil); return }
        let screen = result.view.screen
        let global = result.rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        var image: NSImage?
        if purpose == .capture {
            guard let frozen = result.view.frozen,
                  let cg = ScreenCapture.crop(frozen, screen: screen, rect: global) else { done?(nil); return }
            image = ScreenCapture.image(from: cg, pointSize: global.size)
        }
        done?(Selection(rect: global, screen: screen, image: image))
    }
}

// MARK: - Overlay Window

final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay View

private final class SelectionOverlayView: NSView {
    let screen: NSScreen
    let frozen: CGImage?
    private unowned let controller: SelectionOverlayController

    private var mouse: NSPoint?          // local, nil when mouse is on another screen
    private var hoverRect: NSRect?       // local, clipped
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var lastDragPoint: NSPoint?
    private var isDragging = false

    init(frame: NSRect, screen: NSScreen, frozen: CGImage?, controller: SelectionOverlayController) {
        self.screen = screen
        self.frozen = frozen
        self.controller = controller
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func updateHover(globalMouse: NSPoint?) {
        guard !isDragging else { return }
        if let g = globalMouse {
            let local = NSPoint(x: g.x - screen.frame.minX, y: g.y - screen.frame.minY)
            mouse = local
            if let r = controller.windowRect(at: g) {
                let clipped = r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(bounds)
                hoverRect = clipped.isEmpty ? nil : clipped
            } else {
                hoverRect = nil
            }
        } else {
            mouse = nil
            hoverRect = nil
        }
        needsDisplay = true
    }

    private var selectionRect: NSRect? {
        guard let a = dragStart, let b = dragCurrent, isDragging else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(bounds)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sel = selectionRect
        let hole = sel ?? hoverRect

        // Dim everywhere except the selection / hovered window.
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.appendRect(hole) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        if let sel {
            let border = NSBezierPath(rect: sel.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            NSColor.white.setStroke()
            border.stroke()
            let scale = screen.backingScaleFactor
            drawLabel("\(Int((sel.width * scale).rounded())) × \(Int((sel.height * scale).rounded()))", below: sel)
            return
        }

        guard let mouse else { return }

        if let hoverRect {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            hoverRect.fill()
            let b = NSBezierPath(rect: hoverRect.insetBy(dx: 1, dy: 1))
            b.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            b.stroke()
        }

        // Crosshair guides.
        NSColor.white.withAlphaComponent(0.35).setFill()
        let px = floor(mouse.x),py = floor(mouse.y)
        NSRect(x: px, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: py, width: bounds.width, height: 1).fill()

        drawLoupe(ctx: ctx, at: mouse)
        drawHint()
    }

    private func drawLoupe(ctx: CGContext, at p: NSPoint) {
        guard let img = frozen else { return }
        let n = 11
        let size: CGFloat = 110
        let s = CGFloat(img.width) / bounds.width
        let cx = Int(floor(p.x * s)), cy = Int(floor((bounds.height - p.y) * s))
        let src = CGRect(x: cx - n / 2, y: cy - n / 2, width: n, height: n)
        guard let sample = img.cropping(to: src) else { return }

        var origin = NSPoint(x: p.x + 20, y: p.y - 20 - size)
        if origin.x + size > bounds.maxX - 4 { origin.x = p.x - 20 - size }
        if origin.y < bounds.minY + 4 { origin.y = p.y + 20 }
        origin.x = max(4, min(origin.x, bounds.maxX - size - 4))
        origin.y = max(4, min(origin.y, bounds.maxY - size - 4))
        let loupe = NSRect(origin: origin, size: NSSize(width: size, height: size))

        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: loupe, xRadius: 8, yRadius: 8)
        clip.addClip()
        NSColor.black.setFill()
        loupe.fill()
        ctx.interpolationQuality = .none
        let cell = size / CGFloat(n)
        // Place the (possibly edge-clamped) sample where its pixels belong.
        let clampedSrc = src.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let dx = (clampedSrc.minX - src.minX) * cell
        let dyTop = (clampedSrc.minY - src.minY) * cell
        let drawRect = CGRect(x: loupe.minX + dx,
                              y: loupe.maxY - dyTop - clampedSrc.height * cell,
                              width: clampedSrc.width * cell, height: clampedSrc.height * cell)
        ctx.draw(sample, in: drawRect)
        ctx.restoreGState()

        let center = NSRect(x: loupe.minX + CGFloat(n / 2) * cell, y: loupe.minY + CGFloat(n / 2) * cell,
                            width: cell, height: cell)
        NSColor.white.setStroke()
        let cb = NSBezierPath(rect: center)
        cb.lineWidth = 1
        cb.stroke()
        let outline = NSBezierPath(roundedRect: loupe, xRadius: 8, yRadius: 8)
        outline.lineWidth = 2
        NSColor.white.withAlphaComponent(0.9).setStroke()
        outline.stroke()
    }

    private func drawHint() {
        let first: String
        switch controller.purpose {
        case .capture: first = "Drag to select · Click to capture a window"
        case .scrolling: first = "Select the area to scroll-capture"
        case .recording: first = "Select the area to record"
        }
        let text = "\(first) · Hold Space to move · Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let ts = str.size()
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        let pill = NSRect(x: bounds.midX - ts.width / 2 - 14,
                          y: bounds.maxY - topInset - 24 - ts.height - 12,
                          width: ts.width + 28, height: ts.height + 12)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        str.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 6))
    }

    private func drawLabel(_ text: String, below rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let ts = str.size()
        let size = NSSize(width: ts.width + 12, height: ts.height + 6)
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 6)
        if origin.y < 4 { origin.y = rect.maxY + 6 }
        if origin.y + size.height > bounds.maxY - 4 { origin.y = rect.minY + 6 }
        origin.x = max(4, min(origin.x, bounds.maxX - size.width - 4))
        origin.y = max(4, min(origin.y, bounds.maxY - size.height - 4))
        let bg = NSRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        str.draw(at: NSPoint(x: bg.minX + 6, y: bg.minY + 3))
    }

    // MARK: Mouse

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: max(0, min(p.x, bounds.maxX)), y: max(0, min(p.y, bounds.maxY)))
    }

    override func mouseDown(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        dragStart = p
        dragCurrent = p
        lastDragPoint = p
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let last = lastDragPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !isDragging {
            if hypot(p.x - start.x, p.y - start.y) < 4 { return }
            isDragging = true
            hoverRect = nil
        }
        if controller.spaceDown, let cur = dragCurrent {
            // Move the whole selection, keeping it on-screen.
            var dx = p.x - last.x, dy = p.y - last.y
            let minX = min(start.x, cur.x), maxX = max(start.x, cur.x)
            let minY = min(start.y, cur.y), maxY = max(start.y, cur.y)
            dx = max(-minX, min(dx, bounds.maxX - maxX))
            dy = max(-minY, min(dy, bounds.maxY - maxY))
            dragStart = NSPoint(x: start.x + dx, y: start.y + dy)
            dragCurrent = NSPoint(x: cur.x + dx, y: cur.y + dy)
        } else {
            dragCurrent = clamp(p)
        }
        lastDragPoint = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil; dragCurrent = nil; lastDragPoint = nil; isDragging = false
            needsDisplay = true
        }
        if isDragging, let sel = selectionRect, sel.width >= 4, sel.height >= 4 {
            controller.finish((sel.integral, self))
            return
        }
        if !isDragging, let hover = hoverRect {
            controller.finish((hover, self))
        }
    }
}
