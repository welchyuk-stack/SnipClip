import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures one display. On macOS 14+ uses ScreenCaptureKit (optionally
/// excluding SnipClip's own windows); on macOS 13 falls back to
/// CGDisplayCreateImage.
final class DisplayCapturer {
    let screen: NSScreen
    private let displayID: CGDirectDisplayID
    // Stored as AnyObject so the class compiles for a macOS 13 target.
    private var scFilter: AnyObject?
    private var scConfig: AnyObject?

    private init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.screen = screen
        self.displayID = displayID
    }

    static func make(for screen: NSScreen, excludingOwnWindows: Bool) async -> DisplayCapturer? {
        guard let displayID = screen.displayID else { return nil }
        let capturer = DisplayCapturer(screen: screen, displayID: displayID)
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
                let pid = getpid()
                let excluded = excludingOwnWindows
                    ? content.windows.filter { $0.owningApplication?.processID == pid }
                    : []
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let config = SCStreamConfiguration()
                config.captureResolution = .best
                config.showsCursor = false
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int((filter.contentRect.width * scale).rounded())
                config.height = Int((filter.contentRect.height * scale).rounded())
                capturer.scFilter = filter
                capturer.scConfig = config
            } catch {
                return nil
            }
        }
        return capturer
    }

    func capture() async -> CGImage? {
        if #available(macOS 14.0, *),
           let filter = scFilter as? SCContentFilter,
           let config = scConfig as? SCStreamConfiguration {
            return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        return CGDisplayCreateImage(displayID)
    }
}

enum ScreenCapture {
    static func crop(_ image: CGImage, screen: NSScreen, rect: NSRect) -> CGImage? {
        let sf = screen.frame
        guard sf.width > 0 else { return nil }
        let s = CGFloat(image.width) / sf.width
        let cropRect = CGRect(x: (rect.minX - sf.minX) * s,
                              y: (sf.maxY - rect.maxY) * s,
                              width: rect.width * s,
                              height: rect.height * s).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let safe = cropRect.intersection(bounds)
        guard !safe.isNull, !safe.isEmpty else { return nil }
        return image.cropping(to: safe)
    }

    static func image(from cg: CGImage, pointSize: NSSize) -> NSImage {
        NSImage(cgImage: cg, size: pointSize)
    }

    static func screenUnderMouse() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    @MainActor static func captureFullScreen() async -> NSImage? {
        let screen = screenUnderMouse()
        guard let capturer = await DisplayCapturer.make(for: screen, excludingOwnWindows: true),
              let cg = await capturer.capture() else { return nil }
        return image(from: cg, pointSize: screen.frame.size)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
