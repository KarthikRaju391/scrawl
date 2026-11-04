// Writing mode layout: no sideways pan, and the new line.
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
    func layout(width: Double = 1.0) -> WritingLayout { var l = WritingLayout(); l.lineWidth = width; return l }
    func after(_ l: WritingLayout, lineLeft: Double = 50) -> WritingLayout.Move { l.after(stroke: last, line: line, lineStrokes: strokes, lineLeft: lineLeft, visible: v, pageWidth: pageW) }
    // No sideways pan (Karthik, 28 Oct): ink at 90% of the view, far from the line's limit, moves nothing.
    check(after(layout()) == .none, "no sideways pan: the line's ink at 90% of the view, short of the limit, moves nothing")
    // Line breaks are decided before a word starts, and written ink never moves (Move has no case that moves ink).
    // The words here are 3 letters of 20 with 4 between, 36 apart: a typical word is 68 wide, a word space 36.
    do {
        let a = "writing"
        var l = layout(width: 0.5)
        // A word that started before the limit and ran past it: the line breaks after it (a new line, nothing moved).
        l.lineWidth = (last.maxX - 1) / pageW
        if case .newLine(let c) = after(l) {
            var m = cam; m.center = c; m.clamp()
            check(abs(m.visible.minX - (50 - v.width * 0.05)) < 1e-6 && c.y < line.minY, "\(a): a word that ran past the limit stays; the line breaks after it")
        } else { check(false, "\(a): expected a new line after the word that ran past the limit") }
        // Room left for less than 80% of a typical word after a space: break now, before the next word starts.
        l.lineWidth = (last.maxX + 36 + 68 * 0.8 - 5) / pageW
        check(after(l) == .none, "\(a): no look-ahead (29 Oct): short of the limit the line doesn't break, even if the next word wouldn't fit")
        // A pause inside a word near the limit (the last 'word' is only a letter so far): no break yet.
        var partial = strokes.dropLast(2).map { $0 }
        let lp = partial.last!, lineP = partial.reduce(CGRect.null) { $0.union($1) }
        check(WritingLayout.lastWordUnfinished(partial, line: lineP, visible: v, hint: nil) && !WritingLayout.lastWordUnfinished(strokes, line: line, visible: v, hint: nil),
              "\(a): a word cut short by a pause looks unfinished (the break waits for a longer pause); a whole word doesn't")
        _ = lp
        partial = []
        // Room for it: no break.
        l.lineWidth = (last.maxX + 36 + 68 * 0.8 + 5) / pageW
        if case .newLine = after(l) { check(false, "\(a): the next word fits: no new line yet") } else { check(true, "\(a): the next word fits: no new line yet") }
    }
    // Full width at the page's right end: no new line until the line reaches the page margin (it came early,
    // at 70% of the view, once the view reached the page's end: the parked pan bug).
    var endCam = Camera(page: page); endCam.zoom = 3; endCam.home(); endCam.center.x = pageW - endCam.visible.width / 2
    let ev = endCam.visible
    let s = CGRect(x: ev.minX + ev.width * 0.7, y: 800, width: ev.width * 0.08, height: 30)
    check(layout().after(stroke: s, line: s, lineStrokes: [s], lineLeft: 50, visible: ev, pageWidth: pageW) == .none,
          "full width at the page's end: ink at 78% of the view, short of the margin: no new line yet")
    let s2 = CGRect(x: pageW * 0.9, y: 800, width: pageW * 0.08, height: 30)
    if case .newLine = layout().after(stroke: s2, line: s2, lineStrokes: [s2], lineLeft: 50, visible: ev, pageWidth: pageW) {
        check(true, "full width at the page's end: reaching the page margin starts the next line")
    } else { check(false, "full width at the page's end: expected a new line at the margin") }
    // A deliberate hand pan moved the line's start: the line ends half a page after it, not at the page's edge
    // and not half a page after the left margin.
    var moved = layout(width: 0.5); moved.segmentStart = pageW * 0.3
    let within = CGRect(x: pageW * 0.75, y: 800, width: 20, height: 30), beyond = CGRect(x: pageW * 0.79, y: 800, width: 20, height: 30)
    let noWrap: Bool = { if case .newLine = moved.after(stroke: within, line: within, lineStrokes: [within], lineLeft: 50, visible: ev, pageWidth: pageW) { return false }; return true }()
    let wraps: Bool = { if case .newLine = moved.after(stroke: beyond, line: beyond, lineStrokes: [beyond], lineLeft: 50, visible: ev, pageWidth: pageW) { return true }; return false }()
    let crossing: Bool = { if case .newLine = moved.after(stroke: beyond, line: beyond, lineStrokes: [beyond], lineLeft: 50, visible: ev, pageWidth: pageW) { return true }; return false }()
    check(noWrap && wraps && crossing, "a line moved to 30% of the page by a hand pan ends at 80% (½ page later): no new line at 77%, a new line at 81%")
    // A new line sits 57.5% down the view, so the lines above stay in sight.
    let nc = WritingLayout.newLineCenter(lineLeft: 50, lineMidY: 800, pitch: 40, visible: v)
    var nm = cam; nm.center = nc
    let fromTop = (nm.visible.maxY - 760) / nm.visible.height
    check(abs(fromTop - 0.575) < 1e-9, String(format: "new line: the next line sits %.3f of the way down the view", fromTop))

    blockWidthChecks(check)
}

/// 0.1.6, the infinite canvas: a block's lines are the width setting of the view's width when it started (`blockWidth`),
/// from its start, with no page-edge cap and no 93% zone; the view follows a line longer than itself.
func blockWidthChecks(_ check: (Bool, String) -> Void) {
    let pageW = 1600.0
    func L(_ start: Double, _ bw: Double, width: Double = 1) -> WritingLayout { var l = WritingLayout(); l.lineWidth = width; l.segmentStart = start; l.blockWidth = bw; return l }
    func ink(_ x0: Double, _ x1: Double, y: Double = 500) -> CGRect { CGRect(x: x0, y: y, width: x1 - x0, height: 30) }
    func kind(_ m: WritingLayout.Move) -> String { m.kind }
    // At zoom 3 a 100% block from 1200 is 533 long: its end at 1733, past the page's edge (no 95% cap).
    let v3 = CGRect(x: 1150, y: 300, width: 1600.0 / 3, height: 984.6 / 3)
    let l = L(1200, 1600.0 / 3)
    check(abs(l.lineEnd(lineLeft: 1200, pageWidth: pageW) - (1200 + 1600.0 / 3)) < 1e-9, "a block's line ends at its start + its width (1200 + 533 = 1733), past the page's edge: no 95% cap")
    // Ink at 94% of the page (the old 93% near-edge zone) is no line end any more; only ink near the block's own end is.
    let at94 = ink(1450, 0.94 * pageW)
    check(kind(l.after(stroke: at94, line: at94, lineStrokes: [at94], lineLeft: 1200, visible: CGRect(x: 1150, y: 300, width: 1600, height: 984.6), pageWidth: pageW)) == "none",
          "ink at 94% of the page, well before the block's end: no next line (the 93% rule is gone)")
    let near = ink(1450, 1733 - 0.02 * 533), short = ink(1450, 1733 - 0.04 * 533)
    let wide = CGRect(x: 1100, y: 300, width: 1000, height: 600)   // a view the line fits in: no follow either
    check(kind(l.after(stroke: near, line: near, lineStrokes: [near], lineLeft: 1200, visible: wide, pageWidth: pageW)) == "newLine"
          && kind(l.after(stroke: short, line: short, lineStrokes: [short], lineLeft: 1200, visible: wide, pageWidth: pageW)) == "none",
          "ink within 3% of the block's line before its end: the next line; 4% before it: none")
    // The block's width doesn't depend on the zoom now: the same layout at zoom 1 and zoom 6 gives the same end.
    check(L(300, 800).lineEnd(lineLeft: 300, pageWidth: pageW) == 1100, "the end depends only on the block (its start and its width), not on the view now")
    // A line longer than the view: the view follows once the ink is within 12% of its right side, to put the ink's end in the
    // middle, and never past the line's end + 5% of the view.
    let v = CGRect(x: 1000, y: 300, width: 400, height: 246)
    let lf = L(1050, 1200)   // ends at 2250
    let mid = ink(1060, 1300), edgeInk = ink(1060, 1360)
    check(kind(lf.after(stroke: mid, line: mid, lineStrokes: [mid], lineLeft: 1050, visible: v, pageWidth: pageW)) == "none", "ink at 75% of the view: no follow yet")
    if case .follow(let c) = lf.after(stroke: edgeInk, line: edgeInk, lineStrokes: [edgeInk], lineLeft: 1050, visible: v, pageWidth: pageW) {
        check(abs(c.x - (1360 - 0.5 * 400 + 200)) < 1e-9 && abs(c.y - v.midY) < 1e-9, "ink within 12% of the view's right side: the view follows, the ink's end to its middle, at the same height (centre x \(c.x))")
    } else { check(false, "ink within 12% of the view's right side: expected a follow") }
    let lshort = L(1050, 360)   // ends at 1410: the view goes no further than 1410 + 5% of it
    let e2 = ink(1060, 1365)
    let m2 = lshort.after(stroke: e2, line: e2, lineStrokes: [e2], lineLeft: 1050, visible: v, pageWidth: pageW)
    if case .follow(let c) = m2 { check(c.x + 200 <= 1410 + 20 + 1e-9, "the view never follows past the line's end + 5% of it (right edge \(c.x + 200))") }
    else { check(kind(m2) != "follow", "near its end the line's next line or nothing, never a follow past it (\(kind(m2)))") }
    // Next line: back to the block's start, which may be left of the page (negative): not clamped to the page's edge.
    let nc = WritingLayout.newLineCenter(lineLeft: -300, lineMidY: 500, pitch: 40, visible: v, bounded: false)
    check(abs(nc.x - (-300 - 0.05 * 400 + 200)) < 1e-9, "the next line goes back to a block start left of the page (x -300), not to the page's edge")
    // Before 0.1.6 (no blockWidth): the 95% cap and the 93% zone as they were.
    var old = WritingLayout(); old.lineWidth = 1; old.segmentStart = 1200
    check(abs(old.lineEnd(lineLeft: 1200, pageWidth: pageW) - 0.95 * pageW) < 1e-9 && kind(old.after(stroke: at94, line: at94, lineStrokes: [at94], lineLeft: 1200, visible: v3, pageWidth: pageW)) == "newLine",
          "--column-bound (no blockWidth): the old rules stand (end at 95% of the page, ink at 94% is a line end)")
}
