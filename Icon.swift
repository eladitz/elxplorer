// Draws the app icon: an Explorer-style yellow folder with a blue band, on a dark rounded tile.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); color(0x1B2A44).setFill(); tilePath.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x2F4E7E), color(0x18243B)])!.draw(in: tilePath, angle: -90)

    // Back of the folder with its tab.
    let back = NSBezierPath()
    let l = s * 0.24, r = s * 0.76, b = s * 0.28, t = s * 0.68, tabW = s * 0.2, tabH = s * 0.05, rad = s * 0.03
    back.move(to: NSPoint(x: l + rad, y: b))
    back.line(to: NSPoint(x: r - rad, y: b))
    back.curve(to: NSPoint(x: r, y: b + rad), controlPoint1: NSPoint(x: r, y: b), controlPoint2: NSPoint(x: r, y: b))
    back.line(to: NSPoint(x: r, y: t - rad))
    back.curve(to: NSPoint(x: r - rad, y: t), controlPoint1: NSPoint(x: r, y: t), controlPoint2: NSPoint(x: r, y: t))
    back.line(to: NSPoint(x: l + tabW + s * 0.04, y: t))
    back.line(to: NSPoint(x: l + tabW, y: t + tabH))
    back.line(to: NSPoint(x: l + rad, y: t + tabH))
    back.curve(to: NSPoint(x: l, y: t + tabH - rad), controlPoint1: NSPoint(x: l, y: t + tabH), controlPoint2: NSPoint(x: l, y: t + tabH))
    back.line(to: NSPoint(x: l, y: b + rad))
    back.curve(to: NSPoint(x: l + rad, y: b), controlPoint1: NSPoint(x: l, y: b), controlPoint2: NSPoint(x: l, y: b))
    NSGradient(colors: [color(0xF2B53A), color(0xD9902A)])!.draw(in: back, angle: -90)

    // A sheet of paper peeking out.
    let paper = NSBezierPath(roundedRect: NSRect(x: s * 0.29, y: s * 0.4, width: s * 0.42, height: s * 0.26), xRadius: s * 0.015, yRadius: s * 0.015)
    color(0xF6F7F9).setFill(); paper.fill()

    // Front flap, then the blue band Explorer's folder is known for.
    let front = NSBezierPath(roundedRect: NSRect(x: s * 0.22, y: s * 0.26, width: s * 0.56, height: s * 0.33), xRadius: s * 0.035, yRadius: s * 0.035)
    NSGradient(colors: [color(0xFFD45C), color(0xF5B83B)])!.draw(in: front, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    front.addClip()
    color(0x2F7FE0).setFill()
    NSRect(x: s * 0.22, y: s * 0.355, width: s * 0.56, height: s * 0.07).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
