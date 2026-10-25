// Records the main display for N seconds at native resolution, 60fps, no audio,
// excluding every window owned by the given bundle IDs.
// Usage: rec <out.mov> <seconds> [bundle.id.to.exclude ...]
import ScreenCaptureKit
import AVFoundation
import AppKit

final class Rec: NSObject, SCStreamOutput {
    let writer: AVAssetWriter; let input: AVAssetWriterInput; var started = false
    init(url: URL, w: Int, h: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000]])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started { writer.startWriting(); writer.startSession(atSourceTime: sb.presentationTimeStamp); started = true }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }
}

@main struct Main { static func main() async throws {
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1]); let secs = Double(args[2])!
let excluded = Set(args.dropFirst(3))
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
let display = content.displays.first { $0.displayID == CGMainDisplayID() }!
let apps = content.applications.filter { excluded.contains($0.bundleIdentifier) }
let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
let scale = Int(NSScreen.main!.backingScaleFactor)
let cfg = SCStreamConfiguration()
cfg.width = display.width * scale; cfg.height = display.height * scale
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
cfg.showsCursor = true; cfg.capturesAudio = false; cfg.queueDepth = 6
let rec = try Rec(url: out, w: cfg.width, h: cfg.height)
let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec"))
try await stream.startCapture()
try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
try await stream.stopCapture()
rec.input.markAsFinished()
await rec.writer.finishWriting()
print("saved \(out.path) \(cfg.width)x\(cfg.height) excluded:\(apps.map(\.bundleIdentifier))")
}}
