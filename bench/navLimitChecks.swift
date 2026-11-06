// Outside draw mode the trackpad's pinch (NSEvent magnify) and two-finger scroll move the same camera as draw mode's
// pinches and pans: the same zoom floor (25% on the infinite canvas) and the same reach past the page's sides and top.
// Karthik (6 Nov): outside draw mode he couldn't zoom below 100% (magnify clamped to 1).
import AppKit

func navLimitChecks(_ check: (Bool, String) -> Void) {
    // Draw mode: pinch out and pan as far as it goes, through the real touch path.
    let d = WReal(waitMs: 400, widthIdx: 0, zoom: 1, viewX: 0)
    d.canvas.writingMode = false
    for _ in 0..<12 { _ = d.apply(.pinch(0.5), place: nil) }
    let drawZoom = d.canvas.camera.zoom
    func extent(_ move: (Double, Double) -> Void, _ cam: () -> Camera) -> (minX: Double, maxX: Double, maxY: Double) {
        for _ in 0..<40 { move(-1, 0) }; let a = cam().center.x
        for _ in 0..<80 { move(1, 0) }; let b = cam().center.x
        for _ in 0..<40 { move(0, 1) }; let c = cam().center.y
        return (a, b, c)
    }
    let drawExt = extent({ d.panBy($0, $1) }, { d.canvas.camera })

    // Outside draw mode: magnify (pinch) and scroll.
    let n = WReal(waitMs: 400, widthIdx: 0, zoom: 1, viewX: 0)
    n.canvas.writingMode = false; n.canvas.drawMode = false
    let mid = CGPoint(x: n.canvas.bounds.midX, y: n.canvas.bounds.midY)
    for k in 0..<12 { n.canvas.magnifyBy(-0.5, at: mid, ended: k == 11) }
    let normalZoom = n.canvas.camera.zoom
    func scroll(_ fx: Double, _ fy: Double) {
        let c = n.canvas, k = 1 / (c.ptPerUnit * c.camera.zoom), v = c.camera.visible
        // scrollingDeltaX > 0 moves the view left: a move right (+fx) is a negative delta; up (+fy) a positive deltaY.
        let dx = -fx * v.width / k, dy = fy * v.height / k
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0),
           let ev = NSEvent(cgEvent: cg) { c.scrollWheel(with: ev) }
    }
    let normalExt = extent(scroll, { n.canvas.camera })

    let floor = Camera(page: wPage).minZoom
    check(abs(drawZoom - floor) < 1e-9 && abs(normalZoom - floor) < 1e-9,
          String(format: "navigation: pinching out reaches %.0f%% in draw mode (%.0f%%) and outside it (magnify, %.0f%%)", floor * 100, drawZoom * 100, normalZoom * 100))
    // Compare at the same zoom (both at the floor).
    let same = abs(drawExt.minX - normalExt.minX) < 1 && abs(drawExt.maxX - normalExt.maxX) < 1 && abs(drawExt.maxY - normalExt.maxY) < 1
    let r = Camera.reach * wPage.width
    check(same && abs(drawExt.minX - -r) < 1 && abs(drawExt.maxX - (wPage.width + r)) < 1,
          String(format: "navigation: at %.0f%%, scrolling outside draw mode reaches the same place as draw mode's pans: view centre x %.0f..%.0f, top %.0f (draw mode %.0f..%.0f, top %.0f; reach 2 page widths)",
                 normalZoom * 100, normalExt.minX, normalExt.maxX, normalExt.maxY, drawExt.minX, drawExt.maxX, drawExt.maxY))
}
