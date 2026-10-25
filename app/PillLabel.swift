// A rounded pill with one line of text, centred: equal padding left and right, and the cap height centred
// top to bottom (what reads as centred; centring the whole line box puts text without descenders ~2-4 pt
// high, which is how the old NSTextField labels looked). Used for the toast, the draw-mode / page-full
// banner and the page label.
import AppKit

final class PillLabel: NSView {
    var stringValue = "" { didSet { if stringValue != oldValue { needsDisplay = true } } }
    var font = NSFont.systemFont(ofSize: 12, weight: .medium) { didSet { needsDisplay = true } }
    var textColor = NSColor.white { didSet { needsDisplay = true } }
    var fillColor = NSColor.black { didSet { needsDisplay = true } }
    var paddingX: CGFloat = 14

    private var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: textColor] }
    /// Width that fits the text with the padding.
    var fittingWidth: CGFloat { ceil((stringValue as NSString).size(withAttributes: attributes).width) + 2 * paddingX }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        fillColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let s = stringValue as NSString, size = s.size(withAttributes: attributes)
        // draw(at:) puts the line's descent at the point; baseline = point.y - descender (descender < 0).
        let baseline = (r.height - font.capHeight) / 2
        s.draw(at: CGPoint(x: (r.width - size.width) / 2, y: baseline + font.descender), withAttributes: attributes)
    }
}
