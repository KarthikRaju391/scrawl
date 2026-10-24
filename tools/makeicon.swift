// Draws the app icon (a trackpad with a handwritten stroke) at every size and builds AppIcon.icns.
// Usage: swift tools/makeicon.swift resources/AppIcon.icns
import AppKit

func icon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024, ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824 x 824 rounded square centred in 1024.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    // The trackpad: a slightly darker inset surface.
    let pad = body.insetBy(dx: 110 * s, dy: 150 * s)
    ctx.addPath(CGPath(roundedRect: pad, cornerWidth: 46 * s, cornerHeight: 46 * s, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1).cgColor)
    ctx.fillPath()
    // A handwritten loop in Keep blue, thick to thin.
    let pts: [CGPoint] = stride(from: 0.0, through: 1.0, by: 0.01).map { t in
        let x = 0.18 + 0.64 * t, y = 0.5 + 0.17 * sin(t * 2 * .pi * 1.5) * (1 - 0.3 * t)
        return CGPoint(x: pad.minX + x * pad.width, y: pad.minY + y * pad.height)
    }
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1).cgColor)
    for (i, p) in pts.enumerated() {
        let r = (34 - 20 * Double(i) / Double(pts.count)) * s
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    // The fingertip.
    let tip = pts.last!
    ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.74, blue: 0.02, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: tip.x - 40 * s, y: tip.y - 40 * s, width: 80 * s, height: 80 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "resources/AppIcon.icns"
let set = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! icon(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try! icon(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set, "-o", out]
try! p.run(); p.waitUntilExit()
try! icon(1024).write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + ".png"))
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
