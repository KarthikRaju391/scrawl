// Back to content (0.1.7.1, Karthik): outside draw mode, once the page's content (all its ink and pictures, anywhere on the
// infinite canvas) is mostly out of view, a small pill above the toolbar says "Back to content  ⇧⌘0"; clicking it (or ⇧⌘0,
// View › Back to Content) slides and zooms the view so all the content fits: 7% margin on each side and clear of the
// toolbar, the zoom between 25% (as far out as the canvas goes) and 100% (a page with one word isn't blown up to 800%).
// An empty page goes to its top at 100%, as a new page opens. With the zoom locked it only centres the content.
//
// The pill shows when less than 60% of the content is in the window (of the content box, or of the window when the content
// is bigger than it: zoomed in on a full page is "on the content"), or the window's centre is more than 20% of its width
// outside the content box. It hides again only at 75% / within 10% (hysteresis: no flicker while panning at the edge).
// On an empty page the "content" is the page's top screen at 100%. Never in draw mode or the overview, never with
// `--column-bound` (the view can't leave the page there).
import AppKit

extension CanvasView {
    static let contentMargin = 0.07, contentZoomRange = (0.25, 1.0)
    static let backShowVisible = 0.60, backHideVisible = 0.75, backShowOff = 0.20, backHideOff = 0.10

    /// All the page's ink and pictures (page units), nil on an empty page.
    var contentBox: CGRect? {
        let rects = doc.strokes.map(\.bounds) + doc.images.map(\.frame)
        guard let f = rects.first else { return nil }
        return rects.dropFirst().reduce(f) { $0.union($1) }
    }

    /// The page's top screen at 100%: where an empty page is.
    private var homeCamera: Camera { var h = camera; h.zoom = 1; h.home(); h.clamp(); return h }

    /// What the window shows with `cam` (page units): the whole canvas view, not just the trackpad's area.
    func windowRect(_ cam: Camera) -> CGRect { renderRect(for: cam) }

    /// The camera that shows `box` in the window's free area (7% margins, above the toolbar's strip `bottomInsetPt`) at
    /// zoom `z`, the box's middle in the free area's middle.
    private func cameraShowing(_ box: CGRect, zoom z: Double) -> Camera {
        var t = camera; t.zoom = z
        let r = padRect, k = t.visible.width / max(Double(r.width), 1)   // page units per view point at zoom z
        let b = bounds, inset = Double(bottomInsetPt)
        let px = Double(b.width) / 2, py = (inset + Double(b.height)) / 2   // the free area's middle (view points, y up)
        let minX = box.midX - (px - Double(r.minX)) * k, minY = box.midY - (py - Double(r.minY)) * k
        t.center = CGPoint(x: minX + t.visible.width / 2, y: minY + t.visible.height / 2)
        t.clamp()
        return t
    }

    /// The zoom that fits `box` in the window's free area (7% margins, above the toolbar), within 25-100%.
    func fitZoom(_ box: CGRect) -> Double {
        let r = padRect, b = bounds, m = Self.contentMargin, inset = Double(bottomInsetPt)
        let freeW = Double(b.width) * (1 - 2 * m), freeH = max(Double(b.height) * (1 - 2 * m) - inset, 1)
        // At zoom z, one view point is page.width / z / pad width units: z = page.width x free points / (pad width x box units).
        let pw = camera.page.width / max(Double(r.width), 1)
        let z = min(pw * freeW / max(box.width, 1e-6), pw * freeH / max(box.height, 1e-6))
        return min(max(z, max(Self.contentZoomRange.0, camera.minZoom)), Self.contentZoomRange.1)
    }

    /// Where Back to Content goes from here: all the content fitted (zoom 25-100%); an empty page: its top at 100%; with
    /// the zoom locked, the content centred at this zoom.
    func backToContentTarget() -> Camera {
        guard let box = contentBox?.insetBy(dx: -0.5, dy: -0.5) else { return tools.zoomLocked ? { var h = camera; h.home(); h.clamp(); return h }() : homeCamera }
        return cameraShowing(box, zoom: tools.zoomLocked ? camera.zoom : fitZoom(box))
    }

    /// How much of the content the window shows now: (the share visible, of the content box or of the window when the
    /// content is bigger; the window centre's distance outside the content box, in window widths). An empty page: the
    /// page's top screen at 100% stands for the content.
    func contentInView(_ cam: Camera) -> (visible: Double, off: Double) {
        let s = windowRect(cam)
        let box = (contentBox ?? windowRect(homeCamera)).insetBy(dx: -1, dy: -1)
        let i = box.intersection(s)
        let shown = i.isNull ? 0 : Double(i.width * i.height) / max(min(Double(box.width * box.height), Double(s.width * s.height)), 1e-9)
        let dx = max(box.minX - s.midX, 0, s.midX - box.maxX), dy = max(box.minY - s.midY, 0, s.midY - box.maxY)
        return (min(shown, 1), hypot(dx, dy) / Double(s.width))
    }

    /// Whether the pill should show now, given whether it is showing (the hysteresis).
    func backToContentWanted(showing: Bool) -> Bool {
        guard !drawMode, !Camera.columnBound else { return false }
        let c = contentInView(camera)
        return showing ? (c.visible < Self.backHideVisible || c.off > Self.backHideOff)
                       : (c.visible < Self.backShowVisible || c.off > Self.backShowOff)
    }

    /// ⇧⌘0 / the pill: fit the content (works with the zoom locked: then only centred, no beep).
    func backToContent() {
        cancelPendingMove()
        let t = backToContentTarget()
        act("backToContent", ["fromX": camera.center.x, "fromY": camera.center.y, "fromZoom": camera.zoom, "toX": t.center.x, "toY": t.center.y, "toZoom": t.zoom])
        animateCamera(to: t, src: "backToContent", duration: 0.3)
    }
}

/// The pill: a quiet label that is a button ("Back to content  ⇧⌘0"), bottom right above the toolbar.
final class BackToContentPill: NSView {
    let label = PillLabel()
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.stringValue = "Back to content  ⇧⌘0"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.30, alpha: 1)
        label.fillColor = NSColor(white: 0.95, alpha: 0.95)   // a faint grey: white vanished on the paper
        label.paddingX = 12
        addSubview(label)
        setAccessibilityRole(.button); setAccessibilityLabel("Back to content")
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
