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
                     ?? NSScreen.main ?? NSScreen.screens[0]
        let maxW = screen.visibleFrame.width  * 0.90 - sidebarW
        let maxH = screen.visibleFrame.height * 0.90
        let scale = min(1.0, min(maxW / image.size.width, maxH / image.size.height))
        let canvasW = image.size.width  * scale
        let canvasH = image.size.height * scale
        let totalW = max(canvasW, 200) + sidebarW
        // Window must be at least 480pt tall so sidebar button groups never overlap,
        // but the canvas stays at its natural size — no image stretching.
        let totalH = max(canvasH, 520)

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
        minSize = NSSize(width: sidebarW + 200, height: 520)

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

        // ── Tool buttons — anchored to TOP (autoresizingMask = []) ─────
        // We use [] (no autoresizing) because the root view is already correctly sized
        // before contentView is assigned, so no resize-from-zero will occur.
        let tools: [(MarkupTool, String, String)] = [
            (.pen,       "pencil.tip",       "Pen"),
            (.arrow,     "arrow.up.right",   "Arrow"),
            (.rect,      "rectangle",          "Rectangle"),
            (.rectangle, "circle",            "Circle"),
            (.highlight, "highlighter",      "Highlight"),
            (.text,      "text.cursor",      "Text"),
        ]
        for (i, (tool, sf, tip)) in tools.enumerated() {
            let btn = SidebarIconButton(sfSymbol: sf, tip: tip)
            btn.onAction = { [weak self] in self?.selectTool(tool) }
            // Place from top: first button 10pt from top, then 38pt stride
            let y = height - 10 - 36 - CGFloat(i) * 38
            btn.frame = NSRect(x: cx, y: y, width: 36, height: 36)
            btn.autoresizingMask = []
            bar.addSubview(btn)
            toolButtons[tool] = btn
        }

        // Separator below tools (stride is 38pt per button, 10pt top gap)
        var topCursor = height - 10 - CGFloat(tools.count) * 38 - 8
        let s1 = NSBox(); s1.boxType = .separator
        s1.frame = NSRect(x: 8, y: topCursor, width: sidebarW - 16, height: 1)
        s1.autoresizingMask = []
        bar.addSubview(s1)
        topCursor -= 9

        // Colour picker
        topCursor -= 36
        let cp = ColorPickerButton(frame: NSRect(x: cx, y: topCursor, width: 36, height: 36))
        cp.color = .systemRed
        cp.autoresizingMask = []
        cp.onChange = { [weak self] color in self?.canvasView.currentColor = color }
        bar.addSubview(cp)
        colorPicker = cp

        // Separator below colour picker
        topCursor -= 9
        let s2 = NSBox(); s2.boxType = .separator
        s2.frame = NSRect(x: 8, y: topCursor, width: sidebarW - 16, height: 1)
        s2.autoresizingMask = []
        bar.addSubview(s2)
        topCursor -= 9

        // Undo
        topCursor -= 36
        let undoBtn = SidebarIconButton(sfSymbol: "arrow.uturn.backward", tip: "Undo")
        undoBtn.onAction = { [weak self] in
            guard let self, !self.canvasView.items.isEmpty else { return }
            self.canvasView.items.removeLast()
        }
        undoBtn.frame = NSRect(x: cx, y: topCursor, width: 36, height: 36)
        undoBtn.autoresizingMask = []
        bar.addSubview(undoBtn)

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
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let img = self.renderFinal()
            if let tiff = img.tiffRepresentation,
               let rep  = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
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

        let scaleX = imgSize.width  / canvasSize.width
        let scaleY = imgSize.height / canvasSize.height

        let result = NSImage(size: imgSize)
        result.lockFocusFlipped(true)
        sourceImage.draw(in: NSRect(origin: .zero, size: imgSize))
        NSGraphicsContext.current?.cgContext.scaleBy(x: scaleX, y: scaleY)
        for item in canvasView.items { item.draw() }
        result.unlockFocus()
        return result
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - MarkupCanvasDelegate

extension MarkupEditorWindow: MarkupCanvasDelegate {
    func canvasDidChange() {
        let img = renderFinal()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}
