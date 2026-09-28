import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Controller

final class PreferencesController: NSObject, NSWindowDelegate {
    static let shared = PreferencesController()
    private var window: PreferencesWindow?

    private override init() { super.init() }

    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let w = PreferencesWindow()
        w.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "SnipClip Settings"
        isReleasedWhenClosed = false
        buildUI()
        center()
    }

    private func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    private func buildUI() {
        let capRec = ShortcutRecorderView(slot: .capture)
        let recRec = ShortcutRecorderView(slot: .toggleRecording)
        for r in [capRec, recRec] {
            r.onChange = { NotificationCenter.default.post(name: .snipShortcutChanged, object: nil) }
        }
        captureRecorder = capRec
        recordingRecorder = recRec

        let capReset = NSButton(title: "Reset", target: self, action: #selector(resetCaptureTapped))
        let recReset = NSButton(title: "Reset", target: self, action: #selector(resetRecordingTapped))

        let shortcutGrid = NSGridView(views: [
            [rowLabel("Capture Region:"), capRec, capReset],
            [rowLabel("Screen Recording:"), recRec, recReset],
        ])
        shortcutGrid.rowSpacing = 8
        shortcutGrid.columnSpacing = 8
        shortcutGrid.rowAlignment = .firstBaseline
        shortcutGrid.column(at: 0).xPlacement = .trailing
        for i in 0..<shortcutGrid.numberOfRows { shortcutGrid.row(at: i).yPlacement = .center }

        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut (or focus it and press Space), then type a new key combination including ⌘, ⌥ or ⌃. Press Esc to cancel.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 420

        let copyBox = NSButton(checkboxWithTitle: "Copy new captures to the clipboard",
                               target: self, action: #selector(copyToggled(_:)))
        copyBox.state = AppSettings.copyOnCapture ? .on : .off

        let path = NSTextField(labelWithString: RecordingFolderManager.shared.displayPath)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderLabel = path
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolderTapped))
        let folderRow = NSStackView(views: [NSTextField(labelWithString: "Save to:"), path, choose])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        let audioBox = NSButton(checkboxWithTitle: "Record system audio",
                                target: self, action: #selector(audioToggled(_:)))
        audioBox.state = AppSettings.recordSystemAudio ? .on : .off

        let login = NSButton(checkboxWithTitle: "Launch SnipClip at login",
                             target: self, action: #selector(loginToggled))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginCheckbox = login

        let footer = NSTextField(labelWithString: "SnipClip v\(AppSettings.appVersion)")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor

        let seps = (0..<3).map { _ in separator() }
        let stack = NSStackView(views: [
            header("Shortcuts"), shortcutGrid, hint, seps[0],
            header("Capture"), copyBox, seps[1],
            header("Recording"), folderRow, audioBox, seps[2],
            header("General"), login, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 16, right: 24)
        stack.setCustomSpacing(16, after: login)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in seps + [folderRow as NSView, hint] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        contentView = stack
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

    @objc private func copyToggled(_ sender: NSButton) {
        AppSettings.copyOnCapture = sender.state == .on
    }

    @objc private func audioToggled(_ sender: NSButton) {
        AppSettings.recordSystemAudio = sender.state == .on
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
            loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: self)
        }
    }

    override var canBecomeKey: Bool { true }
}

extension Notification.Name {
    static let snipShortcutChanged = Notification.Name("snipShortcutChanged")
}

// MARK: - Shortcut recorder control

/// A click- or keyboard-activated shortcut field. While recording, global
/// hotkeys are suspended so the current shortcut can be typed back in.
final class ShortcutRecorderView: NSView {
    var onChange: (() -> Void)?
    private let slot: HotkeyManager.Slot
    private var hint: String?
    private var hintWork: DispatchWorkItem?

    private var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            if isRecording { HotkeyManager.shared.suspend() } else { HotkeyManager.shared.resume() }
            needsDisplay = true
            updateAccessibility()
        }
    }

    init(slot: HotkeyManager.Slot) {
        self.slot = slot
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 26))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 170).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { if isRecording { HotkeyManager.shared.resume() } }

    func refresh() {
        needsDisplay = true
        updateAccessibility()
    }

    private func updateAccessibility() {
        let name = slot == .capture ? "Capture Region shortcut" : "Screen Recording shortcut"
        setAccessibilityLabel(name)
        setAccessibilityValue(isRecording ? "Type shortcut" : HotkeyManager.shared.displayString(for: slot))
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 26) }

    private func startRecording() {
        hint = nil
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { isRecording = false } else { startRecording() }
    }

    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : .controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : .separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        let size: CGFloat
        if let hint {
            text = hint; color = .systemRed; size = 11
        } else if isRecording {
            text = "Type shortcut…"; color = .controlAccentColor; size = 12
        } else {
            text = HotkeyManager.shared.displayString(for: slot); color = .labelColor; size = 13
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color, .paragraphStyle: para,
        ])
        let h = str.size().height
        str.draw(in: NSRect(x: 6, y: (bounds.height - h) / 2, width: bounds.width - 12, height: h))
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    private func showHint(_ text: String) {
        hint = text
        needsDisplay = true
        hintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hint = nil
            self?.needsDisplay = true
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // Space / Return start recording when focused via keyboard.
            if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            return
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbonMods |= UInt32(shiftKey) }

        guard HotkeyManager.isAcceptable(carbonModifiers: carbonMods) else {
            showHint("Include ⌘, ⌥ or ⌃")
            return
        }

        isRecording = false
        if HotkeyManager.shared.update(slot, keyCode: UInt32(event.keyCode), modifiers: carbonMods) {
            refresh()
            onChange?()
        } else if let window {
            let alert = NSAlert()
            alert.messageText = "That shortcut is already in use."
            alert.informativeText = "Choose a different key combination."
            alert.beginSheetModal(for: window)
        }
    }

    // Prevent ⌘-combos from being eaten as menu key equivalents while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }
}
