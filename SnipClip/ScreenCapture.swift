import AppKit
import CoreGraphics

enum ScreenCapture {
    /// Captures the given NSRect (NSScreen coordinates, bottom-left origin) and returns an NSImage
    /// sized in logical points. Uses CGDisplayCreateImage + crop so the scale factor is derived
    /// from the actual display rather than assumed, which avoids zoom issues on Retina displays.
    static func capture(nsScreenRect rect: NSRect) -> NSImage? {
        guard let screen = containingScreen(for: rect),
              let displayID = screen.displayID,
              let fullImage = CGDisplayCreateImage(displayID) else { return nil }

        // Scale factor: physical pixels per logical point on this display
        let scaleX = CGFloat(fullImage.width)  / screen.frame.width
        let scaleY = CGFloat(fullImage.height) / screen.frame.height

        // Convert from global NSScreen coords → coords local to this screen
        let local = NSRect(
            x: rect.origin.x - screen.frame.origin.x,
            y: rect.origin.y - screen.frame.origin.y,
            width: rect.width,
            height: rect.height
        )

        // Flip Y (NSScreen origin = bottom-left; CGImage origin = top-left)
        let cropRect = CGRect(
            x: local.origin.x * scaleX,
            y: (screen.frame.height - local.maxY) * scaleY,
            width: local.width  * scaleX,
            height: local.height * scaleY
        )

        // Clamp to actual pixel bounds — prevents nil/bad crops near screen edges
        let imageBounds = CGRect(x: 0, y: 0,
                                 width: CGFloat(fullImage.width),
                                 height: CGFloat(fullImage.height))
        let safeCrop = cropRect.intersection(imageBounds)
        guard !safeCrop.isNull, !safeCrop.isEmpty,
              let cropped = fullImage.cropping(to: safeCrop) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    /// Returns the screen that contains the largest portion of rect.
    private static func containingScreen(for rect: NSRect) -> NSScreen? {
        NSScreen.screens.max {
            NSIntersectionRect($0.frame, rect).area < NSIntersectionRect($1.frame, rect).area
        }
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
