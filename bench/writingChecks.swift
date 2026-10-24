// Writing guide: the page advances so you keep writing at the same pad spot.
import CoreGraphics
import Foundation

func writingChecks(_ check: (Bool, String) -> Void) {
    let g = WritingGuide()
    let page = CGSize(width: 1600, height: 985)
    var cam = Camera(page: page); cam.zoom = 3
    cam.center = CGPoint(x: cam.visible.width / 2, y: page.height - cam.visible.height / 2)
    let v = cam.visible

    // Ink only to 40% of the view: no move; caret just right of the ink.
    let short = CGRect(x: v.minX + v.width * 0.25, y: v.midY - 20, width: v.width * 0.15, height: 40)
    check(g.afterPause(lineInk: short, visible: v, page: page) == .none, "ink at 40% of the view: page stays put")
    let c0 = g.caret(lineInk: short, visible: v, page: page)
    check(c0.minX > short.maxX && c0.minX < short.maxX + v.width * 0.1, "caret sits just right of the ink")

    // Ink to 65%: advance so the caret lands at continueAt (30%) of the view = same pad spot.
    let long = CGRect(x: v.minX + v.width * 0.25, y: v.midY - 20, width: v.width * 0.40, height: 40)
    if case .advance(let c) = g.afterPause(lineInk: long, visible: v, page: page) {
        var moved = cam; moved.center = c
        let caret = g.caret(lineInk: long, visible: moved.visible, page: page)
        let padX = (caret.minX - moved.visible.minX) / moved.visible.width
        check(abs(padX - g.continueAt) < 0.001, String(format: "after the slide the caret is at %.3f of the pad (target %.2f)", padX, g.continueAt))
    } else { check(false, "ink at 65%: expected the page to advance") }

    // Ink at the page's right margin: wrap to a new line below, left margin in view.
    let edge = CGRect(x: page.width - 200, y: v.midY - 20, width: 170, height: 40)
    if case .wrap(let c) = g.afterPause(lineInk: edge, visible: v, page: page) {
        var moved = Camera(page: page); moved.zoom = 3; moved.center = c; moved.clamp()
        let caret = g.caret(lineInk: nil, visible: moved.visible, page: page)
        check(moved.visible.minX <= page.width * g.margin + 1 && c.y < edge.midY && moved.visible.contains(CGPoint(x: caret.minX, y: caret.midY)),
              String(format: "right margin: wraps to a line %.0f units lower, left margin in view, caret visible", edge.midY - c.y))
    } else { check(false, "ink at the right margin: expected a wrap") }
}
