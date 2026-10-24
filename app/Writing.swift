// Writing mode: when a finished stroke reaches the right edge of the view, the view pans so that
// stroke ends mid-screen (you carry on from the middle of the pad); when the line reaches the chosen
// width, the view goes to the start of the next line (line's left edge, one line down, mid-screen).
// Never moves while a finger is down. ("Follow finger" re-anchoring was removed on 2026-10-24.)
import CoreGraphics

struct WritingLayout {
    var edge = 0.85        // stroke past this fraction of the visible width -> pan
    var landAt = 0.5       // ...so the stroke ends at this fraction (the middle)
    var lineWidth = 0.75   // fraction of the page width a line may span (½, ¾, full)
    var margin = 0.03      // page side margin, fraction of the page width

    enum Move: Equatable { case none, pan(CGPoint), newLine(CGPoint) }

    /// After a finished stroke. `line` = bounds of the current line's ink so far (including this
    /// stroke); `lineLeft` = where this line (and the ones after it) start.
    func after(stroke s: CGRect, line: CGRect, lineLeft: Double, visible v: CGRect, pageWidth: Double) -> Move {
        let lineEnd = min(lineLeft + lineWidth * pageWidth, pageWidth * (1 - margin))
        if s.maxX >= lineEnd {
            let pitch = max(line.height * 1.35, v.height * 0.12)
            let minX = max(lineLeft - v.width * 0.05, 0)
            return .newLine(CGPoint(x: minX + v.width / 2, y: line.midY - pitch))
        }
        guard s.maxX > v.minX + v.width * edge else { return .none }
        // Pan so the stroke ends mid-screen. Not limited by the line's end: keeping the end in view
        // made the last part of every line get written at the pad's right edge (0.89-0.95 in tests).
        let minX = min(s.maxX - v.width * landAt, pageWidth - v.width)
        guard minX > v.minX + 0.5 else { return .none }
        return .pan(CGPoint(x: minX + v.width / 2, y: v.midY))
    }
}
