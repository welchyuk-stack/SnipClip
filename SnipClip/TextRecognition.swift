import AppKit
import Vision

/// On-device text recognition (Apple Vision). Nothing leaves the Mac.
enum TextRecognition {
    /// Recognises text in reading order and returns it joined by newlines,
    /// or nil if nothing was found. Calls back on the main queue.
    static func recognize(in image: CGImage, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
        }
    }

    /// Recognises text and copies it to the clipboard, with a short toast
    /// confirming the result.
    static func copyText(from image: NSImage, showToast: Bool = true, completion: ((String?) -> Void)? = nil) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("No text found")
            completion?(nil)
            return
        }
        recognize(in: cg) { text in
            guard let text else {
                Toast.show("No text found")
                completion?(nil)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let lines = text.split(separator: "\n").count
            if showToast { Toast.show(lines == 1 ? "Copied text" : "Copied \(lines) lines of text") }
            completion?(text)
        }
    }
}

/// A small transient HUD near the top of the screen under the mouse.
enum Toast {
    private static var window: NSPanel?

    static func show(_ message: String) {
        window?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 36)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: 16, y: (size.height - label.frame.height) / 2)
        bg.addSubview(label)
        panel.contentView = bg

        let vf = ScreenCapture.screenUnderMouse().visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 24))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        window = panel
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard window === panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
                if window === panel { window = nil }
            }
        }
    }
}
