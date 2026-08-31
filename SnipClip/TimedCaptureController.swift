import AppKit
import UniformTypeIdentifiers

/// Full-screen capture on a countdown, shown via a small terminal-style HUD.
/// The user picks the delay and a save destination from the menu bar;
/// SnipClip counts down, then captures whichever screen the pointer is on
/// and writes it straight to the chosen file.
final class TimedCaptureController {
    static let shared = TimedCaptureController()

    private var hud: CountdownHUDWindow?
    private var timer: Timer?
    private var isArmed = false

    private init() {}

    /// Prompts for a save destination, then arms the countdown.
    /// - Parameter delay: whole seconds to count down from.
    func start(delay: Int) {
        guard !isArmed else { return }

        let panel = NSSavePanel()
        panel.title = "Save Timed Screenshot"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = TimedCaptureController.defaultFileName()
        panel.canCreateDirectories = true

        let formatPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 28), pullsDown: false)
        formatPicker.addItems(withTitles: ["PNG", "JPEG"])
        formatPicker.target = self
        formatPicker.action = #selector(formatChanged(_:))
        panel.accessoryView = formatPicker

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let isJPEG = formatPicker.indexOfSelectedItem == 1
            self.arm(delay: delay, destination: url, jpeg: isJPEG)
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let panel = sender.window as? NSSavePanel else { return }
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        if sender.indexOfSelectedItem == 1 {
            panel.nameFieldStringValue = base + ".jpg"
            panel.allowedContentTypes = [.jpeg]
        } else {
            panel.nameFieldStringValue = base + ".png"
            panel.allowedContentTypes = [.png]
        }
    }

    private func arm(delay: Int, destination: URL, jpeg: Bool) {
        isArmed = true

        let screen = TimedCaptureController.targetScreen()
        let win = CountdownHUDWindow(screen: screen, destination: destination)
        win.onCancel = { [weak self] in self?.cancel() }
        win.updateCount(delay)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hud = win

        var remaining = delay
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] tick in
            guard let self else { tick.invalidate(); return }
            remaining -= 1
            if remaining <= 0 {
                tick.invalidate()
                self.timer = nil
                self.fire(on: screen, destination: destination, jpeg: jpeg)
            } else {
                self.hud?.updateCount(remaining)
            }
        }
        // .common so the countdown still ticks if a menu or modal loop is running.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cancel() {
        timer?.invalidate()
        timer = nil
        hud?.orderOut(nil)
        hud = nil
        isArmed = false
    }

    private func fire(on screen: NSScreen, destination: URL, jpeg: Bool) {
        hud?.orderOut(nil)
        hud = nil

        // Brief pause so the HUD is fully gone before we grab pixels.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            defer { self?.isArmed = false }
            guard let image = ScreenCapture.capture(nsScreenRect: screen.frame) else { return }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            CaptureHistory.shared.record(image)

            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return }
            let data = jpeg
                ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                : rep.representation(using: .png, properties: [:])
            guard let data else { return }
            do {
                try data.write(to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "SnipClip \(formatter.string(from: Date())).png"
    }

    /// The screen under the pointer right now, falling back to the main screen.
    private static func targetScreen() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

// MARK: - Countdown HUD

private final class CountdownHUDWindow: NSWindow {
    var onCancel: (() -> Void)?
    private let numberLabel = NSTextField(labelWithString: "")

    init(screen: NSScreen, destination: URL) {
        let size = NSSize(width: 240, height: 200)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        setFrameOrigin(origin)

        buildUI(size: size, destination: destination)

        // Gentle fade-in. Deliberately alpha-only — animating the window's
        // own frame right as a layer-backed contentView is installed trips
        // AppKit's layout-recursion guard and can be caught mid-transition.
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func buildUI(size: NSSize, destination: URL) {
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        contentView = blur

        // Fixed vertical rhythm, laid out top-down, so all the pieces stay
        // evenly spaced regardless of card size.
        let topPadding: CGFloat = 22
        let titleHeight: CGFloat = 18
        let gapTitleNumber: CGFloat = 10
        let numberHeight: CGFloat = 64
        let gapNumberDest: CGFloat = 14
        let destHeight: CGFloat = 16
        let gapDestHint: CGFloat = 8
        let hintHeight: CGFloat = 14

        var y = size.height - topPadding - titleHeight

        let title = NSTextField(labelWithString: "Full-Screen Capture")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: y, width: size.width, height: titleHeight)
        blur.addSubview(title)

        y -= gapTitleNumber + numberHeight
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 52, weight: .bold)
        numberLabel.textColor = .labelColor
        numberLabel.alignment = .center
        numberLabel.frame = NSRect(x: 0, y: y, width: size.width, height: numberHeight)
        blur.addSubview(numberLabel)

        y -= gapNumberDest + destHeight
        let destLine = NSTextField(labelWithString: destination.lastPathComponent)
        destLine.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        destLine.textColor = .secondaryLabelColor
        destLine.alignment = .center
        destLine.lineBreakMode = .byTruncatingMiddle
        destLine.frame = NSRect(x: 16, y: y, width: size.width - 32, height: destHeight)
        blur.addSubview(destLine)

        y -= gapDestHint + hintHeight
        let hint = NSTextField(labelWithString: "Press Esc to Cancel")
        hint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: y, width: size.width, height: hintHeight)
        blur.addSubview(hint)
    }

    func updateCount(_ n: Int) {
        numberLabel.stringValue = n > 0 ? "\(n)" : "📸"
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
        else { super.keyDown(with: event) }
    }

    override var canBecomeKey: Bool { true }
}
