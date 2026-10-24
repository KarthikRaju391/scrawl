// Auto-pan: a stroke reaching the right edge of the view pans it so the stroke ends mid-screen.
import CoreGraphics
import Foundation

func writingChecks(_ check: (Bool, String) -> Void) {
    let g = AutoPan()
    let page = CGSize(width: 1600, height: 985)
    for zoom in [1.5, 3.0, 8.0] {
        var cam = Camera(page: page); cam.zoom = zoom; cam.center = CGPoint(x: cam.visible.width / 2 + 10, y: page.height / 2)
        let v = cam.visible
        let mid = CGRect(x: v.minX + v.width * 0.5, y: v.midY, width: v.width * 0.2, height: 10)  // ends at 70%
        let edge = CGRect(x: v.minX + v.width * 0.7, y: v.midY, width: v.width * 0.2, height: 10) // ends at 90%
        let none = g.afterStroke(mid, visible: v, page: page) == nil
        if let c = g.afterStroke(edge, visible: v, page: page) {
            var moved = cam; moved.center = c
            let endX = (edge.maxX - moved.visible.minX) / moved.visible.width
            check(none && abs(endX - 0.5) < 1e-9 && c.y == v.midY,
                  String(format: "zoom %.1f: stroke ending at 70%% doesn't pan; at 90%% pans so it ends at %.2f of the view (vertical unchanged)", zoom, endX))
        } else { check(false, "zoom \(zoom): stroke at the edge should pan") }
    }
    var whole = Camera(page: page)   // zoom 1: the whole page is visible, nothing to pan to
    let e = CGRect(x: page.width * 0.9, y: 400, width: 50, height: 10)
    check(g.afterStroke(e, visible: whole.visible, page: page) == nil, "zoom 1 (whole page visible): no pan")
    whole.zoom = 3; whole.center = CGPoint(x: page.width - whole.visible.width / 2, y: page.height / 2)
    check(g.afterStroke(CGRect(x: page.width - 60, y: 400, width: 50, height: 10), visible: whole.visible, page: page) == nil,
          "at the page's right end: no pan")
}
