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
    private var bgBtn: SidebarIconButton!
    private var dupBtn: SidebarIconButton!
    private var container: CanvasContainerView!
    private var preview: ClipboardPreviewView!
    private var zoomBar: ZoomBarView!
    private var lastCrop: NSRect?
    private var previewWork: DispatchWorkItem?

    private let sidebarW: CGFloat = 92
    private let minCanvasW: CGFloat = 300
    private let minContentH: CGFloat = 720

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
        container.background = ExportBackground.current
        self.container = container

        let pv = ClipboardPreviewView(frame: NSRect(x: totalW - 220 - 14, y: 14, width: 220, height: 170))
        pv.autoresizingMask = [.minXMargin, .maxYMargin]
        pv.isHidden = true
        preview = pv

        let zb = ZoomBarView(frame: NSRect(x: sidebarW + 1 + 14, y: 14, width: 236, height: 30))
        zb.autoresizingMask = [.maxXMargin, .maxYMargin]
        zb.onZoom = { [weak self] factor in self?.container.setZoom(factor) }
        zb.onFit = { [weak self] in self?.container.setZoom(1, resetPan: true) }
        container.onZoomChange = { [weak zb] factor, percent in zb?.update(factor: factor, percent: percent) }
        zoomBar = zb

        [sidebar, divider, container, pv, zb].forEach { root.addSubview($0) }
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
        let topH: CGFloat = 532
        let top = FlippedView(frame: NSRect(x: 0, y: height - topH, width: sidebarW, height: topH))
        top.autoresizingMask = [.minYMargin]
        var yCur: CGFloat = 10

        func caption(_ text: String) {
            let l = NSTextField(labelWithString: text.uppercased())
            l.font = .systemFont(ofSize: 9, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            l.alignment = .center
            l.frame = NSRect(x: 0, y: yCur, width: sidebarW, height: 12)
            top.addSubview(l)
            yCur += 16
        }

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
                self.canvas.recolorSelection(color)
                self.selectSwatch(sw)
                self.refocusCanvas()
            }
            top.addSubview(sw)
        }
        swatches = allSwatches
        yCur += 3 * 30 - 6
        separator()

        // Line widths.
        caption("Line width")
        for (i, (w, name)) in [(CGFloat(2), "Thin"), (4, "Medium"), (8, "Thick")].enumerated() {
            let b = LineWidthButton(lineWidth: w, tip: "\(name) lines and text (applies to the selected shape too)")
            b.frame = NSRect(x: swX + CGFloat(i) * 30, y: yCur, width: 24, height: 24)
            b.onAction = { [weak self] in
                self?.selectWidth(w)
                self?.canvas.setSelectionLineWidth(w)
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
        let bottom = FlippedView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: 194))
        bottom.autoresizingMask = [.maxYMargin]

        let copy = SidebarIconButton(sfSymbol: "doc.on.doc", tip: "Copy (⌘C)")
        copy.onAction = { [weak self] in self?.copy(nil); self?.refocusCanvas() }
        let save = SidebarIconButton(sfSymbol: "square.and.arrow.down", tip: "Save… (⌘S)")
        save.onAction = { [weak self] in self?.saveDocument(nil) }
        let drag = SidebarIconButton(sfSymbol: "hand.draw", tip: "Drag me into another app (Mail, Slack, Finder…) to drop the image in")
        drag.onDragStart = { [weak self, weak drag] event in
            guard let self, let drag else { return }
            self.beginDragOut(from: drag, event: event)
        }
        // A plain click does nothing useful, so explain how to use it.
        drag.onAction = { [weak self] in
            Toast.show("Drag this button into another app to drop the image in")
            self?.refocusCanvas()
        }
        let pin = SidebarIconButton(sfSymbol: "pin", tip: "Pin on Screen (⌘P)")
        pin.onAction = { [weak self] in self?.pinToScreen(nil) }
        let bg = SidebarIconButton(sfSymbol: "photo.artframe", tip: "Background & Padding")
        bg.onAction = { [weak self, weak bg] in
            guard let self, let bg else { return }
            self.showBackgroundMenu(from: bg)
        }
        let dup = SidebarIconButton(sfSymbol: "plus.square.on.square", tip: "Duplicate Selection (⌘D)")
        dup.onAction = { [weak self] in self?.duplicate(nil); self?.refocusCanvas() }
        let snip = SidebarIconButton(sfSymbol: "camera.viewfinder", tip: "New Snip")
        snip.onAction = { [weak self] in self?.newSnip() }

        // One-off actions (not tools), so they never stay selected.
        let actions = NSTextField(labelWithString: "ACTIONS")
        actions.font = .systemFont(ofSize: 9, weight: .semibold)
        actions.textColor = .tertiaryLabelColor
        actions.alignment = .center
        actions.frame = NSRect(x: 0, y: 0, width: sidebarW, height: 12)
        bottom.addSubview(actions)
        let y0: CGFloat = 22
        copy.frame = NSRect(x: toolX, y: y0, width: 36, height: 36)
        save.frame = NSRect(x: toolX + 42, y: y0, width: 36, height: 36)
        drag.frame = NSRect(x: toolX, y: y0 + 42, width: 36, height: 36)
        snip.frame = NSRect(x: toolX + 42, y: y0 + 42, width: 36, height: 36)
        pin.frame = NSRect(x: toolX, y: y0 + 84, width: 36, height: 36)
        bg.frame = NSRect(x: toolX + 42, y: y0 + 84, width: 36, height: 36)
        dup.frame = NSRect(x: toolX, y: y0 + 126, width: 36, height: 36)
        bg.isSelected = ExportBackground.current.isOn
        dup.isEnabled = false
        dupBtn = dup
        bgBtn = bg
        [copy, save, drag, snip, pin, bg, dup].forEach { bottom.addSubview($0) }
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
        preview.show(title: "Copied to clipboard", image: img)
        ReviewPrompter.recordSuccessfulExport()
    }

    /// ⇧⌘C picks the Copy Text tool: drag a box to copy the text inside it.
    @objc func copyRecognizedText(_ sender: Any?) {
        canvas.commitPendingText()
        selectTool(.ocr)
    }

    /// Floats the marked-up image above other windows and closes the editor.
    @objc func pinToScreen(_ sender: Any?) {
        canvas.commitPendingText()
        guard let img = renderFinal() else { return }
        PinController.shared.pin(img)
        close()
    }

    @objc func zoomIn(_ sender: Any?) { container.setZoom(container.zoomFactor * 1.25) }
    @objc func zoomOut(_ sender: Any?) { container.setZoom(container.zoomFactor / 1.25) }
    @objc func zoomToFit(_ sender: Any?) { container.setZoom(1, resetPan: true) }

    @objc func duplicate(_ sender: Any?) {
        canvas.duplicateSelection()
    }

    // MARK: Background

    private func showBackgroundMenu(from button: NSView) {
        let menu = NSMenu()
        let style = ExportBackground.current
        for fill in ExportBackground.Fill.allCases {
            let item = NSMenuItem(title: fill.title, action: #selector(pickBackground(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fill.rawValue
            item.state = fill == style.fill ? .on : .off
            if fill.colors.count > 0 { item.image = swatchImage(for: fill) }
            menu.addItem(item)
            if fill == .none { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Padding", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for pad in ExportBackground.Padding.allCases {
            let item = NSMenuItem(title: pad.title, action: #selector(pickPadding(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pad.rawValue
            item.state = pad == style.padding ? .on : .off
            item.isEnabled = style.isOn
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX + 4, y: button.bounds.maxY), in: button)
        refocusCanvas()
    }

    private func swatchImage(for fill: ExportBackground.Fill) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).addClip()
            ExportBackground(fill: fill, padding: .m).drawFill(in: r)
            return true
        }
    }

    @objc private func pickBackground(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        AppSettings.backgroundFill = raw
        applyBackground()
    }

    @objc private func pickPadding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        AppSettings.backgroundPadding = raw
        applyBackground()
    }

    private func applyBackground() {
        let style = ExportBackground.current
        bgBtn.isSelected = style.isOn
        container.background = style
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
        let folder = RecordingFolderManager.screenshots.folderURL
        if AppSettings.saveWithoutAsking, let folder {
            quickSave(to: folder)
            return
        }
        let panel = NSSavePanel()
        if let folder { panel.directoryURL = folder }
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
                ReviewPrompter.recordSuccessfulExport()
            } catch {
                AppAlert.show(error: error, title: "Couldn't Save Image")
            }
        }
    }

    /// Saves with a timestamped name into the chosen screenshots folder, no panel.
    private func quickSave(to folder: URL) {
        let jpeg = AppSettings.saveFormat == "jpeg"
        guard let rep = renderFinalRep(),
              let data = jpeg
                ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                : rep.representation(using: .png, properties: [:]) else {
            AppAlert.show(title: "Couldn't Save Image", message: "The image couldn't be encoded.")
            return
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(AppSettings.timestampedFileName(ext: jpeg ? "jpg" : "png"))
        do {
            try data.write(to: url, options: .withoutOverwriting)
            saveBtn.showConfirmation()
            ReviewPrompter.recordSuccessfulExport()
        } catch {
            AppAlert.show(error: error, title: "Couldn't Save Image")
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
        guard let rep = renderAnnotatedRep() else { return nil }
        let style = ExportBackground.current
        return style.isOn ? (style.compose(rep) ?? rep) : rep
    }

    /// The (cropped) capture with annotations, before any background.
    private func renderAnnotatedRep() -> NSBitmapImageRep? {
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
        case #selector(duplicate(_:)):
            return canvas.hasSelection
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

// MARK: - MarkupCanvasDelegate

extension MarkupEditorWindow: MarkupCanvasDelegate {
    func canvasDidChange() {
        // While a crop is set, keep the preview showing what Copy will produce.
        let crop = canvas.cropRect
        guard crop != nil || lastCrop != nil else { return }
        lastCrop = crop
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.canvas.cropRect == nil {
                self.preview.hide()
            } else if let img = self.renderFinal() {
                self.preview.show(title: "Crop · ⌘C to copy", image: img)
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func canvasSelectionDidChange() {
        dupBtn?.isEnabled = canvas.hasSelection
    }

    func canvasPan(dx: CGFloat, dy: CGFloat) {
        container.pan(dx: dx, dy: -dy)
    }

    func canvasDidCopyText(_ text: String) {
        preview.show(title: "Copied text", text: text)
    }

    func canvasDidChangeTool(_ tool: MarkupTool) {
        syncToolButtons(tool)
    }

    func canvasRequestsClose() {
        performClose(nil)
    }

    func canvasDisplayRectDidChange() {
        container?.fitCanvas()
    }
}

// MARK: - Helper views

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Aspect-fits and centres the canvas (never scaling above 1×) on every resize.
private final class CanvasContainerView: NSView {
    private let canvas: MarkupCanvasView
    var background: ExportBackground? {
        didSet { fitCanvas(); needsDisplay = true }
    }

    /// User zoom relative to fit-to-window (1 = fit), and pan offset in points.
    private(set) var zoomFactor: CGFloat = 1
    private var panOffset = NSPoint.zero
    var onZoomChange: ((CGFloat, Int) -> Void)?

    static let zoomRange: ClosedRange<CGFloat> = 0.25...8

    func setZoom(_ factor: CGFloat, resetPan: Bool = false, anchor: NSPoint? = nil) {
        let old = zoomFactor
        let new = min(max(factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        // Keep the point under the anchor (default: centre) fixed while zooming.
        let a = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let centre = NSPoint(x: bounds.midX + panOffset.x, y: bounds.midY + panOffset.y)
        let k = new / old
        panOffset = resetPan ? .zero : NSPoint(x: a.x + (centre.x - a.x) * k - bounds.midX,
                                               y: a.y + (centre.y - a.y) * k - bounds.midY)
        zoomFactor = new
        fitCanvas()
        needsDisplay = true
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        panOffset.x += dx
        panOffset.y += dy
        fitCanvas()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 10
            setZoom(zoomFactor * (1 + step), anchor: convert(event.locationInWindow, from: nil))
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan(dx: event.scrollingDeltaX * k, dy: -event.scrollingDeltaY * k)
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoomFactor * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

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

        // Live preview of the export background around the canvas.
        guard let bg = background, bg.isOn else { return }
        let s = canvas.zoom
        let p = bg.pad(for: canvas.displayRect.size) * s
        bg.drawFill(in: canvas.frame.insetBy(dx: -p, dy: -p))
        bg.drawShadow(for: canvas.frame, scale: s)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        fitCanvas()
    }

    func fitCanvas() {
        let img = canvas.displayRect.size
        guard img.width > 0, img.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let bg = background?.isOn == true ? background : nil
        let pad = bg?.pad(for: img) ?? 0
        let fit = min(1, min(bounds.width / (img.width + 2 * pad), bounds.height / (img.height + 2 * pad)))
        let s = fit * zoomFactor
        let w = img.width * s, h = img.height * s
        // Don't let the image be panned completely out of view.
        let limX = max(0, (w + 2 * pad * s - bounds.width) / 2) + 40
        let limY = max(0, (h + 2 * pad * s - bounds.height) / 2) + 40
        if zoomFactor <= 1 { panOffset = .zero }
        panOffset.x = min(max(panOffset.x, -limX), limX)
        panOffset.y = min(max(panOffset.y, -limY), limY)
        let f = NSRect(x: (bounds.width - w) / 2 + panOffset.x, y: (bounds.height - h) / 2 + panOffset.y,
                       width: w, height: h).integral
        canvas.baseZoom = fit
        canvas.frame = f
        onZoomChange?(zoomFactor, Int((s * 100).rounded()))
        // In image points; drawn as a clip by the canvas (layer-backing the
        // canvas for a corner radius breaks its mouse handling).
        canvas.previewCornerRadius = bg?.cornerRadius(for: img) ?? 0
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
        MarkupItem.drawSpotlights(items, imageSize: imageSize)
        for item in items { item.draw(drawContext) }
    }
}

// MARK: - Background

/// Puts the screenshot on a gradient or solid colour with padding, rounded
/// corners and a shadow. Applied at export time (and previewed in the editor).
struct ExportBackground {
    enum Fill: String, CaseIterable {
        case none, ocean, sunset, midnight, mint, white, grey, dark

        var title: String {
            switch self {
            case .none:     return "None"
            case .ocean:    return "Ocean"
            case .sunset:   return "Sunset"
            case .midnight: return "Midnight"
            case .mint:     return "Mint"
            case .white:    return "White"
            case .grey:     return "Light Grey"
            case .dark:     return "Dark"
            }
        }

        var colors: [NSColor] {
            func c(_ hex: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
            switch self {
            case .none:     return []
            case .ocean:    return [c(0x4A90FF), c(0x7B5CFF)]
            case .sunset:   return [c(0xFF7E5F), c(0xFEB47B)]
            case .midnight: return [c(0x232526), c(0x414345)]
            case .mint:     return [c(0x43E97B), c(0x38F9D7)]
            case .white:    return [c(0xF5F5F7)]
            case .grey:     return [c(0xD1D1D6)]
            case .dark:     return [c(0x1C1C1E)]
            }
        }
    }

    enum Padding: String, CaseIterable {
        case s, m, l
        var title: String { ["s": "Small", "m": "Medium", "l": "Large"][rawValue]! }
        var factor: CGFloat { ["s": 0.05, "m": 0.08, "l": 0.12][rawValue]! }
    }

    var fill: Fill
    var padding: Padding

    static var current: ExportBackground {
        ExportBackground(fill: Fill(rawValue: AppSettings.backgroundFill) ?? .none,
                        padding: Padding(rawValue: AppSettings.backgroundPadding) ?? .m)
    }

    var isOn: Bool { fill != .none }

    /// Padding in points for content of the given size.
    func pad(for size: NSSize) -> CGFloat {
        max(16, max(size.width, size.height) * padding.factor).rounded()
    }

    func cornerRadius(for size: NSSize) -> CGFloat {
        min(14, min(size.width, size.height) * 0.06)
    }

    /// Fills `rect` with the gradient or solid colour.
    func drawFill(in rect: NSRect) {
        let cols = fill.colors
        if cols.count > 1, let g = NSGradient(colors: cols) {
            g.draw(in: rect, angle: -35)
        } else if let c = cols.first {
            c.setFill()
            rect.fill()
        }
    }

    /// Draws the shadow-casting rounded card for `content` (call before the image).
    func drawShadow(for content: NSRect, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(fill == .dark || fill == .midnight ? 0.6 : 0.35)
        shadow.shadowBlurRadius = 24 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.set()
        let r = cornerRadius(for: content.size)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: content, xRadius: r, yRadius: r).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Wraps an exported bitmap (sized in points via `rep.size`) in the background.
    func compose(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        let pt = rep.size
        guard pt.width > 0, pt.height > 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / pt.width
        let p = pad(for: pt)
        let outPt = NSSize(width: pt.width + 2 * p, height: pt.height + 2 * p)
        let pw = Int((outPt.width * scale).rounded()), ph = Int((outPt.height * scale).rounded())
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let full = NSRect(x: 0, y: 0, width: CGFloat(pw), height: CGFloat(ph))
        drawFill(in: full)
        let content = NSRect(x: p * scale, y: p * scale, width: pt.width * scale, height: pt.height * scale)
        drawShadow(for: content, scale: scale)
        let r = cornerRadius(for: pt) * scale
        NSBezierPath(roundedRect: content, xRadius: r, yRadius: r).addClip()
        rep.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        out.size = outPt
        return out
    }
}


// MARK: - Clipboard preview

/// Small panel in the editor's bottom-right corner showing what was just
/// copied (image or text), or what the current crop will copy.
private final class ClipboardPreviewView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let textView = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 10, y: frame.height - 24, width: frame.width - 40, height: 16)
        titleLabel.autoresizingMask = [.width, .minYMargin]

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide preview")
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.frame = NSRect(x: frame.width - 26, y: frame.height - 26, width: 18, height: 18)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        let body = NSRect(x: 10, y: 10, width: frame.width - 20, height: frame.height - 40)
        imageView.frame = body
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        textView.frame = body
        textView.font = .systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.maximumNumberOfLines = 8
        textView.lineBreakMode = .byTruncatingTail

        [titleLabel, closeButton, imageView, textView].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, image: NSImage) {
        titleLabel.stringValue = title
        imageView.image = image
        imageView.isHidden = false
        textView.isHidden = true
        reveal()
    }

    func show(title: String, text: String) {
        titleLabel.stringValue = title
        textView.stringValue = text
        textView.isHidden = false
        imageView.isHidden = true
        imageView.image = nil
        reveal()
    }

    func hide() {
        isHidden = true
        imageView.image = nil
    }

    private func reveal() {
        guard isHidden else { return }
        alphaValue = 0
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }

    @objc private func closeTapped() { hide() }
}


// MARK: - Zoom bar

/// − [slider] + 100% Fit, floating at the bottom-left of the canvas area.
private final class ZoomBarView: NSVisualEffectView {
    var onZoom: ((CGFloat) -> Void)?
    var onFit: (() -> Void)?

    private let slider = NSSlider()
    private let percent = NSTextField(labelWithString: "100%")

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                             target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.contentTintColor = .secondaryLabelColor
            return b
        }
        let minus = button("minus.magnifyingglass", "Zoom Out (⌘−)", #selector(zoomOut))
        let plus = button("plus.magnifyingglass", "Zoom In (⌘+)", #selector(zoomIn))
        let fit = NSButton(title: "Fit", target: self, action: #selector(fitTapped))
        fit.bezelStyle = .inline
        fit.toolTip = "Zoom to Fit (⌘0)"
        fit.font = .systemFont(ofSize: 11, weight: .medium)

        // Slider works on log2 of the zoom so each step feels even.
        slider.minValue = Double(log2(0.25))
        slider.maxValue = Double(log2(8.0))
        slider.doubleValue = 0
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.toolTip = "Zoom (pinch, or ⌘-scroll)"

        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right

        let y = (frame.height - 18) / 2
        minus.frame = NSRect(x: 8, y: y, width: 20, height: 18)
        slider.frame = NSRect(x: 30, y: y, width: 92, height: 18)
        plus.frame = NSRect(x: 124, y: y, width: 20, height: 18)
        percent.frame = NSRect(x: 146, y: y + 1, width: 42, height: 16)
        fit.frame = NSRect(x: 192, y: y - 1, width: 36, height: 20)
        [minus, slider, plus, percent, fit].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(factor: CGFloat, percent value: Int) {
        slider.doubleValue = Double(log2(factor))
        percent.stringValue = "\(value)%"
    }

    @objc private func sliderMoved() { onZoom?(CGFloat(pow(2, slider.doubleValue))) }
    @objc private func zoomIn() { onZoom?(CGFloat(pow(2, slider.doubleValue)) * 1.25) }
    @objc private func zoomOut() { onZoom?(CGFloat(pow(2, slider.doubleValue)) / 1.25) }
    @objc private func fitTapped() { onFit?() }
}
