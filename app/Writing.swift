// Writing mode. After each stroke the move below is worked out, but it only happens once the finger
// has stayed up for `pauseBeforeMoveMs` (400 ms): Karthik's lift->touch gaps are 77% under 300 ms
// within words, with a long tail past 600 ms between words. A touch before then cancels it (it's
// re-decided at the next lift), so the page never moves mid-word.
// The only move is the new line (Karthik, 28 Oct: the sideways pan that followed the pen along a line was
// distracting, and is gone): when the line reaches the chosen width (or, after you panned right by hand,
// that width after where you moved to), go to the start of the next line: one line down, back to the left
// margin, with the new line a little below the middle of the view so the lines above stay in sight. A faint
// vertical line in the canvas marks the limit (`lineEnd`).
// Lines always start at the page's left margin (`lineStart`), not at wherever the current line's
// first stroke happened to be: that made every new line after a hand pan, an undo or a page switch
// return to the middle of the page.
import CoreGraphics

struct WritingLayout {
    var lineWidth = 0.75   // fraction of the page width a line may span (50%, 75%, 100%), from where its writing run began
    var margin = 0.03      // page side margin, fraction of the page width
    /// Where every line starts (page units).
    func lineStart(pageWidth: Double) -> Double { margin * pageWidth }
    var legacyStrokeEdge = false   // replays of old sessions: the edge check used only the last stroke

    enum Move: Equatable {
        case none, newLine(CGPoint)
        var kind: String { switch self { case .none: return "none"; case .newLine: return "newLine" } }
    }

    /// Where this line started, if a deliberate hand pan moved it (Canvas decides that): the line then ends ½ or
    /// ¾ of the page after this point instead of after the left margin. Auto-pans never move it.
    var segmentStart: Double?
    /// A typical word's width from earlier lines (when this line has only one word so far).
    var wordHint: Double?
    /// The limit for this line (page units).
    func lineEnd(lineLeft: Double, pageWidth: Double) -> Double {
        min(segmentStart.map { $0 + lineWidth * pageWidth } ?? lineWidth * pageWidth, pageWidth * Self.rightCap)
    }
    /// The limit never goes past 95% of the page width (Karthik, 29 Oct): at 97% ink often stopped short of it (no next
    /// line) and the guide line hugged the page's edge; at 92% his lines (he writes to 95-100% of the page) crossed it
    /// while he still had a word or two to write, and the move came mid-phrase. A word that starts before it still
    /// finishes past it, up to the page's edge.
    static let rightCap = 0.95
    /// When the limit is at the page's edge (past 93% of the page, up to `rightCap`), ink that stops at 93% of the page
    /// or more is a full line too: the next line comes after a longer pause (`nearEdgeWaitMs`). Ink at 93-95% got no move at all
    /// (74c61cf); a 93% limit would break lines mid-phrase (Karthik wrote on after a word ending at 92.99%, 0.97 s later).
    static let nearEdge = 0.93
    static let nearEdgeWaitMs = 1500.0
    /// A hand pan counts as deliberate when the view moved sideways by at least this much of its width.
    static let deliberatePan = 0.10
    /// After a hand move, the next line starts a new block only this far (fraction of the page width) from the current
    /// block's start.
    static let newRunAway = 0.10
    /// Where the line sits in the view after a new line, from the top: below the middle, so the lines
    /// you just wrote stay in view above it.
    static let lineFromTop = 0.575

    /// `line` = bounds of the current line's ink (incl. this stroke); `lineStrokes` = its strokes;
    /// `lineLeft` = where lines start (the app passes `lineStart`).
    func after(stroke s: CGRect, line: CGRect, lineStrokes: [CGRect], lineLeft: Double, visible v: CGRect, pageWidth: Double) -> Move {
        let pageEnd = pageWidth * Self.rightCap
        // A hard limit: 50 / 75 / 100% of the page width from where the writing run began (the app passes it as
        // `segmentStart`; without one, from the page's left edge), capped at the page's right margin.
        let lineEnd = min(segmentStart.map { $0 + lineWidth * pageWidth } ?? lineWidth * pageWidth, pageEnd)
        // The line's rightmost ink, not just this stroke: an i-dot or t-cross placed back inside the
        // word must not cancel a move that the word's end already called for.
        let right = legacyStrokeEdge ? s.maxX : max(s.maxX, line.maxX)
        let pitch = max(line.height * 1.35, v.height * 0.12)
        let next = Self.newLineCenter(lineLeft: lineLeft, lineMidY: line.midY, pitch: pitch, visible: v)
        if legacyStrokeEdge {
            if right >= lineEnd { return .newLine(next) }
        } else if right >= lineEnd {
            // The line's ink crossed the limit: the next line at the next word gap. A word that started before the
            // limit and ran past it stays on its line (written ink never moves).
            return .newLine(next)
        } else if lineEnd > pageWidth * Self.nearEdge, right >= pageWidth * Self.nearEdge {
            return .newLine(next)   // the page's edge is near: the app waits longer for this one (Canvas)
        }
        // (No look-ahead any more: breaking before a word that "wouldn't fit" moved the page before Karthik reached the
        // end of the line, 29 Oct. The line goes to the next once its ink crosses the limit.)
        return .none
    }

    /// The view after a new line: one line (`pitch`) down, the line `lineFromTop` down the view, with the
    /// line start 5% in from the left.
    static func newLineCenter(lineLeft: Double, lineMidY: Double, pitch: Double, visible v: CGRect) -> CGPoint {
        CGPoint(x: max(lineLeft - v.width * 0.05, 0) + v.width / 2, y: lineMidY - pitch + (lineFromTop - 0.5) * v.height)
    }

    /// Whether the line's last word looks unfinished: much shorter (< 60%) than this line's typical word, so a
    /// pause now is probably inside it. (A line's first word never counts as unfinished.)
    static func lastWordUnfinished(_ lineStrokes: [CGRect], line: CGRect, visible v: CGRect, hint: Double?) -> Bool {
        let words = Self.words(lineStrokes, gap: Self.wordGap(lineStrokes, visible: v))
        guard words.count >= 2, let w = words.last else { return false }
        let widths = words.dropLast().map { $0.end - $0.start }.sorted()
        let typical = widths[widths.count / 2]
        return (w.end - w.start) < typical * 0.6
    }

    /// The space that splits words: 45% of a typical stroke's height (the median). It used to be 45% of the whole line's
    /// height, which a capital or one descender (the p in "panning") raised from 33 to 48 page units on Karthik's
    /// line at 400% (27 Oct): his word spaces (~18) fell under it, the whole line became one "word", and the next-word
    /// look-ahead broke lines at 28-32% of the page instead of ½.
    static func wordGap(_ strokes: [CGRect], visible v: CGRect) -> Double {
        let hs = strokes.map(\.height).sorted()
        return max(hs.isEmpty ? 0 : hs[hs.count / 2] * 0.45, v.width * 0.01)
    }
    /// A "word" wider than this share of the line can't be one: the strokes weren't split into words.
    static let maxWordShare = 0.25

    /// The line's words as x ranges, left to right (strokes grouped by x; a gap > `gap` splits words).
    static func words(_ strokes: [CGRect], gap: Double) -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        for r in strokes.sorted(by: { $0.minX < $1.minX }) {
            if let l = out.last, r.minX - l.end <= gap { out[out.count - 1].end = max(l.end, r.maxX) } else { out.append((r.minX, r.maxX)) }
        }
        return out
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
