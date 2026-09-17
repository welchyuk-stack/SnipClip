import AppKit
import UniformTypeIdentifiers
import QuartzCore

// MARK: - Controller

final class MarkupEditorController: NSObject, NSWindowDelegate {
    static let shared = MarkupEditorController()
    private var editorWindow: MarkupEditorWindow?

    func show(image: NSImage) {
        editorWindow?.close()
        let win = MarkupEditorWindow(image: image)
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow = win
    }

    func windowWillClose(_ notification: Notification) {
        editorWindow = nil
    }

    /// Closes any open editor window so it can't linger on screen and get
    /// captured as part of a subsequent screenshot.
    func closeIfOpen() {
        editorWindow?.close()
        editorWindow = nil
    }
}

// MARK: - Window

final class MarkupEditorWindow: NSWindow {
    private let sourceImage: NSImage
    private var canvasView: MarkupCanvasView!

    // Left sidebar
    private var toolButtons: [MarkupTool: SidebarIconButton] = [:]
    private var copyBtn: SidebarIconButton!
    private var colorPicker: ColorPickerButton!

    private let sidebarW: CGFloat = 52

    init(image: NSImage) {
        self.sourceImage = image

        // Use the screen with the most available space rather than assuming main
        let screen = NSScreen.screens.max(by: { $0.visibleFrame.width < $1.visibleFrame.width })
                     ?? NSScreen.main ?? NSScreen.screens.first!
        let maxW = screen.visibleFrame.width  * 0.90 - sidebarW
        let maxH = screen.visibleFrame.height * 0.90
        let scale = min(1.0, min(maxW / image.size.width, maxH / image.size.height))
        let canvasW = image.size.width  * scale
        let canvasH = image.size.height * scale
        let totalW = max(canvasW, 200) + sidebarW
        // Window must be at least 480pt tall so sidebar button groups never overlap,
        // but the canvas stays at its natural size — no image stretching.
        let totalH = max(canvasH, 558)

        let cx = max(screen.visibleFrame.minX,
                     min(screen.visibleFrame.midX - totalW / 2,
                         screen.visibleFrame.maxX - totalW))
        let cy = max(screen.visibleFrame.minY,
                     min(screen.visibleFrame.midY - totalH / 2,
                         screen.visibleFrame.maxY - totalH))

        super.init(
            contentRect: NSRect(x: cx, y: cy, width: totalW, height: totalH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "SnipClip"
        isReleasedWhenClosed = false
        // Minimum height must fit both the top tool section (~310pt) and bottom action
        // section (~145pt) plus a gap. Below this they'd overlap.
        minSize = NSSize(width: sidebarW + 200, height: 558)

        buildContent(canvasW: canvasW, canvasH: canvasH, totalW: totalW, totalH: totalH)
    }

    // MARK: Layout

    private func buildContent(canvasW: CGFloat, canvasH: CGFloat, totalW: CGFloat, totalH: CGFloat) {
        // Give root the correct frame immediately so contentView assignment doesn't
        // trigger autoresizing from a (0,0) baseline and corrupt subview positions.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: totalH))
        root.autoresizingMask = [.width, .height]

        // Sidebar (NSVisualEffectView)
        let sidebar = buildSidebar(height: totalH)
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarW, height: totalH)
        sidebar.autoresizingMask = [.maxXMargin, .height]

        // Vertical divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.frame = NSRect(x: sidebarW, y: 0, width: 1, height: totalH)
        divider.autoresizingMask = [.maxXMargin, .height]

        // Canvas — fixed to image size, pinned to top of content area.
        // Any extra height (when totalH > canvasH) shows as window background below.
        let canvas = MarkupCanvasView()
        canvas.backgroundImage = sourceImage
        canvas.delegate = self
        canvas.frame = NSRect(x: sidebarW + 1, y: totalH - canvasH, width: canvasW, height: canvasH)
        canvas.autoresizingMask = [.minYMargin]  // stays anchored to top on resize
        canvasView = canvas

        [sidebar, divider, canvas].forEach { root.addSubview($0) }
        contentView = root
    }

    private func buildSidebar(height: CGFloat) -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .sidebar
        bar.blendingMode = .withinWindow
        bar.state = .active

        let cx = (sidebarW - 36) / 2  // centered x for 36pt buttons

        // All positions are computed in AppKit bottom-left coordinates.
        // "from top" = height - topInset - (index+1)*itemStride

        // ── Tool buttons — pinned to TOP (.minYMargin: flexible bottom gap) ─────
        let tools: [(MarkupTool, String, String)] = [
            (.pen,       "pencil.tip",       "Pen"),
            (.arrow,     "arrow.up.right",   "Arrow"),
            (.rect,      "rectangle",        "Rectangle"),
            (.circle,    "circle",           "Circle"),
            (.highlight, "highlighter",      "Highlight"),
            (.text,      "text.cursor",      "Text"),
        ]
        for (i, (tool, sf, tip)) in tools.enumerated() {
            let btn = SidebarIconButton(sfSymbol: sf, tip: tip)
            btn.onAction = { [weak self] in self?.selectTool(tool) }
            // Place from top: first button 10pt from top, then 38pt stride
            let y = height - 10 - 36 - CGFloat(i) * 38
            btn.frame = NSRect(x: cx, y: y, width: 36, height: 36)
            btn.autoresizingMask = [.minYMargin]
            bar.addSubview(btn)
            toolButtons[tool] = btn
        }

        // Separator below tools
        var topCursor = height - 10 - CGFloat(tools.count) * 38 - 8
        let s1 = NSBox(); s1.boxType = .separator
        s1.frame = NSRect(x: 8, y: topCursor, width: sidebarW - 16, height: 1)
        s1.autoresizingMask = [.minYMargin]
        bar.addSubview(s1)
        topCursor -= 9

        // Colour picker
        topCursor -= 36
        let cp = ColorPickerButton(frame: NSRect(x: cx, y: topCursor, width: 36, height: 36))
        cp.color = .systemRed
        cp.autoresizingMask = [.minYMargin]
        cp.onChange = { [weak self] color in self?.canvasView.currentColor = color }
        bar.addSubview(cp)
        colorPicker = cp

        // Separator below colour picker
        topCursor -= 9
        let s2 = NSBox(); s2.boxType = .separator
        s2.frame = NSRect(x: 8, y: topCursor, width: sidebarW - 16, height: 1)
        s2.autoresizingMask = [.minYMargin]
        bar.addSubview(s2)
        topCursor -= 9

        // Undo
        topCursor -= 36
        let undoBtn = SidebarIconButton(sfSymbol: "arrow.uturn.backward", tip: "Undo")
        undoBtn.onAction = { [weak self] in self?.undoManager?.undo() }
        undoBtn.frame = NSRect(x: cx, y: topCursor, width: 36, height: 36)
        undoBtn.autoresizingMask = [.minYMargin]
        bar.addSubview(undoBtn)

        // Redo
        topCursor -= 38
        let redoBtn = SidebarIconButton(sfSymbol: "arrow.uturn.forward", tip: "Redo")
        redoBtn.onAction = { [weak self] in self?.undoManager?.redo() }
        redoBtn.frame = NSRect(x: cx, y: topCursor, width: 36, height: 36)
        redoBtn.autoresizingMask = [.minYMargin]
        bar.addSubview(redoBtn)

        // ── Action buttons — fixed positions from BOTTOM ────────
        func placeBot(_ v: NSView, y: CGFloat) {
            v.frame = NSRect(x: cx, y: y, width: 36, height: 36)
            v.autoresizingMask = []
            bar.addSubview(v)
        }
        func sepBot(y: CGFloat) {
            let s = NSBox(); s.boxType = .separator
            s.frame = NSRect(x: 8, y: y, width: sidebarW - 16, height: 1)
            s.autoresizingMask = []
            bar.addSubview(s)
        }

        let resnipBtn = SidebarIconButton(sfSymbol: "camera.viewfinder", tip: "New Snip")
        resnipBtn.onAction = { [weak self] in self?.resnip() }
        placeBot(resnipBtn, y: 10)

        let saveBtn = SidebarIconButton(sfSymbol: "square.and.arrow.down", tip: "Save…")
        saveBtn.onAction = { [weak self] in self?.saveImage() }
        placeBot(saveBtn, y: 52)

        sepBot(y: 94)

        let copyButton = SidebarIconButton(sfSymbol: "doc.on.doc", tip: "Copy  ⌘C")
        copyButton.onAction = { [weak self] in self?.copyToClipboard() }
        placeBot(copyButton, y: 100)
        self.copyBtn = copyButton

        selectTool(.pen)
        return bar
    }

    // MARK: Tool selection

    private func selectTool(_ tool: MarkupTool) {
        for (t, btn) in toolButtons { btn.isSelected = (t == tool) }
        canvasView?.currentTool = tool
        if tool != .text { canvasView?.commitPendingText() }
    }

    // MARK: Copy

    @objc func copyToClipboard() {
        canvasView.commitPendingText()
        let img = renderFinal()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        copyBtn.showCopyConfirmation()
    }

    // MARK: Save

    @objc private func saveImage() {
        canvasView.commitPendingText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png, UTType.jpeg]
        panel.nameFieldStringValue = "screenshot.png"

        let formatPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 28), pullsDown: false)
        formatPicker.addItems(withTitles: ["PNG", "JPEG"])
        formatPicker.selectItem(at: 0)
        formatPicker.target = self
        formatPicker.tag = 999
        formatPicker.action = #selector(formatChanged(_:))
        panel.accessoryView = formatPicker

        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let img = self.renderFinal()
            guard let tiff = img.tiffRepresentation,
                  let rep  = NSBitmapImageRep(data: tiff) else { return }

            let isJPEG = formatPicker.indexOfSelectedItem == 1
            let data = isJPEG
                ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                : rep.representation(using: .png, properties: [:])
            guard let data else { return }
            do {
                try data.write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let panel = sender.window as? NSSavePanel else { return }
        let name = panel.nameFieldStringValue
        let base = (name as NSString).deletingPathExtension
        if sender.indexOfSelectedItem == 1 {
            panel.nameFieldStringValue = base + ".jpg"
            panel.allowedContentTypes = [UTType.jpeg]
        } else {
            panel.nameFieldStringValue = base + ".png"
            panel.allowedContentTypes = [UTType.png]
        }
    }

    // MARK: Re-snip

    @objc private func resnip() {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            SelectionOverlayController.shared.show()
        }
    }

    // MARK: Render

    private func renderFinal() -> NSImage {
        let imgSize = sourceImage.size
        let canvasSize = canvasView.bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return sourceImage }

        // Resolve pixel dimensions so markup is rendered at the captured
        // resolution rather than at 1× logical points on Retina displays.
        let pixW: Int
        let pixH: Int
        if let rep = sourceImage.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            pixW = rep.pixelsWide; pixH = rep.pixelsHigh
        } else {
            pixW = Int(imgSize.width); pixH = Int(imgSize.height)
        }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixW, pixelsHigh: pixH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return sourceImage }
        bitmapRep.size = imgSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gc = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return sourceImage }
        NSGraphicsContext.current = gc

        let cg = gc.cgContext
        // Flip: origin top-left, y increases downward — matches the canvas view.
        cg.translateBy(x: 0, y: CGFloat(pixH))
        cg.scaleBy(x: 1, y: -1)
        sourceImage.draw(in: NSRect(origin: .zero, size: NSSize(width: CGFloat(pixW), height: CGFloat(pixH))))

        let scaleX = CGFloat(pixW) / canvasSize.width
        let scaleY = CGFloat(pixH) / canvasSize.height
        cg.scaleBy(x: scaleX, y: scaleY)
        for item in canvasView.items { item.draw() }

        let result = NSImage(size: imgSize)
        result.addRepresentation(bitmapRep)
        return result
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - MarkupCanvasDelegate

extension MarkupEditorWindow: MarkupCanvasDelegate {
    // Clipboard is written only on explicit copyToClipboard() or initial capture —
    // not on every stroke, to avoid silently clobbering the user's clipboard.
    func canvasDidChange() {}
}
