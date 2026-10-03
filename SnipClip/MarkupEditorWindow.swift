import AppKit
import UniformTypeIdentifiers
import QuartzCore

// MARK: - Controller

final class MarkupEditorController: NSObject, NSWindowDelegate {
    static let shared = MarkupEditorController()
    private var editorWindow: MarkupEditorWindow?

    func show(image: NSImage, entry: CaptureHistory.Entry?) {
        closeIfOpen()
        let win = MarkupEditorWindow(image: image, entry: entry)
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(win.canvas)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow = win
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? MarkupEditorWindow else { return }
        win.saveStateToEntry()
        if editorWindow === win { editorWindow = nil }
        // Let the window and its image deallocate before trimming.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard self.editorWindow == nil else { return }
            CaptureHistory.shared.trimMemory()
        }
    }

    /// Closes any open editor so it can't be captured in a later screenshot.
    func closeIfOpen() {
        guard let win = editorWindow else { return }
        editorWindow = nil
        win.close()
    }
}

// MARK: - Window

final class MarkupEditorWindow: NSWindow, NSDraggingSource {
    private let sourceImage: NSImage
    private let entry: CaptureHistory.Entry?
    private(set) var canvas: MarkupCanvasView!

    private var toolButtons: [MarkupTool: SidebarIconButton] = [:]
    private var swatches: [SwatchButton] = []
    private var widthButtons: [LineWidthButton] = []
    private var copyBtn: SidebarIconButton!
    private var saveBtn: SidebarIconButton!

    private let sidebarW: CGFloat = 92
    private let minCanvasW: CGFloat = 300
    private let minContentH: CGFloat = 540

    init(image: NSImage, entry: CaptureHistory.Entry?) {
        self.sourceImage = image
        self.entry = entry

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first!
        let vis = screen.visibleFrame
        let imgW = max(1, image.size.width), imgH = max(1, image.size.height)
        let maxW = vis.width * 0.9 - sidebarW - 1
        let maxH = vis.height * 0.9
        let scale = min(1, min(maxW / imgW, maxH / imgH))
        let canvasW = (imgW * scale).rounded(), canvasH = (imgH * scale).rounded()
        let totalW = sidebarW + 1 + max(canvasW, minCanvasW)
        let totalH = max(canvasH, minContentH)

        let x = max(vis.minX, min(vis.midX - totalW / 2, vis.maxX - totalW))
        let y = max(vis.minY, min(vis.midY - totalH / 2, vis.maxY - totalH))

        super.init(contentRect: NSRect(x: x, y: y, width: totalW, height: totalH),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)

        title = "SnipClip"
        let px = entry?.pixelSize ?? Self.pixelSize(of: image)
        subtitle = "\(Int(px.width)) × \(Int(px.height)) px"
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: sidebarW + 1 + minCanvasW, height: minContentH)

        buildContent(totalW: totalW, totalH: totalH)

        if let entry {
            canvas.restore(items: entry.items.map { $0.copy() }, crop: entry.cropRect)
        }
        initialFirstResponder = canvas
    }

    private static func pixelSize(of image: NSImage) -> NSSize {
        let maxW = image.representations.map { $0.pixelsWide }.max() ?? 0
        let maxH = image.representations.map { $0.pixelsHigh }.max() ?? 0
        if maxW > 0, maxH > 0 { return NSSize(width: maxW, height: maxH) }
        return image.size
    }

    func saveStateToEntry() {
        canvas.commitPendingText()
        entry?.items = canvas.items.map { $0.copy() }
        entry?.cropRect = canvas.cropRect
    }

    // MARK: Layout

    private func buildContent(totalW: CGFloat, totalH: CGFloat) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: totalH))
        root.autoresizingMask = [.width, .height]

        let sidebar = buildSidebar(height: totalH)
        sidebar.autoresizingMask = [.height]

        let divider = NSBox(frame: NSRect(x: sidebarW, y: 0, width: 1, height: totalH))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]

        let cv = MarkupCanvasView(image: sourceImage)
        cv.delegate = self
        canvas = cv

        let container = CanvasContainerView(
            frame: NSRect(x: sidebarW + 1, y: 0, width: totalW - sidebarW - 1, height: totalH), canvas: cv)
        container.autoresizingMask = [.width, .height]

        [sidebar, divider, container].forEach { root.addSubview($0) }
        contentView = root
        container.fitCanvas()
        selectTool(.pen)
        selectSwatch(swatches.first)
        selectWidth(4)
    }

    private func buildSidebar(height: CGFloat) -> NSView {
        // Final frame up front — never resize after adding subviews.
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: height))
        bar.material = .sidebar
        bar.blendingMode = .withinWindow
        bar.state = .active

        // ── Top group (flipped, laid out top-down) ──
        let topH: CGFloat = 430
        let top = FlippedView(frame: NSRect(x: 0, y: height - topH, width: sidebarW, height: topH))
        top.autoresizingMask = [.minYMargin]
        var yCur: CGFloat = 10

        func separator() {
            yCur += 8
            let s = NSBox(frame: NSRect(x: 10, y: yCur, width: sidebarW - 20, height: 1))
            s.boxType = .separator
            top.addSubview(s)
            yCur += 9
        }

        // Tools: 2 columns of 36pt, 6pt gaps.
        let toolX = (sidebarW - (36 * 2 + 6)) / 2
        for (i, tool) in MarkupTool.allCases.enumerated() {
            let btn = SidebarIconButton(sfSymbol: tool.symbol, tip: tool.tooltip, isTool: true)
            btn.frame = NSRect(x: toolX + CGFloat(i % 2) * 42, y: yCur + CGFloat(i / 2) * 42, width: 36, height: 36)
            btn.onAction = { [weak self] in
                self?.selectTool(tool)
                self?.refocusCanvas()
            }
            top.addSubview(btn)
            toolButtons[tool] = btn
        }
        yCur += CGFloat((MarkupTool.allCases.count + 1) / 2) * 42 - 6
        separator()

        // Colours: 3 columns of 24pt.
        let colours: [(NSColor, String)] = [
            (.systemRed, "Red"), (.systemOrange, "Orange"), (.systemYellow, "Yellow"),
            (.systemGreen, "Green"), (.systemBlue, "Blue"), (.systemPurple, "Purple"),
            (.black, "Black"), (.white, "White"),
        ]
        let swX = (sidebarW - (24 * 3 + 12)) / 2
        var allSwatches: [SwatchButton] = colours.map { SwatchButton(color: $0.0, tip: $0.1) }
        allSwatches.append(SwatchButton(color: nil, tip: "Custom Colour…", isCustom: true))
        for (i, sw) in allSwatches.enumerated() {
            sw.frame = NSRect(x: swX + CGFloat(i % 3) * 30, y: yCur + CGFloat(i / 3) * 30, width: 24, height: 24)
            sw.onPick = { [weak self, weak sw] color in
                guard let self else { return }
                self.canvas.currentColor = color
                self.selectSwatch(sw)
                self.refocusCanvas()
            }
            top.addSubview(sw)
        }
        swatches = allSwatches
        yCur += 3 * 30 - 6
        separator()

        // Line widths.
        for (i, w) in [CGFloat(2), 4, 8].enumerated() {
            let b = LineWidthButton(lineWidth: w, tip: "Line Width \(Int(w))")
            b.frame = NSRect(x: swX + CGFloat(i) * 30, y: yCur, width: 24, height: 24)
            b.onAction = { [weak self] in
                self?.selectWidth(w)
                self?.refocusCanvas()
            }
            top.addSubview(b)
            widthButtons.append(b)
        }
        yCur += 24
        separator()

        // Undo / Redo.
        let undoBtn = SidebarIconButton(sfSymbol: "arrow.uturn.backward", tip: "Undo (⌘Z)")
        undoBtn.frame = NSRect(x: toolX, y: yCur, width: 36, height: 36)
        undoBtn.onAction = { [weak self] in self?.undo(nil); self?.refocusCanvas() }
        let redoBtn = SidebarIconButton(sfSymbol: "arrow.uturn.forward", tip: "Redo (⇧⌘Z)")
        redoBtn.frame = NSRect(x: toolX + 42, y: yCur, width: 36, height: 36)
        redoBtn.onAction = { [weak self] in self?.redo(nil); self?.refocusCanvas() }
        top.addSubview(undoBtn)
        top.addSubview(redoBtn)
        bar.addSubview(top)

        // ── Bottom group ──
        let bottom = FlippedView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: 88))
        bottom.autoresizingMask = [.maxYMargin]

        let copy = SidebarIconButton(sfSymbol: "doc.on.doc", tip: "Copy (⌘C)")
        copy.onAction = { [weak self] in self?.copy(nil); self?.refocusCanvas() }
        let save = SidebarIconButton(sfSymbol: "square.and.arrow.down", tip: "Save… (⌘S)")
        save.onAction = { [weak self] in self?.saveDocument(nil) }
        let drag = SidebarIconButton(sfSymbol: "hand.draw", tip: "Drag into another app")
        drag.onDragStart = { [weak self, weak drag] event in
            guard let self, let drag else { return }
            self.beginDragOut(from: drag, event: event)
        }
        drag.onAction = { [weak self] in self?.refocusCanvas() }
        let snip = SidebarIconButton(sfSymbol: "camera.viewfinder", tip: "New Snip")
        snip.onAction = { [weak self] in self?.newSnip() }

        copy.frame = NSRect(x: toolX, y: 0, width: 36, height: 36)
        save.frame = NSRect(x: toolX + 42, y: 0, width: 36, height: 36)
        drag.frame = NSRect(x: toolX, y: 42, width: 36, height: 36)
        snip.frame = NSRect(x: toolX + 42, y: 42, width: 36, height: 36)
        [copy, save, drag, snip].forEach { bottom.addSubview($0) }
        copyBtn = copy
        saveBtn = save
        bar.addSubview(bottom)

        return bar
    }

    private func refocusCanvas() {
        guard let canvas, !canvas.isEditingText else { return }
        makeFirstResponder(canvas)
    }

    // MARK: Selection state

    private func selectTool(_ tool: MarkupTool) {
        canvas?.setTool(tool)
        syncToolButtons(tool)
    }

    private func syncToolButtons(_ tool: MarkupTool) {
        for (t, btn) in toolButtons { btn.isSelected = (t == tool) }
    }

    private func selectSwatch(_ swatch: SwatchButton?) {
        for s in swatches { s.isSelected = (s === swatch) }
        if let c = swatch?.color { canvas.currentColor = c }
    }

    private func selectWidth(_ w: CGFloat) {
        canvas.lineWidthChoice = w
        for b in widthButtons { b.isSelected = (b.lineWidth == w) }
    }

    // MARK: Menu actions (responder chain)

    @objc func copy(_ sender: Any?) {
        canvas.commitPendingText()
        guard let img = renderFinal() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        copyBtn.showConfirmation()
    }

    @objc func undo(_ sender: Any?) {
        canvas.commitPendingText()
        if undoManager?.canUndo == true { undoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if undoManager?.canRedo == true { undoManager?.redo() }
    }

    @objc func delete(_ sender: Any?) {
        canvas.deleteSelection()
    }

    // MARK: Save

    @objc func saveDocument(_ sender: Any?) {
        canvas.commitPendingText()
        let panel = NSSavePanel()
        let isJPEG = AppSettings.saveFormat == "jpeg"
        panel.allowedContentTypes = [isJPEG ? .jpeg : .png]
        panel.nameFieldStringValue = AppSettings.timestampedFileName(ext: isJPEG ? "jpg" : "png")

        let label = NSTextField(labelWithString: "Format:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["PNG", "JPEG"])
        popup.selectItem(at: isJPEG ? 1 : 0)
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.frame.size = stack.fittingSize
        panel.accessoryView = stack

        panel.beginSheetModal(for: self) { [weak self] response in
            guard let self else { return }
            defer { self.refocusCanvas() }
            guard response == .OK, let url = panel.url else { return }
            let jpeg = popup.indexOfSelectedItem == 1
            AppSettings.saveFormat = jpeg ? "jpeg" : "png"
            guard let rep = self.renderFinalRep(),
                  let data = jpeg
                    ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                    : rep.representation(using: .png, properties: [:]) else {
                AppAlert.show(title: "Couldn't Save Image", message: "The image couldn't be encoded.")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self.saveBtn.showConfirmation()
            } catch {
                AppAlert.show(error: error, title: "Couldn't Save Image")
            }
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let panel = sender.window as? NSSavePanel else { return }
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        let jpeg = sender.indexOfSelectedItem == 1
        panel.allowedContentTypes = [jpeg ? .jpeg : .png]
        panel.nameFieldStringValue = base + (jpeg ? ".jpg" : ".png")
    }

    // MARK: Drag out

    private func beginDragOut(from view: NSView, event: NSEvent) {
        canvas.commitPendingText()
        guard let rep = renderFinalRep(), let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnipClip Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(AppSettings.timestampedFileName(ext: "png"))
        do { try png.write(to: url, options: .atomic) } catch { return }

        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(png, forType: .png)

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let thumb = NSImage(size: rep.size)
        thumb.addRepresentation(rep)
        let s = min(1, 96 / max(rep.size.width, rep.size.height, 1))
        let size = NSSize(width: rep.size.width * s, height: rep.size.height * s)
        let p = view.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                         width: size.width, height: size.height), contents: thumb)
        view.beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: New snip

    private func newSnip() {
        MarkupEditorController.shared.closeIfOpen()
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            SelectionOverlayController.shared.begin(purpose: .capture) { sel in
                if let img = sel?.image { CaptureDelivery.deliver(img) }
            }
        }
    }

    // MARK: Render

    private func renderFinal() -> NSImage? {
        guard let rep = renderFinalRep() else { return nil }
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    /// Renders through an offscreen flipped view using the exact same draw
    /// calls as the on-screen canvas (no hand-rolled CGContext flips).
    private func renderFinalRep() -> NSBitmapImageRep? {
        let imgSize = canvas.imageSize
        let full = NSRect(origin: .zero, size: imgSize)
        var crop = (canvas.cropRect ?? full).intersection(full)
        if crop.isNull || crop.width < 1 || crop.height < 1 { crop = full }

        let maxPx = sourceImage.representations.map { $0.pixelsWide }.max() ?? 0
        var pxScale = maxPx > 0 ? CGFloat(maxPx) / imgSize.width : 1
        if !pxScale.isFinite || pxScale <= 0 { pxScale = 1 }

        let pw = max(1, Int((crop.width * pxScale).rounded()))
        let ph = max(1, Int((crop.height * pxScale).rounded()))

        let renderView = RenderCanvasView(frame: NSRect(x: 0, y: 0, width: CGFloat(pw), height: CGFloat(ph)))
        renderView.backgroundImage = sourceImage
        renderView.imageSize = imgSize
        renderView.items = canvas.items
        renderView.drawContext = canvas.drawContext
        renderView.scale = pxScale
        renderView.origin = crop.origin

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = renderView.bounds.size
        renderView.cacheDisplay(in: renderView.bounds, to: rep)
        rep.size = crop.size
        return rep
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - NSMenuItemValidation

extension MarkupEditorWindow {
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        case #selector(redo(_:)):
            menuItem.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

// MARK: - MarkupCanvasDelegate

extension MarkupEditorWindow: MarkupCanvasDelegate {
    func canvasDidChange() {}

    func canvasDidChangeTool(_ tool: MarkupTool) {
        syncToolButtons(tool)
    }

    func canvasRequestsClose() {
        performClose(nil)
    }
}

// MARK: - Helper views

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Aspect-fits and centres the canvas (never scaling above 1×) on every resize.
private final class CanvasContainerView: NSView {
    private let canvas: MarkupCanvasView

    init(frame: NSRect, canvas: MarkupCanvasView) {
        self.canvas = canvas
        super.init(frame: frame)
        wantsLayer = true
        // Since the macOS 14 SDK views don't clip by default, and dirtyRect
        // can extend past bounds — unclipped, this fill painted over the
        // sidebar next to it.
        clipsToBounds = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        fitCanvas()
    }

    func fitCanvas() {
        let img = canvas.imageSize
        guard img.width > 0, img.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let s = min(1, min(bounds.width / img.width, bounds.height / img.height))
        let w = img.width * s, h = img.height * s
        let f = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        canvas.frame = f
    }
}

/// Offscreen stand-in for MarkupCanvasView used only by renderFinal(). Its
/// bounds are the output in pixels; it scales to image points and shifts by
/// the crop origin, then draws exactly like the canvas.
private final class RenderCanvasView: NSView {
    var backgroundImage: NSImage?
    var imageSize: NSSize = .zero
    var items: [MarkupItem] = []
    var drawContext = MarkupDrawContext(pixelated: nil, imageSize: .zero)
    var scale: CGFloat = 1
    var origin: NSPoint = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let t = NSAffineTransform()
        t.scale(by: scale)
        t.translateX(by: -origin.x, yBy: -origin.y)
        t.concat()
        backgroundImage?.draw(in: NSRect(origin: .zero, size: imageSize))
        for item in items { item.draw(drawContext) }
    }
}
