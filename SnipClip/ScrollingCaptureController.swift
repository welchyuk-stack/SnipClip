import AppKit

/// Basic scrolling capture: pick a region with the selection overlay, then
/// manually scroll the content underneath while SnipClip keeps grabbing
/// frames of that region every 350ms and stitching newly revealed rows onto
/// the bottom of a growing image.
///
/// Pixel work is done entirely through NSBitmapImageRep rather than raw
/// CGImage/CGContext calls — NSBitmapImageRep's bitmapData is documented to
/// always be top-down (row 0 = top of the image), which sidesteps the
/// top-vs-bottom-origin ambiguity that CGImage.cropping(to:) and a raw
/// CGContext's drawing coordinate space otherwise carry. Composite growth is
/// just concatenating raw row bytes onto the end of a buffer, not a redraw.
// Main-thread only; the Sendable conformance lets it be referenced from
// @Sendable timer and Task closures that always hop back to main.
final class ScrollingCaptureController: @unchecked Sendable {
    static let shared = ScrollingCaptureController()
    private init() {}

    private var isActive = false
    private var captureRect: NSRect?
    private var captureScreen: NSScreen?
    private var capturer: DisplayCapturer?
    private var timer: Timer?
    private var hud: ScrollingCaptureHUD?
    private var border: NSWindow?
    private var tickInFlight = false
    private var finished = false

    // Composite state: a flat top-down RGBA8 buffer that only ever grows by
    // appending newly-revealed rows to the end.
    private var compositeBuffer: [UInt8] = []
    private var compositeWidth = 0
    private var compositeHeight = 0
    private var bytesPerRow = 0
    private var pixelScale: CGFloat = 1

    private var lastSignature: [Double]?

    private let tickInterval: TimeInterval = 0.35
    private let minShift = 6              // ignore sub-pixel jitter
    private let matchThreshold = 6.0      // avg per-sample byte diff, 0–255 scale
    private let maxCompositeHeight = 12000

    func start() {
        guard !isActive else { return }
        isActive = true
        MarkupEditorController.shared.closeIfOpen()

        SelectionOverlayController.shared.begin(purpose: .scrolling) { [weak self] selection in
            guard let self else { return }
            guard let selection else { self.isActive = false; return }
            self.begin(rect: selection.rect, screen: selection.screen)
        }
    }

    private func begin(rect: NSRect, screen: NSScreen) {
        captureRect = rect
        captureScreen = screen
        finished = false

        // HUD + border go up first so the capturer can exclude them.
        let h = ScrollingCaptureHUD()
        h.onStop = { [weak self] in self?.finish() }
        h.onCancel = { [weak self] in self?.cancel() }
        h.setFrameOrigin(Self.hudOrigin(size: h.frame.size, rect: rect, screen: screen))
        h.orderFrontRegardless()
        h.makeKey()
        hud = h

        let b = Self.makeBorderWindow(around: rect)
        b.orderFrontRegardless()
        border = b

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Let the window server learn about the HUD/border before we
            // snapshot the shareable window list.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard self.isActive else { return }
            guard let capturer = await DisplayCapturer.make(for: screen, excludingOwnWindows: true),
                  let rep = await self.captureFrame(capturer: capturer, rect: rect, screen: screen),
                  let data = rep.bitmapData else {
                self.teardownUI()
                self.resetState()
                AppAlert.show(title: "Scrolling Capture Failed",
                              message: "SnipClip couldn't capture the selected area. Please check Screen Recording permission in System Settings › Privacy & Security.")
                return
            }
            guard self.isActive else { return }

            self.capturer = capturer
            self.pixelScale = rect.width > 0 ? CGFloat(rep.pixelsWide) / rect.width : 1
            self.compositeWidth = rep.pixelsWide
            self.compositeHeight = rep.pixelsHigh
            self.bytesPerRow = rep.bytesPerRow
            self.compositeBuffer = Array(UnsafeBufferPointer(start: data, count: self.bytesPerRow * self.compositeHeight))
            self.lastSignature = ScrollingCaptureController.rowSignature(rep: rep)

            // Scheduled on the main run loop, so the block always runs on main.
            let t = Timer(timeInterval: self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    @MainActor private func captureFrame(capturer: DisplayCapturer, rect: NSRect, screen: NSScreen) async -> NSBitmapImageRep? {
        guard let full = await capturer.capture(),
              let cropped = ScreenCapture.crop(full, screen: screen, rect: rect) else { return nil }
        return ScrollingCaptureController.normalizedBitmap(from: cropped)
    }

    private func tick() {
        guard !tickInFlight, !finished, let rect = captureRect, let screen = captureScreen,
              let capturer else { return }
        tickInFlight = true
        Task { @MainActor in
            let rep = await self.captureFrame(capturer: capturer, rect: rect, screen: screen)
            self.tickInFlight = false
            guard self.isActive, !self.finished, let rep else { return }
            self.process(rep: rep)
        }
    }

    private func process(rep: NSBitmapImageRep) {
        guard let lastSignature, let data = rep.bitmapData,
              rep.pixelsWide == compositeWidth, rep.bytesPerRow == bytesPerRow else { return }

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
            // No confident scroll detected this tick — refresh the reference
            // frame so drift doesn't accumulate against a stale comparison.
            self.lastSignature = newSignature
            return
        }

        // Rows are top-down: the newly revealed content is the BOTTOM
        // `bestShift` rows of the new frame — i.e. the highest row indices.
        let remaining = maxCompositeHeight - compositeHeight
        let rowsToAppend = min(bestShift, remaining)
        let hitLimit = bestShift >= remaining

        if rowsToAppend > 0 {
            let sliceStart = (height - bestShift) * rep.bytesPerRow
            let sliceLength = rowsToAppend * rep.bytesPerRow
            let slice = UnsafeBufferPointer(start: data + sliceStart, count: sliceLength)
            compositeBuffer.append(contentsOf: slice)
            compositeHeight += rowsToAppend
            hud?.updateHeight(compositeHeight)
        }
        self.lastSignature = newSignature

        if hitLimit {
            hud?.setStatus("Maximum height reached")
            finish()
        }
    }

    private func finish() {
        guard isActive, !finished else { return }
        finished = true
        teardownUI()

        defer { resetState() }
        let pointSize = NSSize(width: CGFloat(compositeWidth) / pixelScale,
                               height: CGFloat(compositeHeight) / pixelScale)
        guard compositeHeight > 0, compositeWidth > 0,
              let image = ScrollingCaptureController.makeImage(
                buffer: compositeBuffer, width: compositeWidth,
                height: compositeHeight, bytesPerRow: bytesPerRow,
                pointSize: pointSize)
        else { return }

        CaptureDelivery.deliver(image)
    }

    private func cancel() {
        teardownUI()
        resetState()
    }

    private func teardownUI() {
        timer?.invalidate(); timer = nil
        hud?.orderOut(nil); hud = nil
        border?.orderOut(nil); border = nil
    }

    private func resetState() {
        isActive = false
        finished = false
        tickInFlight = false
        captureRect = nil
        captureScreen = nil
        capturer = nil
        compositeBuffer = []
        compositeWidth = 0
        compositeHeight = 0
        bytesPerRow = 0
        pixelScale = 1
        lastSignature = nil
    }

    /// Above the rect if it fits in the visible frame, else below, else the
    /// top-right corner of the screen.
    private static func hudOrigin(size: NSSize, rect: NSRect, screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        let gap: CGFloat = 12
        let x = max(vf.minX + 8, min(rect.midX - size.width / 2, vf.maxX - size.width - 8))
        if rect.maxY + gap + size.height <= vf.maxY {
            return NSPoint(x: x, y: rect.maxY + gap)
        }
        if rect.minY - gap - size.height >= vf.minY {
            return NSPoint(x: x, y: rect.minY - gap - size.height)
        }
        return NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16)
    }

    private static func makeBorderWindow(around rect: NSRect) -> NSWindow {
        let pad: CGFloat = 3
        let frame = rect.insetBy(dx: -pad, dy: -pad)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = DashedBorderView(frame: NSRect(origin: .zero, size: frame.size))
        return win
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

    private static func makeImage(buffer: [UInt8], width: Int, height: Int, bytesPerRow: Int, pointSize: NSSize) -> NSImage? {
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

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }
}


// MARK: - Border

private final class DashedBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

// MARK: - HUD

private final class ScrollingCaptureHUD: NSPanel {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    private let heightLabel = NSTextField(labelWithString: "")

    init() {
        let size = NSSize(width: 280, height: 96)
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
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
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
        heightLabel.stringValue = "Scroll slowly, then press Stop"
        heightLabel.lineBreakMode = .byTruncatingTail
        heightLabel.frame = NSRect(x: 12, y: size.height - 50, width: size.width - 24, height: 16)
        blur.addSubview(heightLabel)

        let stopBtn = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stopBtn.bezelStyle = .rounded
        stopBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded
        for b in [stopBtn, cancelBtn] {
            b.font = NSFont.systemFont(ofSize: 13)
            b.sizeToFit()
            b.frame.size.width += 20
        }
        let gap: CGFloat = 8
        let total = stopBtn.frame.width + cancelBtn.frame.width + gap
        cancelBtn.frame.origin = NSPoint(x: (size.width - total) / 2, y: 14)
        stopBtn.frame.origin = NSPoint(x: cancelBtn.frame.maxX + gap, y: 14)
        blur.addSubview(stopBtn)
        blur.addSubview(cancelBtn)
    }

    func updateHeight(_ pixels: Int) {
        heightLabel.stringValue = "Captured \(pixels)px tall so far"
    }

    func setStatus(_ text: String) {
        heightLabel.stringValue = text
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func cancelTapped() { onCancel?() }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onStop?()      // Return / Enter
        case 53: onCancel?()        // Esc
        default: super.keyDown(with: event)
        }
    }

    override var canBecomeKey: Bool { true }
}
