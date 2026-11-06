// ⌘0 (Actual Size) and ⇧⌘0 / the pill (Back to Page) on the infinite canvas, on the real CanvasView (0.1.7, Karthik).
import AppKit

func backToPageChecks(_ check: (Bool, String) -> Void) {
    let W = wPage.width, top = wPage.height
    var drivers: [WReal] = []
    /// The view's centre at `p` (the zoom kept), clamped as a hand move would be.
    func place(_ c: CanvasView, _ p: CGPoint) {
        var cam = c.camera; cam.center = p; cam.clamp(); let v = cam.visible
        c.setVisibleForReplay(x: v.minX, y: v.minY, w: v.width, z: cam.zoom)
    }
    func canvas(zoom: Double, center: CGPoint, draw: Bool = false) -> CanvasView {
        let r = WReal(waitMs: 400, widthIdx: 0, zoom: zoom, viewX: 0)
        let c = r.canvas
        c.writingMode = false; c.drawMode = draw
        place(c, center)
        drivers.append(r)   // the canvas's clock is the driver's (unowned): keep it
        return c
    }
    let off = [("far left", CGPoint(x: -2400, y: 400)), ("far right", CGPoint(x: W + 2400, y: 400)),
               ("above", CGPoint(x: 800, y: top + 1500)), ("below", CGPoint(x: 800, y: -6000)), ("left and above", CGPoint(x: -1200, y: top + 900))]

    // ⌘0 from 25%, 60%, 250%, 400% off the page: 100%, the same centre (the clamp doesn't pull it back to the column).
    var bad: [String] = []
    for z in [0.25, 0.6, 2.5, 4.0] {
        for (name, p) in off {
            let c = canvas(zoom: z, center: p), c0 = c.camera.center
            c.resetZoom(); c.flushInputForTest()
            if abs(c.camera.zoom - 1) > 1e-9 || hypot(c.camera.center.x - c0.x, c.camera.center.y - c0.y) > 1e-6 { bad.append(String(format: "%.0f%% %@: zoom %.2f centre (%.0f,%.0f) -> (%.0f,%.0f)", z * 100, name, c.camera.zoom, c0.x, c0.y, c.camera.center.x, c.camera.center.y)) }
        }
    }
    check(bad.isEmpty, "⌘0 (Actual Size): from 25/60/250/400% at 5 off-page places, 100% about the same centre \(bad.prefix(3))")
    // Zoom locked: ⌘0 leaves the zoom (a beep), ⇧⌘0 still goes back.
    do {
        let c = canvas(zoom: 2.5, center: CGPoint(x: -2000, y: 300))
        var t = c.tools; t.zoomLocked = true; c.tools = t
        c.resetZoom(); c.backToPage(); c.flushInputForTest()
        check(abs(c.camera.zoom - 2.5) < 1e-9 && abs(c.camera.center.x - W / 2) < 1e-6, "zoom locked: ⌘0 keeps 250%, ⇧⌘0 still centres the page (centre x \(c.camera.center.x))")
        t.zoomLocked = false; c.tools = t   // (saved to the bench's own defaults otherwise)
    }

    // ⇧⌘0 from far left, right, above and below at 25%, 100%, 300%: the column centred, the zoom unchanged; above the page:
    // its top at the view's top; off all content: the nearest content in view.
    bad = []
    for z in [0.25, 1.0, 3.0] {
        for (name, p) in off {
            let c = canvas(zoom: z, center: p)
            c.testAddStroke((0..<30).map { StrokePoint(p: CGPoint(x: 300 + Double($0) * 20, y: top - 200 - sin(Double($0)) * 10), pressure: 0.6) })   // a line near the top
            let z0 = c.camera.zoom
            c.backToPage(); c.flushInputForTest()
            let v = c.camera.visible, ink = c.doc.strokes[0].bounds
            let ok = abs(c.camera.zoom - z0) < 1e-9 && abs(c.camera.center.x - W / 2) < 1e-6 && v.maxY <= top + 1e-6 && v.intersects(ink)
            if !ok { bad.append(String(format: "%.0f%% %@: zoom %.2f, centre x %.0f, view top %.0f (page top %.0f), ink in view %@", z * 100, name, c.camera.zoom, c.camera.center.x, v.maxY, top, v.intersects(ink) ? "yes" : "no")) }
        }
    }
    check(bad.isEmpty, "⇧⌘0 (Back to Page): from far left, right, above, below at 25/100/300%, the column centred, zoom unchanged, never above the page's top, the ink in view \(bad.prefix(3))")
    // Back to page keeps the height when the view is on content: far right at the page's ink, it only slides sideways.
    do {
        let c = canvas(zoom: 1, center: CGPoint(x: W + 2000, y: 300))
        c.testAddStroke((0..<30).map { StrokePoint(p: CGPoint(x: 300 + Double($0) * 20, y: 300 + sin(Double($0)) * 10), pressure: 0.6) })
        let y0 = c.camera.center.y
        c.backToPage(); c.flushInputForTest()
        check(abs(c.camera.center.y - y0) < 1e-6 && abs(c.camera.center.x - W / 2) < 1e-6, "⇧⌘0 beside the page's ink: only sideways (y \(y0) -> \(c.camera.center.y))")
    }

    // The pill's thresholds and hysteresis: shown once the view's centre is more than 20% of its width outside the
    // column (or its top 10% of its height above the page's top); hidden again only within 10% / 5%.
    for z in [0.5, 1.0, 3.0] {
        let c = canvas(zoom: z, center: CGPoint(x: W / 2, y: 300))
        let vw = c.camera.visible.width, vh = c.camera.visible.height
        var shown = false, flips = 0, trace: [String] = []
        func step(_ cx: Double, _ cy: Double) {
            place(c, CGPoint(x: cx, y: cy))
            let w = c.backToPageWanted(showing: shown)
            if w != shown { flips += 1; trace.append(String(format: "%@ at %.3f", w ? "show" : "hide", (W - cx) < 0 ? 0 : (0 - cx) / vw)) }
            shown = w
        }
        // Pan left past the column's left edge to 25% of the view outside it, wobble around 20% and 10%, then come back.
        var offs: [Double] = stride(from: 0.0, through: 0.25, by: 0.01).map { $0 }
        offs += [0.19, 0.21, 0.19, 0.21, 0.15, 0.12, 0.11, 0.12, 0.11, 0.09, 0.11, 0.12, 0.15]
        let y = top - vh / 2   // the view's top at the page's top
        for o in offs { step(-o * vw, y) }
        let leftFlips = flips
        let leftOK = flips == 2 && trace.first?.hasPrefix("show at 0.21") == true && trace.last?.hasPrefix("hide at 0.09") == true
        // Above: the view's top 12% of its height above the page's top shows it; back to 6%: still; 4%: hidden.
        shown = false; flips = 0
        var above: [Bool] = []
        for a in [0.08, 0.12, 0.06, 0.04] { place(c, CGPoint(x: W / 2, y: top + a * vh - vh / 2)); shown = c.backToPageWanted(showing: shown); above.append(shown) }
        // Zoomed in on the page's right half (the view's centre inside the column): never.
        place(c, CGPoint(x: W - 1, y: y))
        let onPage = !c.backToPageWanted(showing: false)
        check(leftOK && above == [false, true, true, false] && onPage,
              String(format: "Back to page pill at %.0f%%: left of the page shown past 20%% of the view, hidden only back within 10%% (%@; %d changes over a wobble at both thresholds); above the top: shown past 10%%, hidden within 5%% (%@); on the page's right edge: %@",
                     z * 100, trace.joined(separator: ", "), leftFlips, above.map { $0 ? "on" : "off" }.joined(separator: " "), onPage ? "not shown" : "SHOWN"))
    }
    // Never in draw mode, however far off.
    let d = canvas(zoom: 1, center: CGPoint(x: -3000, y: top + 2000), draw: true)
    check(!d.backToPageWanted(showing: false) && !d.backToPageWanted(showing: true), "Back to page pill: never in draw mode (view 2 page widths off and above)")
}
