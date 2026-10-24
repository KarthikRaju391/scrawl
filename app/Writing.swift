// Writing mode: the page follows your finger, not the screen. Most touch-downs continue right where
// the last stroke lifted (~80% in Karthik's sessions) and need nothing. When you come back well to
// the left (>= 15% of the pad width, the "carriage return", ~12%), the page shifts at that moment so
// the spot under your finger is just after the end of your line, wherever you chose to come back
// to. Once the line reaches the chosen width, the next return starts the next line there instead.
// The other style, "Keep centred": when a finished stroke reaches the right edge of the view, the
// view pans so that stroke ends mid-screen (you carry on from the middle of the pad); at the line
// width it returns to the line's left edge, one line down, mid-screen. See WritingLayout below.
import CoreGraphics

enum PanStyle: Int { case followFinger = 0, keepCentred = 1 }

struct Reanchor {
    var minJumpBack = 0.15   // fraction of the pad width
    var lineWidth = 0.75     // fraction of the page width a line may span (½, ¾, full)
    var margin = 0.03        // page side margin, fraction of the page width

    /// Is this touch-down (pad 0...1) a return to continue writing?
    func isReturn(down: CGPoint, lastLift: CGPoint) -> Bool { lastLift.x - down.x >= minJumpBack }

    /// Where writing continues (canvas): just right of the line's ink, or the next line's start.
    func continuation(line: CGRect, lineLeft: Double, newLine: Bool, gap: Double) -> CGPoint {
        if newLine {
            return CGPoint(x: lineLeft, y: line.midY - max(line.height * 1.35, gap * 4))
        }
        return CGPoint(x: line.maxX + gap, y: line.midY)
    }

    /// Has the line reached its width (so the next return starts a new line)?
    func lineFull(line: CGRect, lineLeft: Double, pageWidth: Double) -> Bool {
        line.maxX >= min(lineLeft + lineWidth * pageWidth, pageWidth * (1 - margin))
    }
}

/// Keep centred: pans after a stroke ends (never while a finger is down).
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
