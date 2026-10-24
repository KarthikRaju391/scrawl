// Keep-centred writing layout (pans after a stroke reaches the view's right edge).
import CoreGraphics
import Foundation
// Writing layout: pan along a line, new line at the chosen width; infinite page downwards.

func centredChecks(_ check: (Bool, String) -> Void) {
    let pageW = 1600.0, page = CGSize(width: pageW, height: 985)
    var L = WritingLayout(); L.lineWidth = 1.0
    for zoom in [1.5, 3.0, 8.0] {
        var cam = Camera(page: page); cam.zoom = zoom; cam.home()
        let v = cam.visible
        let line = CGRect(x: v.minX + 10, y: v.midY - 10, width: v.width * 0.6, height: 20)
        let mid = CGRect(x: v.minX + v.width * 0.5, y: v.midY, width: v.width * 0.2, height: 10)   // ends at 70%
        let edge = CGRect(x: v.minX + v.width * 0.7, y: v.midY, width: v.width * 0.2, height: 10)  // ends at 90%
        let none = L.after(stroke: mid, line: line, lineLeft: v.minX + 10, visible: v, pageWidth: pageW) == .none
        if case .pan(let c) = L.after(stroke: edge, line: line.union(edge), lineLeft: v.minX + 10, visible: v, pageWidth: pageW) {
            var moved = cam; moved.center = c
            let endX = (edge.maxX - moved.visible.minX) / moved.visible.width
            check(none && abs(endX - 0.5) < 1e-9 && c.y == v.midY, String(format: "zoom %.1f: stroke ending at 70%% stays; at 90%% pans so it ends at %.2f of the view", zoom, endX))
        } else { check(false, "zoom \(zoom): expected a pan at the edge") }
    }
    // New line once the line reaches its width (½ page): back to the line's left edge, one line down.
    var half = WritingLayout(); half.lineWidth = 0.5
    var cam = Camera(page: page); cam.zoom = 3; cam.home()
    let v = cam.visible, left = 100.0
    let line = CGRect(x: left, y: 800, width: 690, height: 40)
    let crossing = CGRect(x: 860, y: 800, width: 50, height: 40)   // ends at 910, past left + 800 = 900
    if case .newLine(let c) = half.after(stroke: crossing, line: line.union(crossing), lineLeft: left, visible: v, pageWidth: pageW) {
        var moved = cam; moved.center = c; moved.clamp()
        let mv = moved.visible
        check(abs(mv.minX - max(left - v.width * 0.05, 0)) < 1e-6 && abs(c.y - (line.midY - max(line.height * 1.35, v.height * 0.12))) < 1e-6,
              String(format: "½-page line reaching its width: new line at the line's left edge (view starts %.0f, line starts %.0f), %.0f units lower", mv.minX, left, line.midY - c.y))
    } else { check(false, "½-page line reaching its width: expected a new line") }
    var full = WritingLayout(); full.lineWidth = 1.0
    check(full.after(stroke: crossing, line: line.union(crossing), lineLeft: left, visible: v, pageWidth: pageW) != .newLine(.zero) &&
          !({ if case .newLine = full.after(stroke: crossing, line: line.union(crossing), lineLeft: left, visible: v, pageWidth: pageW) { return true }; return false }()),
          "full-width line: the same stroke doesn't wrap")
    // Panning near the line's end still brings the stroke to mid-screen (writing stays mid-pad).
    var cam2 = Camera(page: page); cam2.zoom = 3; cam2.home(); cam2.center.x += 300
    let v2 = cam2.visible
    let nearEnd = CGRect(x: v2.minX + v2.width * 0.8, y: 800, width: v2.width * 0.1, height: 20)
    var three = WritingLayout(); three.lineWidth = 0.75
    if case .pan(let c) = three.after(stroke: nearEnd, line: nearEnd, lineLeft: 100, visible: v2, pageWidth: pageW) {
        var moved = cam2; moved.center = c
        let endX = (nearEnd.maxX - moved.visible.minX) / moved.visible.width
        check(abs(endX - 0.5) < 1e-9, String(format: "near the line's end the stroke still lands mid-screen (%.2f)", endX))
    } else { check(false, "near the line end: expected a pan") }
    // Infinite page: the camera can go any distance down, never above the top.
    var c3 = Camera(page: page); c3.zoom = 2; c3.center = CGPoint(x: 400, y: -50_000); c3.clamp()
    var c4 = Camera(page: page); c4.zoom = 2; c4.center = CGPoint(x: 400, y: 50_000); c4.clamp()
    check(c3.center.y == -50_000 && c4.visible.maxY == page.height, "page is infinite downwards and stops at its top edge")
}
