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
    // Every pan keeps the last 2-3 words on screen and moves at most half the view.
    func wordsInView(_ m: CGRect) -> Int { WritingLayout.wordStarts(strokes, gap: 13.5).filter { $0 >= m.minX - 1e-9 }.count }
    if case .pan(let c) = after(layout(.centre)) {
        var m = cam; m.center = c
        let endAt = (last.maxX - m.visible.minX) / m.visible.width
        check(endAt <= 0.65 && wordsInView(m.visible) >= 2 && m.visible.minX - v.minX <= v.width * 0.5 + 1e-9,
              String(format: "centre: the line's end at %.2f of the view (near the middle: keeping the last words wins), %d words still in view, jump %.2f of the view", endAt, wordsInView(m.visible), (m.visible.minX - v.minX) / v.width))
    } else { check(false, "centre: expected a pan") }
    if case .pan(let c) = after(layout(.left)) {
        var m = cam; m.center = c
        let keep = WritingLayout.wordStarts(strokes, gap: 13.5)[0]   // these 3 words fit in 60% of the view
        let wx = (keep - m.visible.minX) / m.visible.width
        check(abs(wx - 0.04) < 1e-9 || abs(m.visible.minX - v.minX - v.width * 0.5) < 1e-9,
              String(format: "left: the last three words start at %.2f of the view (left edge), %d words in view", wx, wordsInView(m.visible)))
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
    // Full width at the page's right end: no new line until the line reaches the page margin (it came early,
    // at 70% of the view, once the view reached the page's end: the parked pan bug).
    var endCam = Camera(page: page); endCam.zoom = 3; endCam.home(); endCam.center.x = pageW - endCam.visible.width / 2
    let ev = endCam.visible
    let s = CGRect(x: ev.minX + ev.width * 0.7, y: 800, width: ev.width * 0.08, height: 30)
    check(layout(.centre).after(stroke: s, line: s, lineStrokes: [s], lineLeft: 50, visible: ev, pageWidth: pageW) == .none,
          "full width at the page's end: ink at 78% of the view, short of the margin: no new line yet")
    let s2 = CGRect(x: pageW * 0.9, y: 800, width: pageW * 0.08, height: 30)
    if case .newLine = layout(.centre).after(stroke: s2, line: s2, lineStrokes: [s2], lineLeft: 50, visible: ev, pageWidth: pageW) {
        check(true, "full width at the page's end: reaching the page margin starts the next line")
    } else { check(false, "full width at the page's end: expected a new line at the margin") }
    // Panned right by hand (lineFree): past the line width, no new line until the page margin.
    var free = layout(.centre, width: 0.5); free.lineFree = true
    let past = CGRect(x: pageW * 0.6, y: 800, width: 60, height: 30)
    if case .newLine = free.after(stroke: past, line: past, lineStrokes: [past], lineLeft: 50, visible: ev, pageWidth: pageW) {
        check(false, "after a hand pan right, writing past the ½-page line doesn't jump to a new line")
    } else { check(true, "after a hand pan right, writing past the ½-page line doesn't jump to a new line") }
    // A new line sits 57.5% down the view, so the lines above stay in sight.
    let nc = WritingLayout.newLineCenter(lineLeft: 50, lineMidY: 800, pitch: 40, visible: v)
    var nm = cam; nm.center = nc
    let fromTop = (nm.visible.maxY - 760) / nm.visible.height
    check(abs(fromTop - 0.575) < 1e-9, String(format: "new line: the next line sits %.3f of the way down the view", fromTop))
}
