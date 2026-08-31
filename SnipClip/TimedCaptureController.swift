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
        let win = CountdownHUDWindow(screen: screen, destination: destination, totalSeconds: delay)
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
    private let ring = CountdownRingView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))

    init(screen: NSScreen, destination: URL, totalSeconds: Int) {
        let size = NSSize(width: 260, height: 250)
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
        ring.drain(over: TimeInterval(totalSeconds))

        // Gentle pop-in rather than appearing abruptly.
        alphaValue = 0
        setFrame(frame.insetBy(dx: 6, dy: 6), display: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(NSRect(origin: origin, size: size), display: true)
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

        let title = NSTextField(labelWithString: "Full-Screen Capture")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: size.height - 40, width: size.width, height: 18)
        blur.addSubview(title)

        ring.frame = NSRect(x: (size.width - 120) / 2, y: 70, width: 120, height: 120)
        blur.addSubview(ring)

        let destLine = NSTextField(labelWithString: destination.lastPathComponent)
        destLine.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        destLine.textColor = .secondaryLabelColor
        destLine.alignment = .center
        destLine.lineBreakMode = .byTruncatingMiddle
        destLine.frame = NSRect(x: 16, y: 42, width: size.width - 32, height: 16)
        blur.addSubview(destLine)

        let hint = NSTextField(labelWithString: "Press Esc to Cancel")
        hint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 18, width: size.width, height: 14)
        blur.addSubview(hint)
    }

    func updateCount(_ n: Int) {
        ring.setNumber(n)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
        else { super.keyDown(with: event) }
    }

    override var canBecomeKey: Bool { true }
}

/// A circular progress ring that drains smoothly over the countdown's full
/// duration, with the current whole-second count in bold in the center.
private final class CountdownRingView: NSView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let numberLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpLayers()
        setUpLabel()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setUpLayers() {
        let lineWidth: CGFloat = 7
        let path = CGPath(
            ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            transform: nil
        )

        trackLayer.path = path
        trackLayer.fillColor = NSColor.clear.cgColor
        trackLayer.strokeColor = NSColor(calibratedWhite: 0.5, alpha: 0.2).cgColor
        trackLayer.lineWidth = lineWidth
        layer?.addSublayer(trackLayer)

        progressLayer.path = path
        progressLayer.fillColor = NSColor.clear.cgColor
        progressLayer.strokeColor = NSColor.controlAccentColor.cgColor
        progressLayer.lineWidth = lineWidth
        progressLayer.lineCap = .round
        // Start at 12 o'clock and drain clockwise.
        progressLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        progressLayer.strokeEnd = 1
        layer?.addSublayer(progressLayer)
    }

    private func setUpLabel() {
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        numberLabel.textColor = .labelColor
        numberLabel.alignment = .center
        numberLabel.frame = bounds
        addSubview(numberLabel)
    }

    func drain(over seconds: TimeInterval) {
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 1
        anim.toValue = 0
        anim.duration = seconds
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        progressLayer.add(anim, forKey: "drain")
    }

    func setNumber(_ n: Int) {
        numberLabel.stringValue = n > 0 ? "\(n)" : "📸"
    }
}
