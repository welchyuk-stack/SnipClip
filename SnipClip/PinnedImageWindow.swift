import AppKit

/// Floating, always-on-top copies of a screenshot. Drag to move, resize from
/// any edge (aspect ratio kept), scroll to change opacity, Esc or
/// double-click to close, right-click for more.
final class PinController: NSObject, NSWindowDelegate {
    static let shared = PinController()
    private var windows: [PinnedImageWindow] = []

    func pin(_ image: NSImage) {
        let win = PinnedImageWindow(image: image)
        win.delegate = self
        windows.append(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as AnyObject }
    }

    func closeAll() {
        windows.forEach { $0.close() }
    }

    var hasPins: Bool { !windows.isEmpty }
}

final class PinnedImageWindow: NSPanel {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        let screen = ScreenCapture.screenUnderMouse()
        let vf = screen.visibleFrame
        // Start at the capture's point size, scaled down to fit half the screen.
        var size = image.size
        let fit = min(1, (vf.width * 0.5) / max(size.width, 1), (vf.height * 0.5) / max(size.height, 1))
        size = NSSize(width: max(60, size.width * fit), height: max(40, size.height * fit))
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        minSize = NSSize(width: 40, height: 40 * size.height / max(size.width, 1))

        let view = PinnedImageView(frame: NSRect(origin: .zero, size: size), image: image)
        view.autoresizingMask = [.width, .height]
        view.attach(to: self)
        contentView = view
        setAccessibilityTitle("Pinned Screenshot")
        view.toolTip = "Drag to move · scroll to fade · Esc or double-click to close · right-click for more"
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        alphaValue = min(1, max(0.2, alphaValue + delta))
    }

    @objc func copyImage(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Toast.show("Copied")
    }

    @objc func copyText(_ sender: Any?) {
        TextRecognition.copyText(from: image)
    }

    @objc func openInEditor(_ sender: Any?) {
        MarkupEditorController.shared.show(image: image, entry: nil)
        close()
    }

    @objc func actualSize(_ sender: Any?) {
        var f = frame
        let top = f.maxY
        f.size = image.size
        f.origin.y = top - f.height
        setFrame(f, display: true, animate: true)
    }

    @objc func closePin(_ sender: Any?) { close() }
    @objc func closeAllPins(_ sender: Any?) { PinController.shared.closeAll() }
}

private final class PinnedImageView: NSView {
    private let image: NSImage
    private weak var pinWindow: PinnedImageWindow?

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(to w: PinnedImageWindow) { pinWindow = w }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pinWindow?.close(); return }
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let w = pinWindow else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = w
            menu.addItem(item)
        }
        add("Copy Image", #selector(PinnedImageWindow.copyImage(_:)))
        add("Copy Text", #selector(PinnedImageWindow.copyText(_:)))
        add("Open in Editor", #selector(PinnedImageWindow.openInEditor(_:)))
        add("Actual Size", #selector(PinnedImageWindow.actualSize(_:)))
        menu.addItem(.separator())
        add("Close", #selector(PinnedImageWindow.closePin(_:)))
        add("Close All Pins", #selector(PinnedImageWindow.closeAllPins(_:)))
        let hint = NSMenuItem(title: "Scroll to change opacity", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(hint, at: 0)
        return menu
    }
}
