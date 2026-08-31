import AppKit
import UniformTypeIdentifiers

/// Full-screen capture on a countdown, shown via a small terminal-style HUD.
/// The user picks the delay and a save destination from the menu bar;
/// SnipClip counts down, then captures whichever screen the pointer is on
/// and writes it straight to the chosen file.
final class TimedCaptureController {
    static let shared = TimedCaptureController()

    private var hud: TerminalHUDWindow?
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
        let win = TerminalHUDWindow(screen: screen, destination: destination)
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

// MARK: - Terminal-style HUD

private final class TerminalHUDWindow: NSWindow {
    var onCancel: (() -> Void)?
    private let countLabel = NSTextField(labelWithString: "")

    init(screen: NSScreen, destination: URL) {
        let size = NSSize(width: 400, height: 130)
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
    }

    private func buildUI(size: NSSize, destination: URL) {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        root.layer?.cornerRadius = 10
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        contentView = root

        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let green = NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.45, alpha: 1)

        let promptLine = NSTextField(labelWithString: "$ snipclip --capture --full-screen")
        promptLine.font = mono
        promptLine.textColor = green
        promptLine.frame = NSRect(x: 20, y: 84, width: size.width - 40, height: 20)
        root.addSubview(promptLine)

        countLabel.font = mono
        countLabel.textColor = green
        countLabel.frame = NSRect(x: 20, y: 58, width: size.width - 40, height: 20)
        root.addSubview(countLabel)

        let destLine = NSTextField(labelWithString: "→ \(destination.lastPathComponent)")
        destLine.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        destLine.textColor = NSColor(calibratedWhite: 1, alpha: 0.5)
        destLine.lineBreakMode = .byTruncatingMiddle
        destLine.frame = NSRect(x: 20, y: 34, width: size.width - 40, height: 16)
        root.addSubview(destLine)

        let hint = NSTextField(labelWithString: "press esc to cancel")
        hint.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        hint.textColor = NSColor(calibratedWhite: 1, alpha: 0.35)
        hint.frame = NSRect(x: 20, y: 14, width: size.width - 40, height: 14)
        root.addSubview(hint)
    }

    func updateCount(_ n: Int) {
        countLabel.stringValue = n > 0 ? "> capturing in \(n)…▊" : "> capturing now▊"
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
        else { super.keyDown(with: event) }
    }

    override var canBecomeKey: Bool { true }
}
