import AppKit
import Carbon.HIToolbox

// MARK: - Controller

final class PreferencesController: NSObject, NSWindowDelegate {
    static let shared = PreferencesController()
    private var window: PreferencesWindow?

    private override init() { super.init() }

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = PreferencesWindow()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Window

final class PreferencesWindow: NSWindow {
    private var recorder: ShortcutRecorderView!
    private var folderLabel: NSTextField!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "SnipClip Preferences"
        isReleasedWhenClosed = false
        center()
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
        contentView = root

        let label = NSTextField(labelWithString: "Capture shortcut")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: 24, y: 248, width: 200, height: 20)
        root.addSubview(label)

        let hint = NSTextField(wrappingLabelWithString:
            "Click the box, then press a new key combination. Choose something unlikely to clash with other apps' shortcuts.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 196, width: 292, height: 40)
        root.addSubview(hint)

        let rec = ShortcutRecorderView(frame: NSRect(x: 24, y: 160, width: 160, height: 28))
        rec.onChange = { [weak self] keyCode, modifiers in
            HotkeyManager.shared.update(keyCode: keyCode, modifiers: modifiers)
            self?.recorder.refresh()
            NotificationCenter.default.post(name: .snipShortcutChanged, object: nil)
        }
        root.addSubview(rec)
        recorder = rec

        let resetBtn = NSButton(title: "Reset to ⌘⇧S", target: self, action: #selector(resetTapped))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: 196, y: 158, width: 120, height: 28)
        root.addSubview(resetBtn)

        let sep = NSBox(frame: NSRect(x: 24, y: 144, width: 292, height: 1))
        sep.boxType = .separator
        root.addSubview(sep)

        let folderTitle = NSTextField(labelWithString: "Recordings folder")
        folderTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        folderTitle.frame = NSRect(x: 24, y: 112, width: 200, height: 20)
        root.addSubview(folderTitle)

        let path = NSTextField(labelWithString: RecordingFolderManager.shared.displayPath)
        path.font = NSFont.systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.frame = NSRect(x: 24, y: 90, width: 292, height: 16)
        root.addSubview(path)
        folderLabel = path

        let chooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseFolderTapped))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.frame = NSRect(x: 24, y: 56, width: 100, height: 28)
        root.addSubview(chooseBtn)

        let footer = NSTextField(labelWithString: "SnipClip v1.3.1")
        footer.font = NSFont.systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.frame = NSRect(x: 24, y: 16, width: 200, height: 16)
        root.addSubview(footer)
    }

    @objc private func resetTapped() {
        HotkeyManager.shared.resetToDefault()
        recorder.refresh()
        NotificationCenter.default.post(name: .snipShortcutChanged, object: nil)
    }

    @objc private func chooseFolderTapped() {
        RecordingFolderManager.shared.choose { [weak self] url in
            guard url != nil else { return }
            self?.folderLabel.stringValue = RecordingFolderManager.shared.displayPath
        }
    }

    override var canBecomeKey: Bool { true }
}

extension Notification.Name {
    static let snipShortcutChanged = Notification.Name("snipShortcutChanged")
}

// MARK: - Shortcut recorder control

/// A click-to-record shortcut field. Click it, then press any key combo
/// (with at least one modifier) to set it as SnipClip's capture shortcut.
final class ShortcutRecorderView: NSView {
    var onChange: ((_ keyCode: UInt32, _ modifiers: UInt32) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(startRecording))
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() { needsDisplay = true }

    @objc private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor = isRecording ? .controlAccentColor.withAlphaComponent(0.15) : .controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.fill()

        let border: NSColor = isRecording ? .controlAccentColor : .separatorColor
        border.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording ? "Press a key combination…" : HotkeyManager.shared.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        // Require at least one modifier so a plain letter key doesn't become
        // a global shortcut that fires while typing anywhere else.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty, event.keyCode != 53 /* Escape cancels */ else {
            isRecording = false
            return
        }

        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbonMods |= UInt32(shiftKey) }

        isRecording = false
        onChange?(UInt32(event.keyCode), carbonMods)
    }

    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }
}
