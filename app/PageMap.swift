// The page map: a small picture of the page in the top-right corner, with the part you're looking at
// outlined. It appears only while you move the page yourself (two-finger pan, pinch, arrow keys, scrolling),
// at any zoom (0.1.7, the infinite canvas: Karthik; before, and with `--column-bound`, only zoomed in past 1.5x), and
// fades out 1.2 s after the last move: writing, auto-pans and new lines never
// show it. While the pointer is on it, it stays, so you can click or drag it to move the view (outside draw
// mode, where there's a pointer). The ink picture renders on a background queue, at most every 0.4 s and only
// after a stroke ends, so it never touches the writing path; the outline is redrawn live. View › Page Map
// turns it off.
import AppKit

final class PageMapView: NSView {
    weak var canvas: CanvasView?
    static let width: CGFloat = 132
    /// Shown above this zoom: any (the infinite canvas), or past 1.5x with `--column-bound` (the page's column only).
    static var minZoom: Double { Camera.columnBound ? 1.5 : 0 }
    nonisolated(unsafe) static var enabled = Launch.testing ? true : (UserDefaults.standard.object(forKey: "pageMap") as? Bool ?? true)

    private var image: CGImage?
    private var region = CGRect.zero          // page units the image covers
    private var renderedVersion = -1
    private var renderedPage: Int?   // Document.uid
    private var rendering = false
    private var lastRender = 0.0
    private let queue = DispatchQueue(label: "scrawl.pagemap", qos: .utility)
    private(set) var renders = 0

    /// The view moves that show it: the ones you make by hand.
    static let revealSources: Set<String> = ["pinch", "scroll", "magnify", "arrow", "pageMap"]
    static let holdSeconds = 1.2
    private var shownUntil = 0.0
    private var hovering = false
    private var fade: DispatchWorkItem?

    /// Whether it should be on screen now.
    var wanted: Bool {
        guard Self.enabled, let c = canvas, c.camera.zoom > Self.minZoom else { return false }
        return hovering || CACurrentMediaTime() < shownUntil
    }
    /// The view changed; show the map if you moved it yourself.
    func viewChanged(source: String) {
        if Self.revealSources.contains(source) { reveal() } else if !isHidden { needsDisplay = true }
    }
    private func reveal() {
        guard Self.enabled, let c = canvas, c.camera.zoom > Self.minZoom else { return }
        shownUntil = CACurrentMediaTime() + Self.holdSeconds
        fade?.cancel()
        if isHidden || alphaValue < 1 { alphaValue = 1; superview?.needsLayout = true }
        needsDisplay = true
        scheduleFade()
    }
    private func scheduleFade() {
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.animator().alphaValue = 0 }, completionHandler: { [weak self] in self?.superview?.needsLayout = true })
        }
        fade = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: w)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; fade?.cancel(); alphaValue = 1 }
    override func mouseExited(with e: NSEvent) { hovering = false; shownUntil = CACurrentMediaTime() + Self.holdSeconds; scheduleFade() }

    /// The page area the map shows: the page's width, from its top down to below the lowest ink or the view.
    /// Test hook: the page area the map covers now.
    var regionForTest: CGRect { canvas.map(wantedRegion) ?? .zero }

    /// The area the map shows: the page's first screen, all the ink (also past the page's sides, where you
    /// kept writing) and the view, with a small margin.
    private func wantedRegion(_ c: CanvasView) -> CGRect {
        let page = c.camera.page
        var r = CGRect(x: 0, y: 0, width: page.width, height: page.height).union(c.camera.visible)
        for s in c.doc.strokes { r = r.union(s.bounds) }
        for i in c.doc.images { r = r.union(i.frame) }
        let m = page.width * 0.02
        r = r.insetBy(dx: -m, dy: -m)
        if !Camera.columnBound { return r }   // the infinite canvas: everything there is, above the page's top too
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: min(r.maxY, page.height + m) - r.minY)
    }

    /// Re-render the ink picture if the page changed (throttled, off the main thread).
    func refresh() {
        guard let c = canvas, wanted else { return }
        let doc = c.doc, key = doc.uid, r = wantedRegion(c)
        let stale = doc.version != renderedVersion || key != renderedPage || abs(r.height - region.height) > 1 || abs(r.width - region.width) > 1 || abs(r.minX - region.minX) > 1
        guard stale, !rendering, CACurrentMediaTime() - lastRender > 0.4 else {
            if stale && !rendering { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refresh() } }
            return
        }
        rendering = true
        let strokes = doc.strokes, images = doc.images, v = doc.version, page = c.camera.page
        let px = CGSize(width: Self.width * 2, height: Self.width * 2 * r.height / r.width)
        queue.async { [weak self] in
            let img = PageImage.render(strokes, images: images, rect: r, pageWidth: page.width, pageTop: page.height, px: px, fast: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.image = img; self.region = r; self.renderedVersion = v; self.renderedPage = key
                self.rendering = false; self.lastRender = CACurrentMediaTime(); self.renders += 1
                self.superview?.needsLayout = true; self.needsDisplay = true
            }
        }
    }

    /// Height for the current region (capped: a long page shows the part around the view).
    var preferredHeight: CGFloat {
        guard region.width > 0 else { return Self.width * 0.62 }
        return min(Self.width * region.height / region.width, 190)
    }

    /// The part of `region` drawn (a window of it when the page is long), in page units.
    private var shown: CGRect {
        guard let c = canvas, region.width > 0 else { return region }
        let h = Double(bounds.height) / Double(bounds.width) * region.width
        if h >= region.height { return region }
        let v = c.camera.visible
        let y = min(max(v.midY - h / 2, region.minY), region.maxY - h)
        return CGRect(x: region.minX, y: y, width: region.width, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let frame = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(white: 1, alpha: 0.92).setFill(); frame.fill()
        guard let c = canvas, let img = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = shown
        ctx.saveGState()
        frame.addClip()
        // The image covers `region`; place it so `shown` fills the bounds.
        let k = r.width / s.width
        let imgRect = CGRect(x: (region.minX - s.minX) * k, y: (region.minY - s.minY) * k, width: region.width * k, height: region.height * k)
        ctx.draw(img, in: imgRect)
        let v = c.camera.visible
        let vr = CGRect(x: (v.minX - s.minX) * k, y: (v.minY - s.minY) * k, width: v.width * k, height: v.height * k)
        NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 0.14).setFill(); NSBezierPath(rect: vr).fill()
        NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 0.9).setStroke()
        let p = NSBezierPath(rect: vr.insetBy(dx: 0.75, dy: 0.75)); p.lineWidth = 1.5; p.stroke()
        ctx.restoreGState()
        NSColor(white: 0, alpha: 0.18).setStroke(); frame.lineWidth = 1; frame.stroke()
    }

    /// Page point under a point in the map.
    func pagePoint(_ p: CGPoint) -> CGPoint {
        let s = shown, k = s.width / bounds.width
        return CGPoint(x: s.minX + p.x * k, y: s.minY + p.y * k)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    private func move(_ e: NSEvent) {
        guard let c = canvas, !c.drawMode else { return }
        c.centerView(on: pagePoint(convert(e.locationInWindow, from: nil)), src: "pageMap")
        needsDisplay = true
    }
}
