// Draw mode's chrome: the toolbar hides (the pointer is frozen, so it couldn't be clicked), and this small
// capsule at the bottom says what's on: the tool (its colour), writing mode, the zoom lock and the page.
// A thin accent frame round the window marks draw mode itself.
import AppKit

final class StatusCapsule: NSView {
    struct Info: Equatable { var tool: ToolKind; var color: NSColor; var writing: Bool; var locked: Bool; var page: Int; var pages: Int; var zoom = ""; var arm = ""; var armAlpha = 1.0 }
    var info: Info? { didSet { if info != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // shows state only; clicks go through

    private func parts() -> [(NSImage?, String)] {
        guard let i = info else { return [] }
        var p: [(NSImage?, String)] = [(nil, i.tool.title)]
        if i.writing { p.append((NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Writing"), "Writing")) }
        if i.locked { p.append((NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Zoom locked"), "")) }
        if !i.arm.isEmpty { p.append((nil, i.arm)) }
        if !i.zoom.isEmpty { p.append((nil, i.zoom)) }
        p.append((nil, "\(i.page)/\(i.pages)"))
        return p
    }
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private var attrs: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor(white: 0.25, alpha: 1)] }

    var fittingWidth: CGFloat {
        var w: CGFloat = 12 + 10 + 6   // padding, dot, gap
        for (img, text) in parts() { w += (img != nil ? 14 : 0) + (text.isEmpty ? 0 : (text as NSString).size(withAttributes: attrs).width) + 12 }
        return ceil(w)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let i = info else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(white: 1, alpha: 0.9).setFill(); pill.fill()
        NSColor(white: 0, alpha: 0.12).setStroke(); pill.stroke()
        var x: CGFloat = 12
        let dot = CGRect(x: x, y: bounds.midY - 5, width: 10, height: 10)
        if i.tool == .eraser { NSColor(white: 0.55, alpha: 1).setStroke(); NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75)).stroke() }
        else { i.color.setFill(); NSBezierPath(ovalIn: dot).fill() }
        x += 16
        for (img, text) in parts() {
            if let img {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [NSColor(white: 0.3, alpha: 1)]))
                if let m = img.withSymbolConfiguration(cfg) { m.draw(in: CGRect(x: x, y: bounds.midY - m.size.height / 2, width: m.size.width, height: m.size.height)); x += m.size.width + 3 }
            }
            if !text.isEmpty {
                var a = attrs
                if text == "Armed" { a[.foregroundColor] = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: CGFloat(0.25 + 0.75 * i.armAlpha)); a[.font] = NSFont.systemFont(ofSize: 12, weight: .bold) }
                if text == "Click to arm" { a[.foregroundColor] = NSColor(white: 0.5, alpha: 1) }
                let sz = (text as NSString).size(withAttributes: a)
                (text as NSString).draw(at: CGPoint(x: x, y: bounds.midY - sz.height / 2), withAttributes: a)
                x += sz.width
            }
            x += 9
        }
    }
}

/// The accent frame round the window in draw mode (drawn over the page's edge, never on the writing area).
final class DrawModeFrame: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 3
        layer?.borderColor = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 0.55).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go through
}
