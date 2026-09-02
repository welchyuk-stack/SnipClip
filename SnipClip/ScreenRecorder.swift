import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Very basic full-screen video recording: start, stop, write an .mp4 to a
/// caller-supplied URL. Captures the display under the pointer, no audio.
final class ScreenRecorder: NSObject {
    static let shared = ScreenRecorder()

    private(set) var isRecording = false

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let writerQueue = DispatchQueue(label: "com.snipclip.mac.recorder.writer")

    private override init() { super.init() }

    enum RecorderError: LocalizedError {
        case noDisplay
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Couldn't find a display to record."
            }
        }
    }

    func start(to url: URL, completion: @escaping (Error?) -> Void) {
        guard !isRecording else { return }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                let loc = NSEvent.mouseLocation
                let display = content.displays.first { ScreenRecorder.nsScreen(for: $0)
                    .map { NSMouseInRect(loc, $0.frame, false) } ?? false
                } ?? content.displays.first
                guard let display else { throw RecorderError.noDisplay }

                let scale = ScreenRecorder.nsScreen(for: display)?.backingScaleFactor ?? 2
                // Even dimensions — H.264 requires it, and points-to-pixels
                // scaling on Retina displays can land on an odd number.
                let width = Int(CGFloat(display.width) * scale) & ~1
                let height = Int(CGFloat(display.height) * scale) & ~1

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.showsCursor = true
                config.pixelFormat = kCVPixelFormatType_32BGRA

                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                self.writer = writer
                self.videoInput = input
                self.sessionStarted = false

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
                try await stream.startCapture()
                self.stream = stream
                self.isRecording = true
                await MainActor.run { completion(nil) }
            } catch {
                await MainActor.run { completion(error) }
            }
        }
    }

    func stop(completion: @escaping (URL?, Error?) -> Void) {
        guard isRecording, let stream else { completion(nil, nil); return }
        isRecording = false

        Task {
            try? await stream.stopCapture()
            self.stream = nil
            self.videoInput?.markAsFinished()

            guard let writer = self.writer, self.sessionStarted else {
                await MainActor.run { completion(nil, RecorderError.noDisplay) }
                return
            }
            let outputURL = writer.outputURL
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            self.writer = nil
            self.videoInput = nil
            await MainActor.run { completion(outputURL, nil) }
        }
    }

    private static func nsScreen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, isRecording, sampleBuffer.isValid,
              let writer, let videoInput else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRecording = false
    }
}
