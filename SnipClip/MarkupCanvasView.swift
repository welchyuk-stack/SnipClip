import AppKit
import CoreImage

protocol MarkupCanvasDelegate: AnyObject {
    func canvasDidChange()
    func canvasDidChangeTool(_ tool: MarkupTool)
    func canvasRequestsClose()
    /// The visible part of the image changed (crop applied or being edited).
    func canvasDisplayRectDidChange()
    func canvasDidCopyText(_ text: String)
    /// Pan the view by a screen-space delta (Pan tool or Space-drag).
    func canvasPan(dx: CGFloat, dy: CGFloat)
    func canvasSelectionDidChange()
}

/// The annotation surface. Its `bounds` is always the image size in points
/// (flipped, top-left origin); its frame is whatever the editor lays out, so
/// zoom = frame.width / bounds.width and items live in image coordinates.
final class MarkupCanvasView: NSView {
    weak var delegate: MarkupCanvasDelegate?

    let image: NSImage
    let imageSize: NSSize

    private(set) var items: [MarkupItem] = [] { didSet { needsDisplay = true } }
    private(set) var cropRect: NSRect? { didSet { needsDisplay = true; displayRectChanged() } }

    /// The part of the image shown: the whole image while cropping (so the
    /// crop can be adjusted), otherwise just the cropped area.
    var displayRect: NSRect {
        NSRect(origin: .zero, size: imageSize)
    }

    private func displayRectChanged() {
        bounds = displayRect
        delegate?.canvasDisplayRectDidChange()
        window?.invalidateCursorRects(for: self)
    }

    private(set) var currentTool: MarkupTool = .pen
    var currentColor: NSColor = .systemRed {
        didSet { textField?.textColor = currentColor }
    }
    /// Stroke width in on-screen points (sidebar offers 2 / 4 / 8).
    var lineWidthChoice: CGFloat = 4
    /// Rounded corners while previewing an export background (image points).
    var previewCornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    // In-progress state
    private var activePoints: [NSPoint] = []
    private var dragStart: NSPoint = .zero
    private var dragEnd: NSPoint = .zero
    private var isPressing = false
    private var shiftDown = false

    // Selection / move
    private var selectedItem: MarkupItem? {
        didSet { needsDisplay = true; if (oldValue == nil) != (selectedItem == nil) { delegate?.canvasSelectionDidChange() } }
    }
    private var moveStart: NSPoint?
    private var moveTotal: NSPoint = .zero
    private var resizeHandle: Int?
    private var resizeStartState: MarkupItem.State?

    // Text editing
    private var textField: NSTextField?
    private var textOrigin: NSPoint = .zero
    private var editingItem: MarkupItem?
    private var editingFontSize: CGFloat = 0
    private var editingColor: NSColor = .systemRed

    init(image: NSImage) {
        self.image = image
        self.imageSize = NSSize(width: max(1, image.size.width), height: max(1, image.size.height))
        super.init(frame: NSRect(origin: .zero, size: imageSize))
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        bounds = displayRect
        window?.invalidateCursorRects(for: self)
    }

    var zoom: CGFloat { bounds.width > 0 ? max(0.01, frame.width / bounds.width) : 1 }

    /// The fit-to-window scale, ignoring the user's zoom. New strokes are sized
    /// against this so zooming in to draw doesn't make lines thinner.
    var baseZoom: CGFloat = 1

    // Crop editing
    private enum CropDrag { case move(NSPoint, NSRect), resize(Int, NSRect) }
    private var cropDrag: CropDrag?

    // Panning
    private var spaceDown = false
    private var isPanning: Bool { currentTool == .pan || spaceDown }

    var isEditingText: Bool { textField != nil }

    // MARK: Pixelated source (for blur items)

    private var _pixelated: NSImage?
    private var pixelatedBuilt = false

    var pixelatedImage: NSImage? {
        if !pixelatedBuilt {
            pixelatedBuilt = true
            _pixelated = buildPixelated()
        }
        return _pixelated
    }

    private func buildPixelated() -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(8, CGFloat(cg.width) / 80), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: extent.minX, y: extent.minY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: extent),
              let out = CIContext(options: nil).createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: out, size: imageSize)
    }

    var drawContext: MarkupDrawContext {
        MarkupDrawContext(pixelated: pixelatedImage, imageSize: imageSize)
    }

    // MARK: Public API

    func setTool(_ tool: MarkupTool) {
        if tool != .text || textField != nil { commitPendingText() }
        if tool != .select { selectedItem = nil }
        let wasCrop = currentTool == .crop
        currentTool = tool
        if wasCrop != (tool == .crop) { displayRectChanged() }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Replace state without registering undo (used when opening the editor).
    func restore(items: [MarkupItem], crop: NSRect?) {
        self.items = items
        self.cropRect = crop
        selectedItem = nil
    }

    func deleteSelection() {
        guard let item = selectedItem, let idx = items.firstIndex(where: { $0 === item }) else { return }
        removeItem(at: idx, actionName: "Delete")
        selectedItem = nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let full = NSRect(origin: .zero, size: imageSize)
        if previewCornerRadius > 0 {
            NSBezierPath(roundedRect: displayRect, xRadius: previewCornerRadius, yRadius: previewCornerRadius).addClip()
        }
        image.draw(in: full)

        let ctx = drawContext
        let preview = isPressing ? previewItem() : nil
        // Spotlight dimming goes under the annotations so they stay bright.
        MarkupItem.drawSpotlights(items + [preview].compactMap { $0 }, imageSize: imageSize)
        for item in items where item !== editingItem { item.draw(ctx) }

        if let preview { preview.draw(ctx) }

        if let sel = selectedItem, items.contains(where: { $0 === sel }) {
            let z = zoom
            let path = NSBezierPath(rect: sel.bounds.insetBy(dx: -4 / z, dy: -4 / z))
            path.lineWidth = 1 / z
            path.setLineDash([4 / z, 3 / z], count: 2, phase: 0)
            NSColor.white.setStroke(); path.stroke()
            path.setLineDash([4 / z, 3 / z], count: 2, phase: 4 / z)
            NSColor.controlAccentColor.setStroke(); path.stroke()

            let size = 8 / z
            for h in sel.handles {
                let r = NSRect(x: h.x - size / 2, y: h.y - size / 2, width: size, height: size)
                NSColor.white.setFill()
                NSBezierPath(rect: r).fill()
                let b = NSBezierPath(rect: r)
                b.lineWidth = 1.5 / z
                NSColor.controlAccentColor.setStroke()
                b.stroke()
            }
        }

        if isPressing, currentTool == .ocr {
            let r = NSRect(from: dragStart, to: constrainedEnd())
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            r.fill()
            let b = NSBezierPath(rect: r)
            b.lineWidth = 1.5 / zoom
            b.setLineDash([5 / zoom, 3 / zoom], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            b.stroke()
        }

        // The crop is only drawn as an overlay while the Crop tool is active;
        // otherwise the view is already showing just the cropped area.
        let crop: NSRect? = (isPressing && currentTool == .crop) ? liveCropRect() : cropRect
        if let crop, crop.width > 0, crop.height > 0 {
            let dim = NSBezierPath(rect: full)
            dim.append(NSBezierPath(rect: crop))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            dim.fill()
            let border = NSBezierPath(rect: crop)
            border.lineWidth = 1 / zoom
            NSColor.white.setStroke()
            border.stroke()
            if currentTool == .crop {
                let size = 9 / zoom
                for h in cropCorners(crop) {
                    let r = NSRect(x: h.x - size / 2, y: h.y - size / 2, width: size, height: size)
                    NSColor.white.setFill()
                    NSBezierPath(rect: r).fill()
                }
            }
        }
    }

    private func constrainedEnd() -> NSPoint {
        guard shiftDown else { return dragEnd }
        let dx = dragEnd.x - dragStart.x, dy = dragEnd.y - dragStart.y
        if currentTool == .arrow {
            let len = hypot(dx, dy)
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return NSPoint(x: dragStart.x + cos(angle) * len, y: dragStart.y + sin(angle) * len)
        }
        if currentTool.isRectBased {
            let side = max(abs(dx), abs(dy))
            return NSPoint(x: dragStart.x + (dx < 0 ? -side : side),
                           y: dragStart.y + (dy < 0 ? -side : side))
        }
        return dragEnd
    }

    private func liveCropRect() -> NSRect {
        NSRect(from: dragStart, to: constrainedEnd()).intersection(NSRect(origin: .zero, size: imageSize))
    }

    private var newLineWidth: CGFloat { lineWidthChoice / baseZoom }
    private var newFontSize: CGFloat { (12 + lineWidthChoice * 2.5) / baseZoom }

    private func makeItem(_ shape: MarkupItem.Shape) -> MarkupItem {
        MarkupItem(shape, color: currentColor, lineWidth: newLineWidth, fontSize: newFontSize)
    }

    private func previewItem() -> MarkupItem? {
        let end = constrainedEnd()
        switch currentTool {
        case .pen:       return activePoints.count > 1 ? makeItem(.pen(activePoints)) : nil
        case .arrow:     return makeItem(.arrow(dragStart, end))
        case .rect:      return makeItem(.rect(NSRect(from: dragStart, to: end)))
        case .circle:    return makeItem(.circle(NSRect(from: dragStart, to: end)))
        case .highlight: return makeItem(.highlight(NSRect(from: dragStart, to: end)))
        case .blur:      return makeItem(.blur(NSRect(from: dragStart, to: end)))
        case .redact:    return makeItem(.redact(NSRect(from: dragStart, to: end)))
        case .spotlight: return makeItem(.spotlight(NSRect(from: dragStart, to: end)))
        default:         return nil
        }
    }

    // MARK: Area selection (cut / move / erase)

    private lazy var sourceBitmap: NSBitmapImageRep? = {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { NSBitmapImageRep(cgImage: $0) }
    }()

    /// The capture's pixels inside `rect` (image points).
    private func imageRegion(_ rect: NSRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let s = CGFloat(cg.width) / imageSize.width
        let px = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral
        guard let part = cg.cropping(to: px) else { return nil }
        return NSImage(cgImage: part, size: rect.size)
    }

    /// Average colour just outside `rect`, used to fill the hole left behind.
    private func surroundingColor(_ rect: NSRect) -> NSColor {
        guard let rep = sourceBitmap else { return .white }
        let s = CGFloat(rep.pixelsWide) / imageSize.width
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
        func sample(_ x: CGFloat, _ y: CGFloat) {
            let px = Int(x * s), py = Int(y * s)
            guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                  let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
        let o: CGFloat = 2
        for i in 0...12 {
            let t = CGFloat(i) / 12
            sample(rect.minX + rect.width * t, rect.minY - o)
            sample(rect.minX + rect.width * t, rect.maxY + o)
            sample(rect.minX - o, rect.minY + rect.height * t)
            sample(rect.maxX + o, rect.minY + rect.height * t)
        }
        guard n > 0 else { return .white }
        return NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
    }

    private func eraseItem(_ rect: NSRect) -> MarkupItem {
        MarkupItem(.erase(rect), color: surroundingColor(rect), lineWidth: 0, fontSize: 0)
    }

    /// Delete: fill the selected area with the surrounding colour.
    func eraseArea(_ rect: NSRect) {
        window?.undoManager?.beginUndoGrouping()
        addItem(eraseItem(rect), actionName: "Erase Area")
        setCrop(nil)
        window?.undoManager?.endUndoGrouping()
        window?.undoManager?.setActionName("Erase Area")
    }

    /// Dragging inside the selection: cut the pixels out into a movable piece,
    /// fill the hole, and hand the drag to the normal move logic.
    private func liftSelection(_ rect: NSRect, at pt: NSPoint) {
        guard let pixels = imageRegion(rect) else { return }
        let piece = MarkupItem(.patch(pixels, rect), color: .clear, lineWidth: 0, fontSize: 0)
        window?.undoManager?.beginUndoGrouping()
        addItem(eraseItem(rect), actionName: "Cut Area")
        addItem(piece, actionName: "Cut Area")
        setCrop(nil)
        window?.undoManager?.endUndoGrouping()
        window?.undoManager?.setActionName("Cut Area")
        // Switch to Select with the piece picked up, so this same drag moves it.
        currentTool = .select
        delegate?.canvasDidChangeTool(.select)
        window?.invalidateCursorRects(for: self)
        selectedItem = piece
        moveStart = pt
        moveTotal = .zero
    }

    // MARK: Copy Text

    /// Recognises text inside `rect` (image points) of the original capture.
    private func copyText(in rect: NSRect) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let s = CGFloat(cg.width) / imageSize.width
        let px = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral
        guard let part = cg.cropping(to: px) else { return }
        TextRecognition.copyText(from: NSImage(cgImage: part, size: rect.size)) { [weak self] text in
            if let text { self?.delegate?.canvasDidCopyText(text) }
        }
    }

    // MARK: Editing the selection

    var hasSelection: Bool { selectedItem != nil }

    private func handleIndex(of item: MarkupItem, at p: NSPoint) -> Int? {
        let r = 8 / zoom
        return item.handles.firstIndex { abs($0.x - p.x) <= r && abs($0.y - p.y) <= r }
    }

    /// Applies a sidebar colour to the selected item. Returns false if nothing is selected.
    @discardableResult
    func recolorSelection(_ color: NSColor) -> Bool {
        guard let item = selectedItem else { return false }
        var s = item.state
        s.color = color
        setState(item, s, actionName: "Change Colour")
        return true
    }

    /// Applies a sidebar line width (2 / 4 / 8) to the selected item.
    @discardableResult
    func setSelectionLineWidth(_ choice: CGFloat) -> Bool {
        guard let item = selectedItem else { return false }
        var s = item.state
        switch item.shape {
        case .text, .step: s.fontSize = (12 + choice * 2.5) / baseZoom
        default:           s.lineWidth = choice / baseZoom
        }
        setState(item, s, actionName: "Change Line Width")
        return true
    }

    func duplicateSelection() {
        guard let item = selectedItem else { return }
        let dup = item.copy()
        dup.offset(by: NSPoint(x: 12 / zoom, y: 12 / zoom))
        addItem(dup, actionName: "Duplicate")
        selectedItem = dup
    }

    // MARK: Mouse

    private func hitItem(at p: NSPoint) -> MarkupItem? {
        items.reversed().first { $0.hitTest(p, tolerance: 4 / zoom) }
    }

    private func cropCorners(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY)]
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if isPanning {
            NSCursor.closedHand.set()
            return
        }
        if currentTool == .crop, let c = cropRect, textField == nil {
            let r = 9 / zoom
            if let i = cropCorners(c).firstIndex(where: { abs($0.x - pt.x) <= r && abs($0.y - pt.y) <= r }) {
                cropDrag = .resize(i, c)
                return
            }
            if c.contains(pt) {
                liftSelection(c, at: pt)
                return
            }
        }
        shiftDown = event.modifierFlags.contains(.shift)

        // Double-click an existing text item (any tool) to re-edit it.
        if event.clickCount == 2,
           let hit = items.reversed().first(where: {
               if case .text = $0.shape { return $0.hitTest(pt, tolerance: 4 / zoom) }
               return false
           }) {
            commitPendingText()
            beginEditing(hit)
            return
        }

        if textField != nil {
            commitPendingText()
            if currentTool != .text { return }
        }

        switch currentTool {
        case .text:
            window?.makeFirstResponder(self)
            showTextField(at: pt, string: "", fontSize: newFontSize, color: currentColor)
            return
        case .select:
            window?.makeFirstResponder(self)
            if let sel = selectedItem, let i = handleIndex(of: sel, at: pt) {
                resizeHandle = i
                resizeStartState = sel.state
                return
            }
            selectedItem = hitItem(at: pt)
            moveStart = selectedItem != nil ? pt : nil
            moveTotal = .zero
            return
        case .step:
            window?.makeFirstResponder(self)
            let next = (items.compactMap { item -> Int? in
                if case .step(_, let n) = item.shape { return n }
                return nil
            }.max() ?? 0) + 1
            addItem(makeItem(.step(pt, next)), actionName: "Add Step")
            return
        default:
            break
        }

        window?.makeFirstResponder(self)
        isPressing = true
        dragStart = pt
        dragEnd = pt
        activePoints = [pt]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning {
            delegate?.canvasPan(dx: event.deltaX, dy: event.deltaY)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        shiftDown = event.modifierFlags.contains(.shift)
        if let drag = cropDrag {
            let full = NSRect(origin: .zero, size: imageSize)
            switch drag {
            case .move(let start, let orig):
                var r = orig.offsetBy(dx: pt.x - start.x, dy: pt.y - start.y)
                r.origin.x = min(max(r.minX, 0), full.width - r.width)
                r.origin.y = min(max(r.minY, 0), full.height - r.height)
                cropRect = r
            case .resize(let i, let orig):
                let opposite = cropCorners(orig)[(i + 2) % 4]
                let p = NSPoint(x: min(max(pt.x, 0), full.width), y: min(max(pt.y, 0), full.height))
                var r = NSRect(from: opposite, to: p)
                r.size.width = max(r.width, 4); r.size.height = max(r.height, 4)
                cropRect = r
            }
            return
        }
        if currentTool == .select {
            if let i = resizeHandle, let item = selectedItem {
                item.moveHandle(i, to: pt)
                needsDisplay = true
                return
            }
            guard let item = selectedItem, let start = moveStart else { return }
            let d = NSPoint(x: pt.x - start.x, y: pt.y - start.y)
            item.offset(by: d)
            moveTotal.x += d.x; moveTotal.y += d.y
            moveStart = pt
            needsDisplay = true
            return
        }
        guard isPressing else { return }
        dragEnd = pt
        if currentTool == .pen { activePoints.append(pt) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            (spaceDown || currentTool == .pan ? NSCursor.openHand : NSCursor.arrow).set()
            return
        }
        if let drag = cropDrag {
            cropDrag = nil
            let orig: NSRect
            switch drag { case .move(_, let o), .resize(_, let o): orig = o }
            let new = cropRect
            cropRect = orig
            if new != orig { setCrop(new?.integral) }
            return
        }
        if currentTool == .select {
            if resizeHandle != nil, let item = selectedItem, let old = resizeStartState {
                registerStateUndo(item, old: old, actionName: "Resize")
                changed("Resize")
            }
            resizeHandle = nil
            resizeStartState = nil
            if let item = selectedItem, moveStart != nil, moveTotal != .zero {
                registerMoveUndo(item, delta: moveTotal)
                delegate?.canvasDidChange()
            }
            moveStart = nil
            return
        }
        guard isPressing else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        shiftDown = event.modifierFlags.contains(.shift)
        isPressing = false
        defer { activePoints = []; needsDisplay = true }

        let end = constrainedEnd()
        let big = hypot(end.x - dragStart.x, end.y - dragStart.y) > 4 / zoom
        switch currentTool {
        case .crop:
            let r = liveCropRect()
            if r.width > 2 / zoom, r.height > 2 / zoom {
                setCrop(r.integral.intersection(NSRect(origin: .zero, size: imageSize)))
            }
        case .ocr:
            let r = NSRect(from: dragStart, to: end).intersection(NSRect(origin: .zero, size: imageSize))
            if r.width > 4 / zoom, r.height > 4 / zoom { copyText(in: r) }
        case .pen:
            if activePoints.count > 1 { addItem(makeItem(.pen(activePoints)), actionName: "Draw") }
        default:
            if big, let item = previewItem() { addItem(item, actionName: "Add \(currentTool.name)") }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        shiftDown = event.modifierFlags.contains(.shift)
        if isPressing { needsDisplay = true }
        super.flagsChanged(with: event)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { super.keyDown(with: event); return }
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 53: // Esc
            if textField != nil { cancelPendingText() }
            else if cropRect != nil { setCrop(nil) }
            else if selectedItem != nil { selectedItem = nil }
            else { delegate?.canvasRequestsClose() }
            return
        case 51, 117: // Delete / Forward Delete
            if selectedItem != nil { deleteSelection() }
            else if let c = cropRect { eraseArea(c) }
            return
        case 49: // Space: hold to pan
            if !spaceDown {
                spaceDown = true
                NSCursor.openHand.set()
            }
            return
        case 123, 124, 125, 126:
            guard let item = selectedItem else { break }
            let s: CGFloat = shift ? 10 : 1
            let d: NSPoint
            switch event.keyCode {
            case 123: d = NSPoint(x: -s, y: 0)
            case 124: d = NSPoint(x: s, y: 0)
            case 125: d = NSPoint(x: 0, y: s)
            default:  d = NSPoint(x: 0, y: -s)
            }
            item.offset(by: d)
            registerMoveUndo(item, delta: d)
            needsDisplay = true
            delegate?.canvasDidChange()
            return
        default:
            break
        }

        if !shift, let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = MarkupTool.forKey(ch) {
            setTool(tool)
            delegate?.canvasDidChangeTool(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceDown {
            spaceDown = false
            window?.invalidateCursorRects(for: self)
            resetCursorRects()
            return
        }
        super.keyUp(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if textField != nil { cancelPendingText() } else { delegate?.canvasRequestsClose() }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch currentTool {
        case .select: cursor = .arrow
        case .pan:    cursor = .openHand
        case .text:   cursor = .iBeam
        default:      cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Text

    private func showTextField(at point: NSPoint, string: String, fontSize: CGFloat, color: NSColor) {
        let tf = NSTextField(string: string)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isBezeled = false
        tf.focusRingType = .none
        tf.font = MarkupItem.textFont(size: fontSize)
        tf.textColor = color
        tf.placeholderString = "Type text"
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.lineBreakMode = .byClipping
        tf.delegate = self
        tf.frame.origin = NSPoint(x: point.x - 2, y: point.y)
        addSubview(tf)
        textField = tf
        textOrigin = point
        editingFontSize = fontSize
        editingColor = color
        sizeTextField()
        window?.makeFirstResponder(tf)
        if let editor = tf.currentEditor() as? NSTextView {
            editor.insertionPointColor = color
            editor.selectedRange = NSRange(location: (string as NSString).length, length: 0)
        }
    }

    private func sizeTextField() {
        guard let tf = textField else { return }
        let origin = tf.frame.origin
        tf.sizeToFit()
        var f = tf.frame
        f.origin = origin
        f.size.width = max(60 / zoom, f.width + 8 / zoom)
        tf.frame = f
    }

    private func beginEditing(_ item: MarkupItem) {
        guard case .text(let pt, let str) = item.shape else { return }
        if currentTool != .select { selectedItem = nil }
        editingItem = item
        needsDisplay = true
        showTextField(at: pt, string: str, fontSize: item.fontSize, color: item.color)
    }

    private func tearDownTextField() -> String? {
        guard let tf = textField else { return nil }
        let str = tf.stringValue
        let editor = tf.currentEditor()
        textField = nil
        tf.delegate = nil
        tf.removeFromSuperview()
        if let editor { window?.undoManager?.removeAllActions(withTarget: editor) }
        if let fe = window?.fieldEditor(false, for: nil) {
            window?.undoManager?.removeAllActions(withTarget: fe)
        }
        window?.makeFirstResponder(self)
        return str
    }

    func commitPendingText() {
        guard let str = tearDownTextField() else { return }
        let original = editingItem
        editingItem = nil
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = original?.color ?? currentColor
        if let original, let idx = items.firstIndex(where: { $0 === original }) {
            if trimmed.isEmpty {
                removeItem(at: idx, actionName: "Delete Text")
            } else if case .text(_, let old) = original.shape, old == str {
                // unchanged
            } else {
                replaceItem(at: idx, with: MarkupItem(.text(textOrigin, str), color: color,
                                                      lineWidth: original.lineWidth, fontSize: editingFontSize),
                            actionName: "Edit Text")
            }
        } else if !trimmed.isEmpty {
            addItem(MarkupItem(.text(textOrigin, str), color: editingColor,
                               lineWidth: newLineWidth, fontSize: editingFontSize), actionName: "Add Text")
        }
        needsDisplay = true
    }

    private func cancelPendingText() {
        _ = tearDownTextField()
        editingItem = nil
        needsDisplay = true
    }

    // MARK: Undoable mutations

    private func changed(_ actionName: String) {
        window?.undoManager?.setActionName(actionName)
        needsDisplay = true
        delegate?.canvasDidChange()
    }

    private func addItem(_ item: MarkupItem, at index: Int? = nil, actionName: String) {
        let idx = index ?? items.count
        items.insert(item, at: min(idx, items.count))
        window?.undoManager?.registerUndo(withTarget: self) { target in
            if let i = target.items.firstIndex(where: { $0 === item }) {
                target.removeItem(at: i, actionName: actionName)
            }
        }
        changed(actionName)
    }

    private func removeItem(at index: Int, actionName: String) {
        let item = items.remove(at: index)
        if selectedItem === item { selectedItem = nil }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.addItem(item, at: index, actionName: actionName)
        }
        changed(actionName)
    }

    private func replaceItem(at index: Int, with newItem: MarkupItem, actionName: String) {
        let old = items[index]
        items[index] = newItem
        if selectedItem === old { selectedItem = newItem }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            if let i = target.items.firstIndex(where: { $0 === newItem }) {
                target.replaceItem(at: i, with: old, actionName: actionName)
            }
        }
        changed(actionName)
    }

    private func registerMoveUndo(_ item: MarkupItem, delta: NSPoint) {
        window?.undoManager?.registerUndo(withTarget: self) { target in
            let back = NSPoint(x: -delta.x, y: -delta.y)
            item.offset(by: back)
            target.registerMoveUndo(item, delta: back)
            target.needsDisplay = true
            target.delegate?.canvasDidChange()
        }
        window?.undoManager?.setActionName("Move")
    }

    private func setState(_ item: MarkupItem, _ new: MarkupItem.State, actionName: String) {
        let old = item.state
        item.state = new
        registerStateUndo(item, old: old, actionName: actionName)
        changed(actionName)
    }

    /// Registers an undo that restores `old` (and, via setState, a redo back).
    private func registerStateUndo(_ item: MarkupItem, old: MarkupItem.State, actionName: String) {
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.setState(item, old, actionName: actionName)
        }
        window?.undoManager?.setActionName(actionName)
    }

    func setCrop(_ rect: NSRect?) {
        let old = cropRect
        var r = rect
        if let rr = r {
            let c = rr.intersection(NSRect(origin: .zero, size: imageSize))
            r = (c.isNull || c.width < 1 || c.height < 1) ? nil : c
        }
        cropRect = r
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.setCrop(old)
        }
        changed(r == nil ? "Clear Crop" : "Crop")
    }
}

// MARK: - NSTextFieldDelegate

extension MarkupCanvasView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        sizeTextField()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            commitPendingText()
            return true
        }
        if selector == #selector(cancelOperation(_:)) {
            cancelPendingText()
            return true
        }
        return false
    }
}
