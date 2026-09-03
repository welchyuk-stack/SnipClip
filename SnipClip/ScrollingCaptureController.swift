import AppKit

/// Basic scrolling capture: pick a region the same way as a normal capture,
/// then manually scroll the content underneath while SnipClip keeps grabbing
/// frames of that region and stitching the newly revealed rows onto the
/// bottom of a growing image. Detection is a lightweight 1D row-signature
/// slide match, not pixel-perfect alignment — good enough for typical text
/// and web content, not guaranteed for everything (video, animation, blur).
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()
    private init() {}

    private var isActive = false
    private var pickerWindow: SelectionOverlayWindow?
    private var rect: NSRect?
    private var timer: Timer?
    private var hud: ScrollingCaptureHUD?

    private var composite: CGImage?
    private var lastSignature: [Double]?

    private let tickInterval: TimeInterval = 0.35
    private let minShift = 8              // ignore sub-pixel jitter
    private let matchThreshold = 10.0     // avg per-sample byte diff, 0–255 scale
    private let maxCompositeHeight = 12000

    func start() {
        guard !isActive else { return }
        isActive = true
        MarkupEditorController.shared.closeIfOpen()

        let unionRect = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let win = SelectionOverlayWindow(contentRect: unionRect, styleMask: .borderless,
                                         backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: unionRect.size))
        view.onComplete = { [weak self] screenRect in
            self?.pickerWindow?.orderOut(nil)
            self?.pickerWindow = nil
            self?.begin(rect: screenRect)
        }
        view.onCancel = { [weak self] in
            self?.pickerWindow?.orderOut(nil)
            self?.pickerWindow = nil
            self?.isActive = false
        }

        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pickerWindow = win
    }

    private func begin(rect: NSRect) {
        // Brief pause so the picker overlay is fully gone before we grab pixels.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            guard let first = self.captureCGImage(rect: rect) else {
                self.isActive = false
                return
            }
            self.rect = rect
            self.composite = first
            self.lastSignature = ScrollingCaptureController.rowSignature(of: first)

            let h = ScrollingCaptureHUD(anchorScreen: ScrollingCaptureController.screen(for: rect))
            h.onStop = { [weak self] in self?.finish() }
            h.onCancel = { [weak self] in self?.cancel() }
            h.orderFrontRegardless()
            self.hud = h

            let t = Timer(timeInterval: self.tickInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    private func tick() {
        guard let rect, let lastSignature,
              let newFrame = captureCGImage(rect: rect) else { return }
        guard let newSignature = ScrollingCaptureController.rowSignature(of: newFrame),
              newSignature.count == lastSignature.count, newSignature.count > 40 else { return }

        let height = newSignature.count
        let minOverlap = max(40, height / 3)
        var bestShift = 0
        var bestError = Double.greatestFiniteMagnitude

        var s = minShift
        while s <= height - minOverlap {
            let compareCount = height - s
            var total = 0.0
            var i = 0
            while i < compareCount {
                total += abs(newSignature[i] - lastSignature[s + i])
                i += 1
            }
            let avg = total / Double(compareCount)
            if avg < bestError {
                bestError = avg
                bestShift = s
            }
            s += 1
        }

        guard bestError < matchThreshold, bestShift > 0 else {
            // No confident scroll detected this tick — just refresh the
            // reference frame so drift doesn't accumulate.
            self.lastSignature = newSignature
            return
        }

        if let slice = newFrame.cropping(to: CGRect(x: 0, y: newFrame.height - bestShift,
                                                     width: newFrame.width, height: bestShift)),
           let composite,
           let merged = ScrollingCaptureController.appendVertically(top: composite, bottom: slice),
           merged.height <= maxCompositeHeight {
            self.composite = merged
            hud?.updateHeight(merged.height)
        } else if let composite, composite.height > maxCompositeHeight {
            // Hit the cap — stop automatically rather than growing forever.
            finish()
            return
        }

        self.lastSignature = newSignature
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        hud?.orderOut(nil); hud = nil

        defer { isActive = false; rect = nil; composite = nil; lastSignature = nil }
        guard let final = composite else { return }
        let image = NSImage(cgImage: final, size: NSSize(width: final.width, height: final.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        CaptureHistory.shared.record(image)
        MarkupEditorController.shared.show(image: image)
    }

    private func cancel() {
        timer?.invalidate(); timer = nil
        hud?.orderOut(nil); hud = nil
        isActive = false
        rect = nil; composite = nil; lastSignature = nil
    }

    private func captureCGImage(rect: NSRect) -> CGImage? {
        guard let image = ScreenCapture.capture(nsScreenRect: rect) else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    private static func screen(for rect: NSRect) -> NSScreen {
        NSScreen.screens.max { NSIntersectionRect($0.frame, rect).area < NSIntersectionRect($1.frame, rect).area }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// A coarse per-row brightness signature (subsampled columns, single
    /// channel) — cheap enough to run every tick, precise enough to find a
    /// scroll offset by sliding one signature against another.
    private static func rowSignature(of image: CGImage) -> [Double]? {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let stride = max(1, width / 200)
        let dataLength = CFDataGetLength(data)

        var sig = [Double](repeating: 0, count: height)
        var sampleCount = 0
        for y in 0..<height {
            var sum = 0
            var x = 0
            let rowBase = y * bytesPerRow
            while x < width {
                let offset = rowBase + x * bytesPerPixel
                if offset < dataLength { sum += Int(ptr[offset]) }
                x += stride
            }
            if y == 0 { sampleCount = max(1, (width + stride - 1) / stride) }
            sig[y] = Double(sum) / Double(sampleCount)
        }
        return sig
    }

    /// Stacks `top` above `bottom` into one taller image.
    private static func appendVertically(top: CGImage, bottom: CGImage) -> CGImage? {
        let width = max(top.width, bottom.width)
        let totalHeight = top.height + bottom.height
        guard let ctx = CGContext(data: nil, width: width, height: totalHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(bottom.height)))
        ctx.draw(top, in: CGRect(x: 0, y: CGFloat(bottom.height), width: CGFloat(width), height: CGFloat(top.height)))
        return ctx.makeImage()
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

// MARK: - HUD

private final class ScrollingCaptureHUD: NSPanel {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    private let heightLabel = NSTextField(labelWithString: "")

    init(anchorScreen: NSScreen) {
        let size = NSSize(width: 280, height: 90)
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        let origin = NSPoint(
            x: anchorScreen.frame.midX - size.width / 2,
            y: anchorScreen.frame.maxY - size.height - 44
        )
        setFrameOrigin(origin)
        buildUI(size: size)
    }

    private func buildUI(size: NSSize) {
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        contentView = blur

        let title = NSTextField(labelWithString: "Scrolling Capture")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: size.height - 30, width: size.width, height: 18)
        blur.addSubview(title)

        heightLabel.font = NSFont.systemFont(ofSize: 11)
        heightLabel.textColor = .secondaryLabelColor
        heightLabel.alignment = .center
        heightLabel.stringValue = "Scroll the content, then click Stop"
        heightLabel.lineBreakMode = .byTruncatingTail
        heightLabel.frame = NSRect(x: 12, y: size.height - 50, width: size.width - 24, height: 16)
        blur.addSubview(heightLabel)

        let stopBtn = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stopBtn.bezelStyle = .rounded
        stopBtn.keyEquivalent = "\r"
        stopBtn.frame = NSRect(x: size.width / 2 - 76, y: 14, width: 72, height: 28)
        blur.addSubview(stopBtn)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: size.width / 2 + 4, y: 14, width: 72, height: 28)
        blur.addSubview(cancelBtn)
    }

    func updateHeight(_ pixels: Int) {
        heightLabel.stringValue = "Captured \(pixels)px tall so far"
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func cancelTapped() { onCancel?() }

    override var canBecomeKey: Bool { false }
}
