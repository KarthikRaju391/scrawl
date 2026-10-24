// Writing mode layout: auto-pan off / centre / left, and the new line.
import CoreGraphics
import Foundation

func writingLayoutChecks(_ check: (Bool, String) -> Void) {
    let pageW = 1600.0, page = CGSize(width: pageW, height: 985)
    var cam = Camera(page: page); cam.zoom = 3; cam.home(); cam.center.x += 200
    let v = cam.visible
    // A line of 3 "words" (letters 20 wide, 4 apart; words 40 apart); the last letter ends at 90% of the view.
    // (The pan trigger is at 70% of the view.)
    var strokes: [CGRect] = []
    var x = v.minX + v.width * 0.9 - (3 * 3 * 20 + 6 * 4 + 2 * 40)
    for _ in 0..<3 { for _ in 0..<3 { strokes.append(CGRect(x: x, y: 800, width: 20, height: 30)); x += 24 }; x += 36 }
    let last = strokes.last!, line = strokes.reduce(CGRect.null) { $0.union($1) }
    let lastWord = strokes[6].minX
    check(abs(WritingLayout.lastWordStart(strokes, gap: 13.5) - lastWord) < 1e-9, "last word found from the gaps between strokes")
    func layout(_ a: AutoPan, width: Double = 1.0) -> WritingLayout { var l = WritingLayout(); l.autoPan = a; l.lineWidth = width; return l }
    func after(_ l: WritingLayout, lineLeft: Double = 50) -> WritingLayout.Move { l.after(stroke: last, line: line, lineStrokes: strokes, lineLeft: lineLeft, visible: v, pageWidth: pageW) }
    if case .pan(let c) = after(layout(.centre)) {
        var m = cam; m.center = c
        check(abs((last.maxX - m.visible.minX) / m.visible.width - 0.5) < 1e-9, "centre: the stroke ends mid-view")
    } else { check(false, "centre: expected a pan") }
    if case .pan(let c) = after(layout(.left)) {
        var m = cam; m.center = c
        let wx = (lastWord - m.visible.minX) / m.visible.width
        check(abs(wx - 0.04) < 1e-9, String(format: "left: the word just written starts at %.2f of the view (left edge)", wx))
    } else { check(false, "left: expected a pan") }
    check(after(layout(.off)) == .none, "no pan: nothing moves at the right edge")
    // New line at the line width, in every mode.
    for a in [AutoPan.off, .centre, .left] {
        var l = layout(a, width: 0.5)
        l.lineWidth = (last.maxX - 50) / pageW   // the line is exactly full
        if case .newLine(let c) = after(l) {
            var m = cam; m.center = c; m.clamp()
            check(abs(m.visible.minX - (50 - v.width * 0.05)) < 1e-6 && c.y < line.minY, "\(a): at the line width, the view goes to the next line's start")
        } else { check(false, "\(a): expected a new line at the line width") }
    }
    // Full width at the page's right end: the view can't pan further, so a new line.
    var endCam = Camera(page: page); endCam.zoom = 3; endCam.home(); endCam.center.x = pageW - endCam.visible.width / 2
    let ev = endCam.visible
    let s = CGRect(x: ev.minX + ev.width * 0.8, y: 800, width: ev.width * 0.08, height: 30)
    if case .newLine = layout(.centre).after(stroke: s, line: s, lineStrokes: [s], lineLeft: 50, visible: ev, pageWidth: pageW) {
        check(true, "full width at the page's end: reaching the view's edge starts the next line")
    } else { check(false, "full width at the page's end: expected a new line") }
}
