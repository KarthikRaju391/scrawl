// Writing mode's line length on the infinite canvas, driven through the real CanvasView (WReal: its touch entry point on a
// virtual clock). Karthik (6 Nov): "If the writing mode setting is at 50%, that means it should cut off at 50% of the screen
// width from the point where I am writing from. It should not consider the viewport ... calculate the full screen width and
// then take the percentage off of it." The screen's full width is the page's (it fills the window's width at 100%): the
// limit = the block's start + the setting x 1,600 units, at any zoom, wherever the start sits on the screen, through hand
// pans, follows and zooms during the block. (`WritingLayout.measureFromView`: the 0.1.6 drafts' rule, the view's width when
// the block started, checked too so the switch stays honest.)
import AppKit

func lineWidthRuleChecks(_ check: (Bool, String) -> Void) {
    let saved = WritingLayout.measureFromView
    defer { WritingLayout.measureFromView = saved }
    let W = wPage.width, settings = ToolState.lineWidths   // 0.5, 0.75, 1.0

    /// A fresh canvas at `zoom`, the view's left edge at page x `viewLeft`, writing mode on, width setting `wi`.
    func canvasAt(zoom: Double, viewLeft: Double, wi: Int = 0) -> WReal {
        let r = WReal(waitMs: 400, widthIdx: wi, zoom: zoom, viewX: 0)
        let w = W / zoom
        r.canvas.setVisibleForReplay(x: viewLeft, y: wPage.height - wPage.height / zoom, w: w, z: zoom)
        return r
    }
    /// A word from page x `x`, `len` long, on the view's line at `fromTop` of its height.
    func word(_ r: WReal, x: Double, len: Double, fromTop: Double = 0.45) -> CGRect {
        let v = r.canvas.camera.visible, h = min(max(v.height * 0.05, 6), 50)
        return CGRect(x: x, y: v.maxY - fromTop * v.height - h / 2, width: len, height: h)
    }
    func write(_ r: WReal, _ rect: CGRect) { _ = r.apply(.write(.at(0)), place: rect); r.tick(0.05) }
    func measure(_ r: WReal) -> Double { WritingLayout.measureFromView ? r.canvas.camera.visible.width : W }

    for fromView in [false, true] {
        WritingLayout.measureFromView = fromView
        let rule = fromView ? "0.1.6 drafts (of the view)" : "0.1.7 (of the screen at 100%)"

        // (d) limit - start = setting x the measure at the block's start, every setting and zoom.
        var bad: [String] = []
        for zoom in [0.5, 1.0, 2.5, 4.0] {
            for wi in 0..<3 {
                let r = canvasAt(zoom: zoom, viewLeft: 200, wi: wi)
                let v = r.canvas.camera.visible
                write(r, word(r, x: v.minX + 0.2 * v.width, len: v.width * 0.06))
                let o = r.obs, want = settings[wi] * (fromView ? v.width : W)
                guard let s = o.runStart, let lim = o.limit, abs(lim - s - want) < 1e-6 else {
                    bad.append(String(format: "zoom %.1f %.0f%%: limit-start %.1f want %.1f", zoom, settings[wi] * 100, (o.limit ?? .nan) - (o.runStart ?? .nan), want)); continue
                }
            }
        }
        check(bad.isEmpty, "line width, \(rule): limit - the block's start = setting x \(fromView ? "the view's width then" : "1,600 units"), at 50/75/100% and zoom 50%-400% \(bad.prefix(3))")

        // (a) The same start (page x 300) gives the same limit wherever it sits on the screen: left edge, middle, near the right.
        for zoom in [1.0, 2.5] {
            let w = W / zoom
            var lims: [(String, Double, Double)] = []
            for (name, at) in [("left edge", 0.06), ("middle", 0.5), ("near the right", 0.85)] {
                let r = canvasAt(zoom: zoom, viewLeft: 300 - at * w)
                write(r, word(r, x: 300, len: w * 0.05))
                let o = r.obs
                lims.append((name, (o.limit ?? .nan) - (o.runStart ?? .nan), o.runStart ?? .nan))
            }
            let want = 0.5 * (fromView ? w : W)
            check(lims.allSatisfy { abs($0.1 - want) < 1e-6 && abs($0.2 - 300) < 3 },
                  String(format: "line width, %@, zoom %.1f: a block started at x 300 at the screen's left edge, middle or near its right side ends at 300 + %.0f every time (%@)",
                         rule, zoom, want, lims.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: ", ")))
        }

        // (b) Hand pans and follows during the block don't move the limit; (c) nor does zooming mid-block.
        do {
            let r = canvasAt(zoom: 4, viewLeft: 100)   // view 400 units: a 50% line (800 under 0.1.7) runs on past it
            let v0 = r.canvas.camera.visible
            write(r, word(r, x: v0.minX + 0.08 * v0.width, len: 30))
            let s0 = r.obs.runStart!, lim0 = r.obs.limit!
            var lims = [lim0], follows0 = r.obs.follows, events: [String] = []
            var x = r.obs.lineInk!.maxX
            for k in 0..<14 {
                let v = r.canvas.camera.visible
                if k == 2 || x + 40 > v.maxX - 0.02 * v.width { _ = r.apply(.pan(0.2), place: nil); r.tick(0.1); events.append("pan") }   // by hand (and when out of room)
                if k == 1 { _ = r.apply(.pinch(1.3), place: nil); r.tick(0.1); events.append("pinch") }
                guard let ink = r.obs.lineInk, r.obs.newLines == 0 else { break }
                x = ink.maxX
                write(r, word(r, x: x + 12, len: 28, fromTop: 0.45))
                r.tick(0.5)   // the word gap: a follow (or the next line) comes
                if r.obs.follows > follows0 + events.filter({ $0 == "follow" }).count { events.append("follow") }
                if r.obs.newLines > 0 { break }
                if let l = r.obs.limit { lims.append(l) }
                x = r.obs.lineInk?.maxX ?? x
            }
            let want = s0 + 0.5 * (fromView ? v0.width : W)
            check(abs(lim0 - want) < 1e-6 && lims.allSatisfy { abs($0 - lim0) < 1e-6 } && events.contains("pan") && events.contains("pinch"),
                  String(format: "line width, %@: at 400%%, through %d hand pans, %d follows and a pinch mid-block, the limit stays at the block's start + %.0f (%@)",
                         rule, events.filter { $0 == "pan" }.count, r.obs.follows - follows0, 0.5 * (fromView ? v0.width : W), Set(lims.map { String(format: "%.1f", $0) }).sorted().joined(separator: ", ")))
            if !fromView { check(r.obs.follows > follows0, "line width, \(rule): a line longer than the view at 400% gets follows (\(r.obs.follows - follows0))") }
        }

        // A redo after the block ended (writing mode off and on) brings ink back: it starts a block where it is, with this
        // rule; before, no block meant the rules before 0.1.6 (½ page from the page's margin, capped at 95%).
        do {
            let r = canvasAt(zoom: 1, viewLeft: 0)
            write(r, word(r, x: 200, len: 60))
            write(r, word(r, x: 820, len: 70))   // ends at 890: past ½ page (800), well before the block's end
            _ = r.apply(.undo, place: nil)
            _ = r.apply(.toggle, place: nil); _ = r.apply(.toggle, place: nil)   // the block ends
            _ = r.apply(.redo, place: nil)
            let o = r.obs, back = r.canvas.doc.strokes.last!.bounds
            let want = back.minX + 0.5 * (fromView ? r.canvas.camera.visible.width : W)
            check(o.pendingTarget == nil && o.runStart.map { abs($0 - back.minX) < 1e-9 } == true && o.limit.map { abs($0 - want) < 1e-6 } == true,
                  String(format: "line width, %@: a redo after the block ended starts one at the ink (start %.1f, limit %.1f, want %.1f), no next line (pending: %@)",
                         rule, o.runStart ?? .nan, o.limit ?? .nan, want, o.pendingTarget.map { "\($0)" } ?? "none"))
        }
    }

    // Karthik's session (6 Nov, 19:59): zoom 250%, a block started at x -1056 with 50%. 0.1.7: its line ends at -256 (the
    // 0.1.6 drafts ended it at -736, half his screen, and he went back twice to finish the sentence on the same line).
    WritingLayout.measureFromView = false
    let r = canvasAt(zoom: 2.5, viewLeft: -1145)
    write(r, word(r, x: -1056, len: 40))
    check(r.obs.limit.map { abs($0 - (r.obs.runStart! + 800)) < 1e-6 && abs($0 - -256) < 4 } == true,
          String(format: "line width: Karthik's block at x -1056 (250%%, 50%%) ends at %.0f (the 0.1.6 drafts: -736)", r.obs.limit ?? .nan))
}
