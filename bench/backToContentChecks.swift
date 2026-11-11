// ⌘0 (Actual Size) and ⇧⌘0 / the pill (Back to Content) on the real CanvasView (0.1.7.1, Karthik: "set the zoom and position
// so that all the page's content fits in the view"). Expected values are worked out here from the window's geometry, not
// from the app's own helpers; the app is driven only through backToContent(), backToContentWanted(showing:) and
// bottomInsetPt (the toolbar's strip), so the same checks run against v0.1.7's Back to Page through a 3-line shim.
import AppKit

func backToContentChecks(_ check: (Bool, String) -> Void) {
    let W = wPage.width, top = wPage.height
    var drivers: [WReal] = []
    let margin = 0.07, toolbarPt: CGFloat = 60
    func place(_ c: CanvasView, _ p: CGPoint, zoom: Double? = nil) {
        var cam = c.camera; if let zoom { cam.zoom = zoom }; cam.center = p; cam.clamp(); let v = cam.visible
        c.setVisibleForReplay(x: v.minX, y: v.minY, w: v.width, z: cam.zoom)
    }
    func canvas(zoom: Double, center: CGPoint, draw: Bool = false) -> CanvasView {
        let r = WReal(waitMs: 400, widthIdx: 0, zoom: zoom, viewX: 0)
        drivers.append(r)   // the canvas's clock is the driver's (unowned): keep it
        let c = r.canvas
        c.writingMode = false; c.drawMode = draw; c.bottomInsetPt = toolbarPt
        place(c, center, zoom: zoom)
        return c
    }
    /// Ink: a horizontal wiggle from (x0, y) to (x1, y), `n` points.
    func ink(_ c: CanvasView, _ x0: Double, _ x1: Double, _ y: Double, n: Int = 40) {
        c.testAddStroke((0..<n).map { k in StrokePoint(p: CGPoint(x: x0 + (x1 - x0) * Double(k) / Double(n - 1), y: y + 8 * sin(Double(k))), pressure: 0.6) })
    }
    func box(_ c: CanvasView) -> CGRect { let rs = c.doc.strokes.map(\.bounds); return rs.dropFirst().reduce(rs[0]) { $0.union($1) } }
    /// The window (page units) and the free part of it: 7% margins, above the toolbar's strip.
    func free(_ c: CanvasView) -> (window: CGRect, free: CGRect) {
        let s = c.renderRect(for: c.camera), k = s.width / Double(c.bounds.width)
        let f = CGRect(x: s.minX + margin * s.width, y: s.minY + Double(toolbarPt) * k + margin * s.height,
                       width: s.width * (1 - 2 * margin), height: s.height * (1 - 2 * margin) - Double(toolbarPt) * k)
        return (s, f)
    }
    /// The zoom that fits `b` in the free area, worked out from the window's points (25-100%).
    func wantZoom(_ c: CanvasView, _ b: CGRect) -> Double {
        let pw = W / Double(c.padRect.width)   // page units per view point at 100%
        let fw = Double(c.bounds.width) * (1 - 2 * margin), fh = Double(c.bounds.height) * (1 - 2 * margin) - Double(toolbarPt)
        return min(max(min(pw * fw / b.width, pw * fh / b.height), 0.25), 1)
    }
    func fits(_ c: CanvasView, _ b: CGRect, tol: Double = 1) -> Bool { free(c).free.insetBy(dx: -tol, dy: -tol).contains(b) }

    // Fit from far away at 25%, 100% and 400%: all the content in the free area, the zoom the fit zoom.
    var bad: [String] = []
    for z in [0.25, 1.0, 4.0] {
        for (name, p) in [("far left", CGPoint(x: -2800, y: 300)), ("far right above", CGPoint(x: W + 2500, y: top + 1800)), ("far below", CGPoint(x: 800, y: -9000))] {
            let c = canvas(zoom: z, center: p)
            ink(c, 200, 1300, 700); ink(c, 200, 1100, 500); ink(c, 250, 900, 300)   // a page's worth of lines
            c.backToContent(); c.flushInputForTest()
            let b = box(c), wz = wantZoom(c, b)
            if abs(c.camera.zoom / wz - 1) > 1e-3 || !fits(c, b) { bad.append(String(format: "%.0f%% %@: zoom %.3f (want %.3f), content %@ free %@", z * 100, name, c.camera.zoom, wz, "\(b.integral)", "\(free(c).free.integral)")) }
        }
    }
    check(bad.isEmpty, "Back to Content: from far left / right-above / below at 25, 100 and 400%, all the page's ink fits the window (7% margins, above the toolbar) at the fit zoom \(bad.prefix(2))")

    // Spread wide: 3 page widths fits (the zoom just below what fits); 5 page widths: as far out as the canvas goes (25%),
    // centred on it (it can't fit with margins: the window is 4 page widths at 25%).
    do {
        let c = canvas(zoom: 1, center: CGPoint(x: 800, y: 500))
        ink(c, -1600, -1200, 600); ink(c, 2800, 3200, 400)   // 4,800 units
        c.backToContent(); c.flushInputForTest()
        let b = box(c), wz = wantZoom(c, b)
        let d = canvas(zoom: 1, center: CGPoint(x: 800, y: 500))
        ink(d, -3000, -2600, 600); ink(d, 4600, 5000, 400)   // 8,000 units: 5 page widths
        d.backToContent(); d.flushInputForTest()
        let bd = box(d), fd = free(d)
        check(abs(c.camera.zoom / wz - 1) < 1e-3 && wz > 0.25 && fits(c, b) && abs(d.camera.zoom - 0.25) < 1e-9 && abs(fd.free.midX - bd.midX) < 1,
              String(format: "Back to Content, spread wide: 3 page widths fit at %.1f%% (want %.1f%%, fits %@: content %@, free %@); 5 page widths go to 25%% (%.0f%%), centred on the content (free middle %.0f, content middle %.0f)",
                     c.camera.zoom * 100, wz * 100, fits(c, b) ? "yes" : "NO", "\(b.integral)", "\(free(c).free.integral)", d.camera.zoom * 100, fd.free.midX, bd.midX))
    }

    // One word: 100%, not 800%; centred in the free area.
    do {
        let c = canvas(zoom: 4, center: CGPoint(x: -2000, y: top + 1000))
        ink(c, 600, 660, 500, n: 12)
        c.backToContent(); c.flushInputForTest()
        let b = box(c), f = free(c).free
        check(abs(c.camera.zoom - 1) < 1e-9 && fits(c, b) && abs(f.midX - b.midX) < 1 && abs(f.midY - b.midY) < 1,
              String(format: "Back to Content, one word from 400%%: 100%% (%.0f%%), the word in the middle of the free area (off by %.1f, %.1f)", c.camera.zoom * 100, f.midX - b.midX, f.midY - b.midY))
    }

    // An empty page: its top at 100%, as a new page opens.
    do {
        let c = canvas(zoom: 3, center: CGPoint(x: -2500, y: -4000))
        c.backToContent(); c.flushInputForTest()
        var home = Camera(page: wPage); home.home()
        check(abs(c.camera.zoom - 1) < 1e-9 && hypot(c.camera.center.x - home.center.x, c.camera.center.y - home.center.y) < 1e-6,
              String(format: "Back to Content on an empty page (from 300%%, far off): its top at 100%% (zoom %.0f%%, centre %.0f,%.0f; a new page's %.0f,%.0f)", c.camera.zoom * 100, c.camera.center.x, c.camera.center.y, home.center.x, home.center.y))
    }

    // Zoom locked: the content centred at this zoom, no zoom change.
    do {
        let c = canvas(zoom: 3, center: CGPoint(x: -2500, y: 300))
        ink(c, 200, 1300, 700); ink(c, 200, 1100, 500)
        var t = c.tools; t.zoomLocked = true; c.tools = t
        c.backToContent(); c.flushInputForTest()
        let b = box(c), f = free(c).free
        check(abs(c.camera.zoom - 3) < 1e-9 && abs(f.midX - b.midX) < 1 && abs(f.midY - b.midY) < 1,
              String(format: "Back to Content with the zoom locked: 300%% kept (%.0f%%), the content centred (off by %.1f, %.1f)", c.camera.zoom * 100, f.midX - b.midX, f.midY - b.midY))
        t.zoomLocked = false; c.tools = t   // (saved to the bench's own defaults otherwise)
    }

    // ⌘0 (Actual Size) is unchanged: 100% about the same centre, off the page too.
    bad = []
    for z in [0.25, 0.6, 2.5, 4.0] {
        let c = canvas(zoom: z, center: CGPoint(x: -2400, y: top + 900)), c0 = c.camera.center
        c.resetZoom(); c.flushInputForTest()
        if abs(c.camera.zoom - 1) > 1e-9 || hypot(c.camera.center.x - c0.x, c.camera.center.y - c0.y) > 1e-6 { bad.append("\(z)") }
    }
    check(bad.isEmpty, "⌘0 (Actual Size): from 25/60/250/400% off the page, 100% about the same centre \(bad)")

    // The pill: shown when less than 60% of the content is in the window or its centre is 20% of its width off the
    // content, hidden only at 75% / 10% (hysteresis). Measured here from the window and the content box.
    func seen(_ c: CanvasView) -> (Double, Double) {
        let s = free(c).window, b = box(c).insetBy(dx: -1, dy: -1), i = b.intersection(s)
        let v = i.isNull ? 0 : Double(i.width * i.height) / min(Double(b.width * b.height), Double(s.width * s.height))
        let dx = max(b.minX - s.midX, 0, s.midX - b.maxX), dy = max(b.minY - s.midY, 0, s.midY - b.maxY)
        return (min(v, 1), hypot(dx, dy) / s.width)
    }
    for z in [0.5, 1.0] {
        let c = canvas(zoom: z, center: CGPoint(x: 800, y: 600))
        ink(c, 300, 1300, 700); ink(c, 300, 1300, 400)
        let b = box(c), s0 = free(c).window
        // Pan right from the content's middle: the window's left edge crosses the content's right part.
        var shown = false, flips = 0, trace: [String] = [], sweep: [Double] = []
        for k in 0...40 { sweep.append(Double(k) * 0.025) }               // window centre: content middle + k x 2.5% of the window
        sweep += [0.70, 0.66, 0.70, 0.66, 0.60, 0.55, 0.5, 0.45, 0.40, 0.30, 0.2, 0.1, 0.0]
        var okTransitions = true
        for f in sweep {
            place(c, CGPoint(x: b.midX + f * s0.width, y: c.camera.center.y))
            let w = c.backToContentWanted(showing: shown), (v, o) = seen(c)
            if w != shown {
                flips += 1; trace.append(String(format: "%@ at %.0f%% seen, %.2f off", w ? "show" : "hide", v * 100, o))
                if w && !(v < 0.6 + 1e-6 || o > 0.2 - 1e-6) { okTransitions = false }
                if !w && !(v >= 0.75 - 1e-6 && o <= 0.1 + 1e-6) { okTransitions = false }
            } else if !shown && (v < 0.6 - 0.02 || o > 0.2 + 0.02) { okTransitions = false }   // should have shown by now
            shown = w
        }
        // Zoomed in on the content (bigger than the window): no pill.
        place(c, CGPoint(x: b.midX, y: b.midY), zoom: 4)
        let zoomedIn = !c.backToContentWanted(showing: false)
        check(okTransitions && flips == 2 && zoomedIn,
              String(format: "Back to Content pill at %.0f%%: shows below 60%% seen or 20%% off, hides only at 75%% / 10%% (%@; %d changes through a wobble); zoomed in on the content: %@",
                     z * 100, trace.joined(separator: "; "), flips, zoomedIn ? "no pill" : "PILL"))
    }
    // An empty page: no pill at its top; one once panned well away.
    do {
        let c = canvas(zoom: 1, center: CGPoint(x: 800, y: 500))
        var home = c.camera; home.home(); place(c, home.center)
        let atTop = c.backToContentWanted(showing: false)
        place(c, CGPoint(x: home.center.x + 2400, y: home.center.y))
        let away = c.backToContentWanted(showing: false)
        check(!atTop && away, "Back to Content pill on an empty page: none at its top (\(atTop)), shown once panned 1.5 page widths away (\(away))")
    }
    // The pill is decided on every view change (each frame of a pan or a transition): cheap on a full page.
    do {
        let c = canvas(zoom: 1, center: CGPoint(x: 800, y: 500))
        for k in 0..<2500 { ink(c, Double(k % 50) * 30, Double(k % 50) * 30 + 25, 900 - Double(k / 50) * 15, n: 30) }
        let t0 = CFAbsoluteTimeGetCurrent()
        var n = 0
        for k in 0..<200 { place(c, CGPoint(x: 800 + Double(k) * 20, y: 500)); if c.backToContentWanted(showing: k % 2 == 0) { n += 1 } }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 200
        check(ms < 1, String(format: "Back to Content pill: deciding it on a 2,500-stroke page takes %.3f ms a view change (bar 1 ms; a frame is 8-16 ms)", ms))
    }
    // Never in draw mode.
    let d = canvas(zoom: 1, center: CGPoint(x: -3000, y: top + 2000), draw: true)
    ink(d, 300, 1300, 700)
    check(!d.backToContentWanted(showing: false) && !d.backToContentWanted(showing: true), "Back to Content pill: never in draw mode (content 2 page widths away)")
}
