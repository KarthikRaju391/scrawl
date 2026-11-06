// Back to the page (0.1.7, the infinite canvas; Karthik): outside draw mode, once the view has drifted away from the page a
// small pill above the toolbar says "Back to page  ⇧⌘0"; clicking it (or ⇧⌘0, View › Back to Page) slides the view back,
// the page's column centred, at the same zoom. Never in draw mode, never with `--column-bound` (the view can't leave).
//
// Away from the page (shown): the view's centre is more than 20% of the view's width outside the column [0, page width]
// (inside it, anywhere, is on the page: zoomed in on its right half is still the page), or the view's top is more than 10%
// of its height above the page's top. It hides again only once within 10% / 5% (hysteresis: panning at the threshold
// doesn't make it flicker). Below the page's ink isn't away: the page goes on downwards, and that's where new writing goes.
import AppKit

extension CanvasView {
    static let backShowSide = 0.20, backHideSide = 0.10, backShowAbove = 0.10, backHideAbove = 0.05

    /// How far `cam` is from the page: (sideways: the view centre's distance outside the column, in view widths; above:
    /// the view's top above the page's top, in view heights). 0 on the page.
    func pageDrift(_ cam: Camera) -> (side: Double, above: Double) {
        let v = cam.visible, w = cam.page.width
        let out = v.midX < 0 ? -v.midX : (v.midX > w ? v.midX - w : 0)
        return (out / v.width, max(v.maxY - cam.page.height, 0) / v.height)
    }

    /// Whether the pill should show now, given whether it is showing (the hysteresis).
    func backToPageWanted(showing: Bool) -> Bool {
        guard !drawMode, !Camera.columnBound else { return false }
        let d = pageDrift(camera)
        return showing ? (d.side > Self.backHideSide || d.above > Self.backHideAbove)
                       : (d.side > Self.backShowSide || d.above > Self.backShowAbove)
    }

    /// Where "back to the page" goes from `cam`: the column centred sideways, the zoom kept. Up and down the view stays,
    /// unless it is above the page's top (then the page's top at the view's top) or, once centred, no ink or picture of
    /// the page is in it (then the nearest: the view's top just above content below it, or a quarter down from the top
    /// when the content is above it).
    func backToPageTarget(_ cam: Camera) -> Camera {
        var t = cam
        t.center.x = cam.page.width / 2
        var v = t.visible
        let top = cam.page.height
        if v.maxY > top { t.center.y = top - v.height / 2; v = t.visible }
        let rects = doc.strokes.map(\.bounds) + doc.images.map(\.frame)
        if let c = rects.dropFirst().reduce(rects.first, { $0?.union($1) }), !rects.contains(where: { $0.intersects(v) }) {
            if v.minY > c.maxY { t.center.y = min(c.maxY + 0.05 * v.height, top) - v.height / 2 }        // content below the view
            else if v.maxY < c.minY { t.center.y = min(c.minY + 0.25 * v.height, top) - v.height / 2 }   // content above it
        }
        t.clamp()
        return t
    }

    /// ⇧⌘0 / the pill: slide back to the page (works with the zoom locked: the zoom doesn't change).
    func backToPage() {
        cancelPendingMove()
        let t = backToPageTarget(camera)
        act("backToPage", ["fromX": camera.center.x, "fromY": camera.center.y, "toX": t.center.x, "toY": t.center.y])
        animateCamera(to: t, src: "backToPage", duration: 0.3)
    }
}

/// The pill: a quiet label that is a button ("Back to page  ⇧⌘0"), under the page label at the top, out of the toolbar's way.
final class BackToPagePill: NSView {
    let label = PillLabel()
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.stringValue = "Back to page  ⇧⌘0"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.30, alpha: 1)
        label.fillColor = NSColor(white: 1, alpha: 0.9)
        label.paddingX = 12
        addSubview(label)
        setAccessibilityRole(.button); setAccessibilityLabel("Back to page")
        wantsLayer = true
        layer?.shadowOpacity = 0.12; layer?.shadowRadius = 3; layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
    required init?(coder: NSCoder) { fatalError() }
    var fittingSize_: CGSize { CGSize(width: label.fittingWidth, height: 22) }
    override func layout() { super.layout(); label.frame = bounds }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
