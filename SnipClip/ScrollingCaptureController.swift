import AppKit

/// Basic scrolling capture: pick a region the same way as a normal capture,
/// then manually scroll the content underneath while SnipClip keeps grabbing
/// frames of that region every 350ms and stitching newly revealed rows onto
/// the bottom of a growing image.
///
/// Pixel work is done entirely through NSBitmapImageRep rather than raw
/// CGImage/CGContext calls — NSBitmapImageRep's bitmapData is documented to
/// always be top-down (row 0 = top of the image), which sidesteps the
/// top-vs-bottom-origin ambiguity that CGImage.cropping(to:) and a raw
/// CGContext's drawing coordinate space otherwise carry. Composite growth is
/// just concatenating raw row bytes onto the end of a buffer, not a redraw.
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()
    private init() {}

    private var isActive = false
    private var pickerWindow: SelectionOverlayWindow?
    private var captureRect: NSRect?
    private var timer: Timer?
    private var hud: ScrollingCaptureHUD?

    // Composite state: a flat top-down RGBA8 buffer that only ever grows by
    // appending newly-revealed rows to the end.
    private var compositeBuffer: [UInt8] = []
    private var compositeWidth = 0
    private var compositeHeight = 0
    private var bytesPerRow = 0

    private var lastSignature: [Double]?

    private let tickInterval: TimeInterval = 0.35
    private let minShift = 6              // ignore sub-pixel jitter
    private let matchThreshold = 6.0      // avg per-sample byte diff, 0–255 scale
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
            guard let cgImage = self.captureCGImage(rect: rect),
                  let rep = ScrollingCaptureController.normalizedBitmap(from: cgImage),
                  let data = rep.bitmapData else {
                self.isActive = false
                return
            }

            self.captureRect = rect
            self.compositeWidth = rep.pixelsWide
            self.compositeHeight = rep.pixelsHigh
            self.bytesPerRow = rep.bytesPerRow
            self.compositeBuffer = Array(UnsafeBufferPointer(start: data, count: self.bytesPerRow * self.compositeHeight))
            self.lastSignature = ScrollingCaptureController.rowSignature(rep: rep)

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
        guard let rect = captureRect, let lastSignature,
              let cgImage = captureCGImage(rect: rect),
              let rep = ScrollingCaptureController.normalizedBitmap(from: cgImage),
              let data = rep.bitmapData else { return }

        let height = rep.pixelsHigh
        guard let newSignature = ScrollingCaptureController.rowSignature(rep: rep),
              newSignature.count == lastSignature.count, height > 40 else { return }

        let minOverlap = max(40, height / 3)
        var bestShift = 0
        var bestError = Double.greatestFiniteMagnitude

        var s = minShift
        while s <= height - minOverlap {
            let compareCount = height - s
            var total = 0.0
            var i = 0
            while i < compareCount {
                // newFrame row i shows the same content as lastFrame row
                // (i + s) once the view has scrolled down by s rows.
                total += abs(newSignature[i] - lastSignature[i + s])
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
            // No confident scroll detected this tick (or scrolled too far to
            // find any overlap) — just refresh the reference frame so drift
            // doesn't accumulate against a stale comparison point.
            self.lastSignature = newSignature
            return
        }

        // Rows are top-down: the newly revealed content is the BOTTOM
        // `bestShift` rows of the new frame — i.e. the highest row indices.
        let sliceStart = (height - bestShift) * rep.bytesPerRow
        let sliceLength = bestShift * rep.bytesPerRow
        guard sliceStart >= 0, sliceLength > 0,
              compositeHeight + bestShift <= maxCompositeHeight else {
            if compositeHeight >= maxCompositeHeight { finish() }
            return
        }

        let slice = UnsafeBufferPointer(start: data + sliceStart, count: sliceLength)
        compositeBuffer.append(contentsOf: slice)
        compositeHeight += bestShift
        hud?.updateHeight(compositeHeight)

        self.lastSignature = newSignature
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        hud?.orderOut(nil); hud = nil

        defer { resetState() }
        guard compositeHeight > 0, compositeWidth > 0,
              let image = ScrollingCaptureController.makeImage(
                buffer: compositeBuffer, width: compositeWidth,
                height: compositeHeight, bytesPerRow: bytesPerRow)
        else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        CaptureHistory.shared.record(image)
        MarkupEditorController.shared.show(image: image)
    }

    private func cancel() {
        timer?.invalidate(); timer = nil
        hud?.orderOut(nil); hud = nil
        resetState()
    }

    private func resetState() {
        isActive = false
        captureRect = nil
        compositeBuffer = []
        compositeWidth = 0
        compositeHeight = 0
        bytesPerRow = 0
        lastSignature = nil
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

    // MARK: - Pixel helpers

    /// Redraws a CGImage into a known, fixed 8-bit RGBA NSBitmapImageRep, so
    /// every frame we handle has an identical, predictable byte layout
    /// regardless of the source image's own format.
    private static func normalizedBitmap(from cgImage: CGImage) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: cgImage.width, pixelsHigh: cgImage.height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return rep
    }

    /// A coarse per-row brightness signature (subsampled columns, single
    /// channel) — cheap enough to run every tick, precise enough to find a
    /// scroll offset by sliding one signature against another. Row 0 is the
    /// top of the image (NSBitmapImageRep's guaranteed row order).
    private static func rowSignature(rep: NSBitmapImageRep) -> [Double]? {
        guard let data = rep.bitmapData else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = rep.bytesPerRow
        let bytesPerPixel = 4
        let stride = max(1, width / 200)

        var sig = [Double](repeating: 0, count: height)
        let sampleCount = max(1, (width + stride - 1) / stride)
        for y in 0..<height {
            var sum = 0
            var x = 0
            let rowBase = y * bytesPerRow
            while x < width {
                sum += Int(data[rowBase + x * bytesPerPixel])
                x += stride
            }
            sig[y] = Double(sum) / Double(sampleCount)
        }
        return sig
    }

    private static func makeImage(buffer: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: bytesPerRow, bitsPerPixel: 32
        ), let dest = rep.bitmapData else { return nil }

        buffer.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dest.update(from: base, count: min(buffer.count, bytesPerRow * height))
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
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
