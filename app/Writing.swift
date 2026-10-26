// Writing mode. After each stroke the move below is worked out, but it only happens once the finger
// has stayed up for `pauseBeforeMoveMs` (400 ms): Karthik's lift->touch gaps are 77% under 300 ms
// within words, with a long tail past 600 ms between words. A touch before then cancels it (it's
// re-decided at the next lift), so the page never moves mid-word.
//  - auto-pan (off / centre / left): when the line's ink passes 70% of the view, pan so it ends
//    mid-screen (centre), or so the last words sit at the left edge (left). Either way the last 2-3
//    words stay on screen and a pan moves at most half the view;
//  - new line: when the line reaches the chosen width (or, after you panned right by hand, the page's
//    margin), go to the start of the next line: one line down, back to the left margin, with the new
//    line a little below the middle of the view so the lines above stay in sight.
// Lines always start at the page's left margin (`lineStart`), not at wherever the current line's
// first stroke happened to be: that made every new line after a hand pan, an undo or a page switch
// return to the middle of the page.
import CoreGraphics

enum AutoPan: Int { case off = 0, centre = 1, left = 2 }

struct WritingLayout {
    var autoPan = AutoPan.centre
    var edge = 0.70        // line's ink past this fraction of the view -> pan (at the next pause, so
                           // the next word starts with room; 0.85 ran words off the pad edge)
    var lineWidth = 0.75   // fraction of the page width a line may span (½, ¾, full)
    var margin = 0.03      // page side margin, fraction of the page width
    /// Where every line starts (page units).
    func lineStart(pageWidth: Double) -> Double { margin * pageWidth }
    var legacyStrokeEdge = false   // replays of old sessions: the edge check used only the last stroke

    enum Move: Equatable {
        case none, pan(CGPoint), newLine(CGPoint)
        var kind: String { switch self { case .none: return "none"; case .pan: return "autoPan"; case .newLine: return "newLine" } }
    }

    /// Where this line started, if a deliberate hand pan moved it (Canvas decides that): the line then ends ½ or
    /// ¾ of the page after this point instead of after the left margin. Auto-pans never move it.
    var segmentStart: Double?
    /// A hand pan counts as deliberate when the view moved sideways by at least this much of its width.
    static let deliberatePan = 0.10
    /// A pan moves the view at most this much (fraction of its width), so you can follow it.
    var maxJump = 0.5
    /// Where the line sits in the view after a new line, from the top: below the middle, so the lines
    /// you just wrote stay in view above it.
    static let lineFromTop = 0.575

    /// `line` = bounds of the current line's ink (incl. this stroke); `lineStrokes` = its strokes;
    /// `lineLeft` = where lines start (the app passes `lineStart`).
    func after(stroke s: CGRect, line: CGRect, lineStrokes: [CGRect], lineLeft: Double, visible v: CGRect, pageWidth: Double) -> Move {
        let pageEnd = pageWidth * (1 - margin)
        let lineEnd = min((segmentStart ?? lineLeft) + lineWidth * pageWidth, pageEnd)
        // The line's rightmost ink, not just this stroke: an i-dot or t-cross placed back inside the
        // word must not cancel a move that the word's end already called for.
        let right = legacyStrokeEdge ? s.maxX : max(s.maxX, line.maxX)
        let atEdge = right > v.minX + v.width * edge
        if right >= lineEnd {
            let pitch = max(line.height * 1.35, v.height * 0.12)
            return .newLine(Self.newLineCenter(lineLeft: lineLeft, lineMidY: line.midY, pitch: pitch, visible: v))
        }
        guard atEdge, autoPan != .off else { return .none }
        // Keep the last words on screen: the last three if they fit in 60% of the view, else two, else one.
        let starts = Self.wordStarts(lineStrokes, gap: max(line.height * 0.45, v.width * 0.01))
        var keep = starts.last ?? right
        for k in [3, 2] where starts.count >= k {
            let st = starts[starts.count - k]
            if right - st <= v.width * 0.6 { keep = st; break }
        }
        let keepX = keep - v.width * 0.04
        var minX: Double
        switch autoPan {
        case .left: minX = keepX                                  // those words at the left edge
        default:    minX = min(right - v.width * 0.5, keepX)      // centre: the line's end mid-screen
        }
        minX = min(minX, v.minX + v.width * maxJump, pageWidth - v.width)
        guard minX > v.minX + 0.5 else { return .none }
        return .pan(CGPoint(x: minX + v.width / 2, y: v.midY))
    }

    /// The view after a new line: one line (`pitch`) down, the line `lineFromTop` down the view, with the
    /// line start 5% in from the left.
    static func newLineCenter(lineLeft: Double, lineMidY: Double, pitch: Double, visible v: CGRect) -> CGPoint {
        CGPoint(x: max(lineLeft - v.width * 0.05, 0) + v.width / 2, y: lineMidY - pitch + (lineFromTop - 0.5) * v.height)
    }

    /// Left edges of the line's words, left to right: strokes grouped by x, a gap > `gap` splits words.
    static func wordStarts(_ strokes: [CGRect], gap: Double) -> [Double] {
        let sorted = strokes.sorted { $0.minX < $1.minX }
        guard let first = sorted.first else { return [] }
        var starts: [Double] = [first.minX], end = first.maxX
        for r in sorted.dropFirst() {
            if r.minX - end > gap { starts.append(r.minX) }
            end = max(end, r.maxX)
        }
        return starts
    }

    /// Left edge of the last word: strokes grouped left to right, a horizontal gap > `gap` splits words.
    static func lastWordStart(_ strokes: [CGRect], gap: Double) -> Double {
        let sorted = strokes.sorted { $0.minX < $1.minX }
        guard var start = sorted.first?.minX, var end = sorted.first?.maxX else { return 0 }
        for r in sorted.dropFirst() {
            if r.minX - end > gap { start = r.minX }
            end = max(end, r.maxX)
        }
        return start
    }
}
