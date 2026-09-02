import AppKit
import Carbon.HIToolbox
import ServiceManagement

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
    private var captureRecorder: ShortcutRecorderView!
    private var recordingRecorder: ShortcutRecorderView!
    private var folderLabel: NSTextField!
    private var loginCheckbox: NSButton!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 420))
        contentView = root

        // ── Keyboard shortcuts ──
        let shortcutsTitle = NSTextField(labelWithString: "Keyboard Shortcuts")
        shortcutsTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        shortcutsTitle.frame = NSRect(x: 24, y: 382, width: 300, height: 18)
        root.addSubview(shortcutsTitle)

        let captureLabel = NSTextField(labelWithString: "Capture")
        captureLabel.font = NSFont.systemFont(ofSize: 12)
        captureLabel.frame = NSRect(x: 24, y: 344, width: 70, height: 28)
        captureLabel.alignment = .left
        root.addSubview(captureLabel)

        let capRec = ShortcutRecorderView(frame: NSRect(x: 100, y: 344, width: 120, height: 28), slot: .capture)
        capRec.onChange = { NotificationCenter.default.post(name: .snipShortcutChanged, object: nil) }
        root.addSubview(capRec)
        captureRecorder = capRec

        let captureResetBtn = NSButton(title: "Reset", target: self, action: #selector(resetCaptureTapped))
        captureResetBtn.bezelStyle = .rounded
        captureResetBtn.frame = NSRect(x: 230, y: 344, width: 80, height: 28)
        root.addSubview(captureResetBtn)

        let recordingLabel = NSTextField(labelWithString: "Recording")
        recordingLabel.font = NSFont.systemFont(ofSize: 12)
        recordingLabel.frame = NSRect(x: 24, y: 306, width: 70, height: 28)
        root.addSubview(recordingLabel)

        let recRec = ShortcutRecorderView(frame: NSRect(x: 100, y: 306, width: 120, height: 28), slot: .toggleRecording)
        recRec.onChange = { NotificationCenter.default.post(name: .snipShortcutChanged, object: nil) }
        root.addSubview(recRec)
        recordingRecorder = recRec

        let recordingResetBtn = NSButton(title: "Reset", target: self, action: #selector(resetRecordingTapped))
        recordingResetBtn.bezelStyle = .rounded
        recordingResetBtn.frame = NSRect(x: 230, y: 306, width: 80, height: 28)
        root.addSubview(recordingResetBtn)

        let hint = NSTextField(wrappingLabelWithString:
            "Click a box, then press a new key combination. Choose something unlikely to clash with other apps' shortcuts.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 260, width: 332, height: 32)
        root.addSubview(hint)

        let sep1 = NSBox(frame: NSRect(x: 24, y: 243, width: 332, height: 1))
        sep1.boxType = .separator
        root.addSubview(sep1)

        // ── Recordings folder ──
        let folderTitle = NSTextField(labelWithString: "Recordings Folder")
        folderTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        folderTitle.frame = NSRect(x: 24, y: 211, width: 300, height: 18)
        root.addSubview(folderTitle)

        let path = NSTextField(labelWithString: RecordingFolderManager.shared.displayPath)
        path.font = NSFont.systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.frame = NSRect(x: 24, y: 187, width: 332, height: 16)
        root.addSubview(path)
        folderLabel = path

        let chooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseFolderTapped))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.frame = NSRect(x: 24, y: 149, width: 100, height: 28)
        root.addSubview(chooseBtn)

        let sep2 = NSBox(frame: NSRect(x: 24, y: 132, width: 332, height: 1))
        sep2.boxType = .separator
        root.addSubview(sep2)

        // ── Launch at login ──
        let login = NSButton(checkboxWithTitle: "Launch SnipClip at Login",
                             target: self, action: #selector(loginToggled))
        login.frame = NSRect(x: 24, y: 98, width: 300, height: 20)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        root.addSubview(login)
        loginCheckbox = login

        let footer = NSTextField(labelWithString: "SnipClip v1.3.1")
        footer.font = NSFont.systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.frame = NSRect(x: 24, y: 16, width: 200, height: 16)
        root.addSubview(footer)
    }

    @objc private func resetCaptureTapped() {
        HotkeyManager.shared.resetToDefault(.capture)
        captureRecorder.refresh()
        NotificationCenter.default.post(name: .snipShortcutChanged, object: nil)
    }

    @objc private func resetRecordingTapped() {
        HotkeyManager.shared.resetToDefault(.toggleRecording)
        recordingRecorder.refresh()
        NotificationCenter.default.post(name: .snipShortcutChanged, object: nil)
    }

    @objc private func chooseFolderTapped() {
        RecordingFolderManager.shared.choose { [weak self] url in
            guard url != nil else { return }
            self?.folderLabel.stringValue = RecordingFolderManager.shared.displayPath
        }
    }

    @objc private func loginToggled() {
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the checkbox to match reality and tell the user why.
            loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }

    override var canBecomeKey: Bool { true }
}

extension Notification.Name {
    static let snipShortcutChanged = Notification.Name("snipShortcutChanged")
}

// MARK: - Shortcut recorder control

/// A click-to-record shortcut field. Click it, then press any key combo
/// (with at least one modifier) to set it as the given slot's shortcut.
final class ShortcutRecorderView: NSView {
    var onChange: (() -> Void)?
    private let slot: HotkeyManager.Slot

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, slot: HotkeyManager.Slot) {
        self.slot = slot
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

        let text = isRecording ? "Press a key combination…" : HotkeyManager.shared.displayString(for: slot)
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
        HotkeyManager.shared.update(slot, keyCode: UInt32(event.keyCode), modifiers: carbonMods)
        onChange?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }
}
