// Generates Resources/AppIcon.icns — a deep-indigo rounded square with a fanned
// deck of paper cards; the front card has text lines and a green check.
// Run from the package root:  swift tools/make_icon.swift
// Requires only Command Line Tools (AppKit offscreen drawing + iconutil).
import AppKit

func draw(_ s: CGFloat) {
    // Background squircle (Apple icon grid: ~80% canvas, ~22.5% corner radius)
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.27, green: 0.25, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.28, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    let cardW = s * 0.40, cardH = s * 0.52
    let center = CGPoint(x: s * 0.5, y: s * 0.47)

    func card(angle: CGFloat, dx: CGFloat, color: NSColor, shadow: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: center.x + dx, yBy: center.y)
        t.rotate(byDegrees: angle)
        t.concat()
        if shadow {
            let sh = NSShadow()
            sh.shadowBlurRadius = s * 0.03
            sh.shadowOffset = NSSize(width: 0, height: -s * 0.012)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
            sh.set()
        }
        let r = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: s * 0.035, yRadius: s * 0.035).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    card(angle: 14, dx: s * 0.09, color: NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.98, alpha: 1), shadow: true)
    card(angle: 6, dx: s * 0.045, color: NSColor(calibratedRed: 0.78, green: 0.82, blue: 1.0, alpha: 1), shadow: true)
    card(angle: -4, dx: -s * 0.02, color: .white, shadow: true)

    // Text lines + check on the front card (same transform as the front card)
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: center.x - s * 0.02, yBy: center.y)
    t.rotate(byDegrees: -4)
    t.concat()
    let lineColor = NSColor(calibratedRed: 0.30, green: 0.30, blue: 0.45, alpha: 0.55)
    lineColor.setFill()
    let left = -cardW / 2 + s * 0.05
    let widths: [CGFloat] = [0.27, 0.22, 0.25, 0.16]
    for (i, w) in widths.enumerated() {
        let y = cardH / 2 - s * 0.09 - CGFloat(i) * s * 0.058
        let h = i == 0 ? s * 0.030 : s * 0.020
        NSBezierPath(roundedRect: CGRect(x: left, y: y, width: s * w, height: h),
                     xRadius: h / 2, yRadius: h / 2).fill()
    }
    let cR = s * 0.085
    let cC = CGPoint(x: cardW / 2 - s * 0.10, y: -cardH / 2 + s * 0.11)
    NSColor(calibratedRed: 0.18, green: 0.74, blue: 0.42, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: cC.x - cR, y: cC.y - cR, width: cR * 2, height: cR * 2)).fill()
    let check = NSBezierPath()
    check.move(to: CGPoint(x: cC.x - cR * 0.45, y: cC.y + cR * 0.02))
    check.line(to: CGPoint(x: cC.x - cR * 0.10, y: cC.y - cR * 0.32))
    check.line(to: CGPoint(x: cC.x + cR * 0.48, y: cC.y + cR * 0.36))
    check.lineWidth = s * 0.022
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in variants {
    try! render(px).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}
if CommandLine.arguments.contains("--preview") {
    try! render(512).write(to: URL(fileURLWithPath: "icon-preview.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print(p.terminationStatus == 0 ? "✅ Resources/AppIcon.icns generated" : "❌ iconutil failed")
