import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Screen recording to an .mp4: whole display or a region, optional system audio.
///
/// Threading model:
/// - `state`, `stream`, border window, pending callbacks: MAIN only.
/// - AVAssetWriter, its inputs, `sessionStarted`, `finished`: `writerQueue` only
///   (which is also the SCStreamOutput sample-handler queue).
// State lives on main and the writer is confined to writerQueue, so
// cross-queue references are safe by construction.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    static let shared = ScreenRecorder()

    private enum State { case idle, starting, recording, stopping }

    // MARK: Main-thread state
    private var state: State = .idle
    private var stream: SCStream?
    private var borderWindow: NSWindow?
    private var pendingStopCompletions: [(URL?, Error?) -> Void] = []

    /// true while starting, recording or stopping.
    var isActive: Bool { state != .idle }
    /// true only once frames are being captured.
    var isRecording: Bool { state == .recording }

    /// Called on MAIN if the stream stops on its own or the writer fails mid-recording.
    var onUnexpectedStop: ((URL?, Error) -> Void)?

    // MARK: writerQueue state
    private let writerQueue = DispatchQueue(label: "com.snipclip.mac.recorder.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false
    private var failureReported = false

    private override init() { super.init() }

    enum RecorderError: LocalizedError {
        case busy, noDisplay, noFrames
        var errorDescription: String? {
            switch self {
            case .busy: return "A recording is already starting or in progress."
            case .noDisplay: return "Couldn't find the display to record."
            case .noFrames: return "The recording ended before any video was captured."
            }
        }
    }

    // MARK: - Start

    func start(to url: URL, screen: NSScreen, region: NSRect?, captureAudio: Bool,
               completion: @escaping (Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .idle else { completion(RecorderError.busy); return }
        state = .starting   // set synchronously before any async work

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            state = .idle
            completion(RecorderError.noDisplay)
            return
        }
        let sf = screen.frame
        let scale = screen.backingScaleFactor

        var captureRect = sf
        var sourceRect: CGRect?
        if let region {
            let r = region.intersection(sf).integral
            if !r.isEmpty && r.width >= 2 && r.height >= 2 {
                captureRect = r
                sourceRect = CGRect(x: r.minX - sf.minX, y: sf.maxY - r.maxY,
                                    width: r.width, height: r.height)
                showBorder(around: r)   // before fetching content so it's excluded
            }
        }
        let (width, height) = Self.outputSize(for: captureRect.size, scale: scale)

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw RecorderError.noDisplay
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                if let sourceRect { config.sourceRect = sourceRect }
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.showsCursor = true
                config.pixelFormat = kCVPixelFormatType_32BGRA
                if captureAudio {
                    config.capturesAudio = true
                    config.excludesCurrentProcessAudio = true
                    config.sampleRate = 48000
                    config.channelCount = 2
                }

                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ])
                vInput.expectsMediaDataInRealTime = true
                guard writer.canAdd(vInput) else { throw writer.error ?? RecorderError.noDisplay }
                writer.add(vInput)
                var aInput: AVAssetWriterInput?
                if captureAudio {
                    let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48000,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 128_000,
                    ])
                    a.expectsMediaDataInRealTime = true
                    if writer.canAdd(a) { writer.add(a); aInput = a }
                }
                self.writerQueue.sync {
                    self.writer = writer
                    self.videoInput = vInput
                    self.audioInput = aInput
                    self.sessionStarted = false
                    self.finished = false
                    self.failureReported = false
                }

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.writerQueue)
                if captureAudio {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.writerQueue)
                }
                try await stream.startCapture()

                await MainActor.run {
                    self.stream = stream
                    self.state = .recording
                    completion(nil)
                    if !self.pendingStopCompletions.isEmpty {
                        let pending = self.pendingStopCompletions
                        self.pendingStopCompletions = []
                        self.stopInternal { url, err in pending.forEach { $0(url, err) } }
                    }
                }
            } catch {
                self.writerQueue.sync {
                    if let w = self.writer, w.status == .writing { w.cancelWriting() }
                    self.resetWriterState()
                }
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    self.removeBorder()
                    self.stream = nil
                    self.state = .idle
                    completion(error)
                    let pending = self.pendingStopCompletions
                    self.pendingStopCompletions = []
                    pending.forEach { $0(nil, nil) }
                }
            }
        }
    }

    static func outputSize(for size: CGSize, scale: CGFloat) -> (Int, Int) {
        var w = size.width * scale
        var h = size.height * scale
        let factor = min(1, 4096 / max(w, 1), 2304 / max(h, 1))
        w *= factor; h *= factor
        return (max(2, Int(w) & ~1), max(2, Int(h) & ~1))
    }

    // MARK: - Stop

    func stop(completion: @escaping (URL?, Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch state {
        case .idle:
            completion(nil, nil)
        case .starting:
            pendingStopCompletions.append(completion)
        case .stopping:
            pendingStopCompletions.append(completion)
        case .recording:
            stopInternal(completion: completion)
        }
    }

    /// MAIN. Stops capture, finalises the file, resets to idle, then calls completion on MAIN.
    private func stopInternal(completion: @escaping (URL?, Error?) -> Void) {
        state = .stopping
        let stream = self.stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
            self.writerQueue.async {
                self.finalizeOnWriterQueue { url, err in
                    DispatchQueue.main.async {
                        self.removeBorder()
                        self.state = .idle
                        completion(url, err)
                        let pending = self.pendingStopCompletions
                        self.pendingStopCompletions = []
                        pending.forEach { $0(url, err) }
                    }
                }
            }
        }
    }

    /// writerQueue only. Calls done exactly once (on any queue).
    private func finalizeOnWriterQueue(_ done: @escaping (URL?, Error?) -> Void) {
        finished = true
        guard let writer else { done(nil, RecorderError.noFrames); return }
        let url = writer.outputURL

        guard sessionStarted, writer.status == .writing else {
            let err: Error = (writer.status == .failed ? writer.error : nil) ?? RecorderError.noFrames
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            resetWriterState()
            done(nil, err)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting {
            self.writerQueue.async {
                let ok = writer.status == .completed
                let err = ok ? nil : (writer.error ?? RecorderError.noFrames)
                if !ok { try? FileManager.default.removeItem(at: url) }
                self.resetWriterState()
                done(ok ? url : nil, err)
            }
        }
    }

    /// writerQueue only.
    private func resetWriterState() {
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false
    }

    // MARK: - Unexpected stop

    /// writerQueue only.
    private func reportWriterFailure(_ error: Error?) {
        guard !failureReported else { return }
        failureReported = true
        let err = error ?? RecorderError.noFrames
        DispatchQueue.main.async { self.handleUnexpectedStop(err) }
    }

    /// MAIN.
    private func handleUnexpectedStop(_ error: Error) {
        guard state == .recording else { return }
        stopInternal { url, _ in
            self.onUnexpectedStop?(url, error)
        }
    }

    // MARK: - Border

    private func showBorder(around rect: NSRect) {
        removeBorder()
        let inset: CGFloat = 2
        let win = NSWindow(contentRect: rect.insetBy(dx: -inset, dy: -inset),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .statusBar
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView = DashedBorderView(frame: NSRect(origin: .zero, size: win.frame.size))
        win.orderFrontRegardless()
        borderWindow = win
    }

    private func removeBorder() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }

    private final class DashedBorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.setStroke()
            path.stroke()
        }
    }
}

// MARK: - SCStreamOutput (writerQueue)

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, let writer else { return }

        if type == .audio {
            guard sessionStarted, writer.status == .writing,
                  let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
            return
        }
        guard type == .screen, let videoInput else { return }

        // Skip status-only buffers (idle/started/suspended…) — only complete frames carry images.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else { return }

        if !sessionStarted {
            if writer.status == .unknown {
                guard writer.startWriting() else { reportWriterFailure(writer.error); return }
            }
            guard writer.status == .writing else { reportWriterFailure(writer.error); return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if writer.status == .failed { reportWriterFailure(writer.error); return }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        if !videoInput.append(sampleBuffer), writer.status == .failed {
            reportWriterFailure(writer.error)
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.handleUnexpectedStop(error)
        }
    }
}
