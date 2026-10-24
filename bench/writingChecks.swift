// Writing mode re-anchoring rules; infinite page.
import CoreGraphics
import Foundation

func writingChecks(_ check: (Bool, String) -> Void) {
    let r = Reanchor()
    let lift = CGPoint(x: 0.82, y: 0.5)
    check(r.isReturn(down: CGPoint(x: 0.20, y: 0.55), lastLift: lift), "touch-down far left of the lift (0.82 -> 0.20) is a return")
    check(!r.isReturn(down: CGPoint(x: 0.75, y: 0.5), lastLift: lift), "touch-down near the lift (0.82 -> 0.75, e.g. a dot) is not a return")
    check(!r.isReturn(down: CGPoint(x: 0.90, y: 0.5), lastLift: lift), "touch-down to the right of the lift is not a return")
    let line = CGRect(x: 100, y: 780, width: 600, height: 40)
    let c = r.continuation(line: line, lineLeft: 100, newLine: false, gap: 12)
    check(c.x == 712 && c.y == line.midY, "continuation is just right of the line's ink, same line")
    let n = r.continuation(line: line, lineLeft: 100, newLine: true, gap: 12)
    check(n.x == 100 && n.y < line.minY, String(format: "after a full line, continuation is the line's left edge, one line down (%.0f units)", line.midY - n.y))
    var half = Reanchor(); half.lineWidth = 0.5
    check(half.lineFull(line: CGRect(x: 100, y: 0, width: 805, height: 10), lineLeft: 100, pageWidth: 1600) &&
          !half.lineFull(line: CGRect(x: 100, y: 0, width: 700, height: 10), lineLeft: 100, pageWidth: 1600), "½-page line is full at 800 units from its left edge")
    let page = CGSize(width: 1600, height: 985)
    var c3 = Camera(page: page); c3.zoom = 2; c3.center = CGPoint(x: 400, y: -50_000); c3.clamp()
    var c4 = Camera(page: page); c4.zoom = 2; c4.center = CGPoint(x: 400, y: 50_000); c4.clamp()
    check(c3.center.y == -50_000 && c4.visible.maxY == page.height, "page is infinite downwards and stops at its top edge")
}
