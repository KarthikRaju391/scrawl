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
        /// `follow`: the line runs on past the view's right side, the view goes along with it (0.1.6; camera only).
        case none, newLine(CGPoint), follow(CGPoint)
        var kind: String { switch self { case .none: return "none"; case .newLine: return "newLine"; case .follow: return "follow" } }
    }

    // MARK: 0.1.6, the infinite canvas: the page's edge is no limit
    // A block's lines are as long as the width setting (50 / 75 / 100%) of the view's width when the block started, from the
    // block's start (where its first stroke landed): `blockWidth`, fixed for the block (zooming in or out while writing it
    // doesn't change it; the next block takes the zoom then). No 95% cap, no 93% near-edge rule: the only early trigger is
    // ink just short of the marker (`nearMarker` of the line). A line longer than the view: the view follows it as it fills
    // (`follow`), at the same pause as a next line. Nil `blockWidth`: the rules before 0.1.6 (`--column-bound`).
    var blockWidth: Double?
    /// What the width setting is a share of: 0.1.7 (Karthik, 6 Nov: "It should not consider the viewport ... calculate the
    /// full screen width and then take the percentage"), the screen's width at 100%, which is the page's width (the page
    /// fills the window's width at 100%): a 50% line is 800 units at any zoom, from where the block starts. `measureFromView`
    /// (the 0.1.6 drafts): the view's width when the block started instead.
    nonisolated(unsafe) static var measureFromView = false
    /// The length a block's 100% line has: the page's width (or, `measureFromView`, the view's width now).
    static func blockMeasure(visibleWidth: Double, pageWidth: Double) -> Double { measureFromView ? visibleWidth : pageWidth }
    /// The view follows a line once its ink is within this share of the view's width from the view's right side, and goes
    /// so that the ink is at `followTo` of the view.
    static let followWithin = 0.12, followTo = 0.5
    /// The furthest right the view can show at the zoom now (the camera's reach): a line never ends past it. A block started
    /// near the reach (a 100% line from past x 4,080 at 100%, a 50% line from past 4,320 at 250%) had its end where the view
    /// couldn't follow and no stroke could get, so no next line ever came (cutoff-verify: P8Reach, the reach check). Only
    /// there does the end depend on the zoom. Never closer than 10% of the line to its start. Nil: no cap (unit checks).
    var reachRight: Double?
    static func reachRight(pageWidth: Double, visibleWidth: Double) -> Double { pageWidth * (1 + Camera.reach) + visibleWidth * 0.45 }   // 5% inside the view at its reach: room for the word that crosses

    /// Where this line started, if a deliberate hand pan moved it (Canvas decides that): the line then ends ½ or
    /// ¾ of the page after this point instead of after the left margin. Auto-pans never move it.
    var segmentStart: Double?
    /// A typical word's width from earlier lines (when this line has only one word so far).
    var wordHint: Double?
    /// The limit for this line (page units).
    func lineEnd(lineLeft: Double, pageWidth: Double) -> Double {
        if let bw = blockWidth {
            let end = (segmentStart ?? lineLeft) + bw
            guard let r = reachRight else { return end }
            return min(end, max(r, (segmentStart ?? lineLeft) + 0.1 * bw))
        }
        return min(segmentStart.map { $0 + lineWidth * pageWidth } ?? lineWidth * pageWidth, pageWidth * Self.rightCap)
    }
    /// The limit never goes past 95% of the page width (Karthik, 29 Oct): at 97% ink often stopped short of it (no next
    /// line) and the guide line hugged the page's edge; at 92% his lines (he writes to 95-100% of the page) crossed it
    /// while he still had a word or two to write, and the move came mid-phrase. A word that starts before it still
    /// finishes past it, up to the page's edge.
    static let rightCap = 0.95
    /// When the limit is at the page's edge (past 93% of the page, up to `rightCap`), ink that stops at 93% of the page
    /// or more is a full line too: the next line at the usual 400 ms word gap, like a crossing (Karthik on b03bac2: not
    /// 1.5 s). Ink at 93-95% got no move at all (74c61cf).
    static let nearEdge = 0.93
    /// Ink ending this close before the marker (fraction of the line width: 24 page units at 50% of a 1600-wide page,
    /// 36 at 75%, 48 at 100%) is a full line too (Karthik on 0.1.1: "when I am just inside the guide line, the next
    /// line pan isn't triggering"; his "it" ended 4 units short). In his sessions the only words ending within 4% of
    /// the marker were followed by a long pause (1.6 s, 6.3 s: waiting for the move); at 4.8-5% he wrote another word
    /// on the line 0.6-2.4 s later, so the zone stays well under that.
    static let nearMarker = 0.03
    /// Where the "full line" zone starts: `nearMarker` of the line width before the marker; with the marker near the
    /// page's edge (past 93%), at 93% of the page (never before: he once wrote a word more after one ending at 92.99%).
    func nearMarkerStart(lineEnd: Double, pageWidth: Double) -> Double {
        if let bw = blockWidth { return lineEnd - Self.nearMarker * bw }
        return lineEnd > pageWidth * Self.nearEdge ? pageWidth * Self.nearEdge : lineEnd - Self.nearMarker * lineWidth * pageWidth
    }
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
        // A hard limit: 50 / 75 / 100% of the page width from where the writing run began (the app passes it as
        // `segmentStart`; without one, from the page's left edge), capped at the page's right margin. 0.1.6: the block's
        // own width from its start, no cap.
        let lineEnd = self.lineEnd(lineLeft: lineLeft, pageWidth: pageWidth)
        // The line's rightmost ink, not just this stroke: an i-dot or t-cross placed back inside the
        // word must not cancel a move that the word's end already called for.
        let right = legacyStrokeEdge ? s.maxX : max(s.maxX, line.maxX)
        let pitch = max(line.height * 1.35, v.height * 0.12)
        let next = Self.newLineCenter(lineLeft: lineLeft, lineMidY: line.midY, pitch: pitch, visible: v, bounded: blockWidth == nil)
        if legacyStrokeEdge {
            if right >= lineEnd { return .newLine(next) }
        } else if right >= lineEnd {
            // The line's ink crossed the limit: the next line at the next word gap. A word that started before the
            // limit and ran past it stays on its line (written ink never moves).
            return .newLine(next)
        } else if right >= nearMarkerStart(lineEnd: lineEnd, pageWidth: pageWidth) {
            // Just short of the marker (no room for another word), or at 93%+ of the page with the marker at its
            // edge: a full line too, at the usual 400 ms word gap.
            return .newLine(next)
        }
        // (No look-ahead any more: breaking before a word that "wouldn't fit" moved the page before Karthik reached the
        // end of the line, 29 Oct. The line goes to the next once its ink crosses the limit.)
        // 0.1.6: a line running on past the view's right side, the view follows (only sideways; never past the line's end).
        if blockWidth != nil, right > v.maxX - Self.followWithin * v.width {
            let cx = min(right - Self.followTo * v.width + v.width / 2, lineEnd + v.width * 0.05 - v.width / 2)
            if cx > v.midX + 1e-9 { return .follow(CGPoint(x: cx, y: v.midY)) }
        }
        return .none
    }

    /// The view after a new line: one line (`pitch`) down, the line `lineFromTop` down the view, with the
    /// line start 5% in from the left.
    /// `bounded` (before 0.1.6): the view never left of the page's edge.
    static func newLineCenter(lineLeft: Double, lineMidY: Double, pitch: Double, visible v: CGRect, bounded: Bool = true) -> CGPoint {
        let left = lineLeft - v.width * 0.05
        return CGPoint(x: (bounded ? max(left, 0) : left) + v.width / 2, y: lineMidY - pitch + (lineFromTop - 0.5) * v.height)
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
