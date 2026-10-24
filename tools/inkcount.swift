// Counts dark (ink) pixels in a window screenshot, inside the canvas area (excludes title bar,
// hint line and toolbar by cropping 12% top / 14% bottom / 6% sides).
import AppKit
let img = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let w = rep.pixelsWide, h = rep.pixelsHigh
var dark = 0, total = 0
for y in Int(Double(h) * 0.12)..<Int(Double(h) * 0.86) {
    for x in Int(Double(w) * 0.06)..<Int(Double(w) * 0.94) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        total += 1
        if c.redComponent + c.greenComponent + c.blueComponent < 1.2 { dark += 1 }
    }
}
print("ink pixels: \(dark) of \(total) (\(String(format: "%.3f", Double(dark) / Double(total) * 100))%)")
