// Draws the app icon (a disk ring split into category colours) and writes Resources/AppIcon.icns.
// Run through scripts/make-icon.sh.
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle with the standard macOS icon margin.
    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    ctx.saveGState()
    path.addClip()
    NSGradient(colors: [NSColor(red: 0.10, green: 0.14, blue: 0.34, alpha: 1), NSColor(red: 0.05, green: 0.36, blue: 0.62, alpha: 1)])!
        .draw(in: body, angle: -60)

    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = body.width * 0.30
    let line = body.width * 0.115
    let arcs: [(Double, NSColor)] = [
        (0.34, NSColor(red: 0.20, green: 0.84, blue: 0.80, alpha: 1)),
        (0.22, NSColor(red: 1.00, green: 0.42, blue: 0.62, alpha: 1)),
        (0.15, NSColor(red: 1.00, green: 0.70, blue: 0.25, alpha: 1)),
        (0.09, NSColor(red: 0.45, green: 0.92, blue: 0.50, alpha: 1)),
    ]
    // Track
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    var start = CGFloat.pi / 2
    let gap: CGFloat = 0.035
    for (share, color) in arcs {
        let sweep = CGFloat(share) * .pi * 2
        ctx.setStrokeColor(color.cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: start - gap, endAngle: start - sweep + gap, clockwise: true)
        ctx.strokePath()
        start -= sweep
    }
    // Lens handle, so it reads as "look into the disk".
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(line * 0.9)
    let a = CGFloat.pi * 1.75
    ctx.move(to: CGPoint(x: center.x + cos(a) * (radius + line * 0.9), y: center.y + sin(a) * (radius + line * 0.9)))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * (radius + line * 2.0), y: center.y + sin(a) * (radius + line * 2.0)))
    ctx.strokePath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
    ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes { try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png")) }
