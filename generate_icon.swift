#!/usr/bin/swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))

img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// ── Background gradient — deep navy ──────────────────────────────────
let cs = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    CGColor(red: 0.06, green: 0.11, blue: 0.22, alpha: 1),  // #0F1C38
    CGColor(red: 0.03, green: 0.05, blue: 0.12, alpha: 1),  // #080D1F
] as CFArray
let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: [])

// ── Helper: rounded rect clip ─────────────────────────────────────────
// macOS applies its own mask so we draw to the full square.

// ── Glow behind the selection box ────────────────────────────────────
let glowRect = CGRect(x: 262, y: 262, width: 500, height: 500)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 120,
    color: CGColor(red: 0.24, green: 0.50, blue: 0.91, alpha: 0.45))
ctx.setFillColor(CGColor(red: 0.24, green: 0.50, blue: 0.91, alpha: 0.01))
ctx.fill(glowRect)
ctx.restoreGState()

// ── Selection rectangle — white stroke ───────────────────────────────
let boxInset: CGFloat = 280
let boxRect = CGRect(x: boxInset, y: boxInset,
                     width: size - boxInset * 2,
                     height: size - boxInset * 2)
let cornerR: CGFloat = 10

// Dashed stroke
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.90))
ctx.setLineWidth(10)
ctx.setLineDash(phase: 0, lengths: [28, 14])
let boxPath = CGPath(roundedRect: boxRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
ctx.addPath(boxPath)
ctx.strokePath()
ctx.restoreGState()

// Corner handle squares — accent blue fill
func handle(_ cx: CGFloat, _ cy: CGFloat) {
    let hw: CGFloat = 30
    let r = CGRect(x: cx - hw/2, y: cy - hw/2, width: hw, height: hw)
    ctx.setFillColor(CGColor(red: 0.24, green: 0.50, blue: 0.91, alpha: 1))  // #3D80E8
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(4)
    let p = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
    ctx.addPath(p); ctx.fillPath()
    ctx.addPath(p); ctx.strokePath()
}
handle(boxRect.minX, boxRect.minY)
handle(boxRect.maxX, boxRect.minY)
handle(boxRect.minX, boxRect.maxY)
handle(boxRect.maxX, boxRect.maxY)

// ── Scissors icon — bottom-right of box ──────────────────────────────
// Simple scissors drawn with bezier paths
let sx: CGFloat = 620   // pivot center X
let sy: CGFloat = 372   // pivot center Y  (low in icon, above handle corner)
let bladeLen: CGFloat = 160
let handleLen: CGFloat = 130
let spread: CGFloat = 28   // half-angle spread in degrees

func point(from center: CGPoint, angle: CGFloat, dist: CGFloat) -> CGPoint {
    CGPoint(x: center.x + cos(angle) * dist,
            y: center.y + sin(angle) * dist)
}

let pivot = CGPoint(x: sx, y: sy)
let angles: [CGFloat] = [.pi * 0.18, -.pi * 0.18, .pi + .pi * 0.18, .pi - .pi * 0.18]

ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(18)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))

// Two blades
for angle in [CGFloat.pi * 0.14, -.pi * 0.14] {
    let tip = point(from: pivot, angle: angle + .pi, dist: bladeLen)
    ctx.move(to: pivot)
    ctx.addLine(to: tip)
}
ctx.strokePath()

// Two handles
ctx.setLineWidth(14)
ctx.setStrokeColor(CGColor(red: 0.24, green: 0.50, blue: 0.91, alpha: 1))
for angle in [CGFloat.pi * 0.14, -.pi * 0.14] {
    let end = point(from: pivot, angle: angle, dist: handleLen)
    ctx.move(to: pivot)
    ctx.addLine(to: end)
}
ctx.strokePath()

// Pivot circle
ctx.setFillColor(CGColor(red: 0.24, green: 0.50, blue: 0.91, alpha: 1))
ctx.fillEllipse(in: CGRect(x: pivot.x - 16, y: pivot.y - 16, width: 32, height: 32))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: pivot.x - 8, y: pivot.y - 8, width: 16, height: 16))

ctx.restoreGState()

// ── Subtle vignette ───────────────────────────────────────────────────
let vigColors = [
    CGColor(red: 0, green: 0, blue: 0, alpha: 0),
    CGColor(red: 0, green: 0, blue: 0, alpha: 0.35),
] as CFArray
let vigGrad = CGGradient(colorsSpace: cs, colors: vigColors, locations: [0.4, 1])!
ctx.drawRadialGradient(vigGrad,
    startCenter: CGPoint(x: size/2, y: size/2), startRadius: 0,
    endCenter: CGPoint(x: size/2, y: size/2), endRadius: size * 0.72,
    options: [.drawsAfterEndLocation])

img.unlockFocus()

// ── Save PNG ──────────────────────────────────────────────────────────
guard let tiff = img.tiffRepresentation,
      let rep  = NSBitmapImageRep(data: tiff),
      let png  = rep.representation(using: .png, properties: [:]) else {
    print("Failed to encode PNG"); exit(1)
}

let outURL = URL(fileURLWithPath: "SnipClip/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
try! png.write(to: outURL)
print("✓ Wrote \(outURL.path)")
