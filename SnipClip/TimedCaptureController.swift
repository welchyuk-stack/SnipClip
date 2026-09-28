import AppKit

/// Full-screen capture on a countdown. Shows a small non-activating HUD on
/// the screen under the pointer (so the user's own app stays frontmost while
/// they set up the shot), then captures that screen and delivers it.
final class TimedCaptureController {
    static let shared = TimedCaptureController()

    private var hud: CountdownHUDPanel?
    private var timer: Timer?
    private var isArmed = false

    private init() {}

    /// - Parameter delay: whole seconds to count down from.
    func start(delay: Int) {
        guard !isArmed else { return }
        isArmed = true

        let screen = ScreenCapture.screenUnderMouse()
        let panel = CountdownHUDPanel(screen: screen)
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.updateCount(max(1, delay))
        panel.orderFrontRegardless()
        panel.makeKey()
        hud = panel

        var remaining = max(1, delay)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] tick in
            guard let self else { tick.invalidate(); return }
            remaining -= 1
            if remaining <= 0 {
                tick.invalidate()
                self.timer = nil
                self.fire(on: screen)
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

    private func fire(on screen: NSScreen) {
        hud?.orderOut(nil)
        hud = nil

        Task { @MainActor in
            defer { self.isArmed = false }
            if #unavailable(macOS 14.0) {
                // The fallback path can't exclude our windows; let the HUD vanish.
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard let capturer = await DisplayCapturer.make(for: screen, excludingOwnWindows: true),
                  let cg = await capturer.capture() else {
                AppAlert.show(title: "Timed Capture Failed",
                              message: "SnipClip couldn't capture the screen. Check that Screen Recording permission is enabled in System Settings › Privacy & Security.")
                return
            }
            CaptureDelivery.deliver(ScreenCapture.image(from: cg, pointSize: screen.frame.size))
        }
    }
}

// MARK: - Countdown HUD

private final class CountdownHUDPanel: NSPanel {
    var onCancel: (() -> Void)?
    private let numberLabel = NSTextField(labelWithString: "")

    init(screen: NSScreen) {
        let size = NSSize(width: 240, height: 200)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.midY - size.height / 2))
        buildUI(size: size)

        // Alpha-only fade-in (animating the frame here trips layout recursion).
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func buildUI(size: NSSize) {
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
        title.alignment = .center
        title.frame = NSRect(x: 0, y: size.height - 22 - 18, width: size.width, height: 18)
        blur.addSubview(title)

        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 52, weight: .bold)
        numberLabel.alignment = .center
        numberLabel.frame = NSRect(x: 0, y: title.frame.minY - 8 - 64, width: size.width, height: 64)
        blur.addSubview(numberLabel)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.font = NSFont.systemFont(ofSize: 13)
        cancel.sizeToFit()
        var f = cancel.frame
        f.size.width += 20
        f.origin = NSPoint(x: (size.width - f.width) / 2, y: 38)
        cancel.frame = f
        blur.addSubview(cancel)

        let hint = NSTextField(labelWithString: "Press Esc to cancel")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 14, width: size.width, height: 16)
        blur.addSubview(hint)
    }

    func updateCount(_ n: Int) {
        numberLabel.stringValue = "\(n)"
    }

    @objc private func cancelTapped() { onCancel?() }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override var canBecomeKey: Bool { true }
}
