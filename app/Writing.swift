// Writing mode. After each stroke (never while a finger is down):
//  - auto-pan (off / centre / left): when the stroke reaches the right 15% of the view, pan so it
//    ends mid-screen (centre), or so the word just written sits at the left edge (left);
//  - new line: when the line reaches the chosen width, or the view can't pan further right (end of
//    the page), go to the start of the next line (line's left edge, one line down, mid-screen).
import CoreGraphics

enum AutoPan: Int { case off = 0, centre = 1, left = 2 }

struct WritingLayout {
    var autoPan = AutoPan.centre
    var edge = 0.85        // stroke past this fraction of the visible width -> pan
    var lineWidth = 0.75   // fraction of the page width a line may span (½, ¾, full)
    var margin = 0.03      // page side margin, fraction of the page width

    enum Move: Equatable { case none, pan(CGPoint), newLine(CGPoint) }

    /// `line` = bounds of the current line's ink (incl. this stroke); `lineStrokes` = its strokes;
    /// `lineLeft` = where lines start.
    func after(stroke s: CGRect, line: CGRect, lineStrokes: [CGRect], lineLeft: Double, visible v: CGRect, pageWidth: Double) -> Move {
        let lineEnd = min(lineLeft + lineWidth * pageWidth, pageWidth * (1 - margin))
        let atEdge = s.maxX > v.minX + v.width * edge
        let viewAtPageEnd = v.maxX >= pageWidth - 0.5
        if s.maxX >= lineEnd || (atEdge && viewAtPageEnd) {
            let pitch = max(line.height * 1.35, v.height * 0.12)
            let minX = max(lineLeft - v.width * 0.05, 0)
            return .newLine(CGPoint(x: minX + v.width / 2, y: line.midY - pitch))
        }
        guard atEdge, autoPan != .off else { return .none }
        var minX: Double
        switch autoPan {
        case .left:  // the word just written at the left edge (at most 80% of the view back)
            minX = max(Self.lastWordStart(lineStrokes, gap: max(line.height * 0.45, v.width * 0.01)) - v.width * 0.04, s.maxX - v.width * 0.8)
        default:     // centre
            minX = s.maxX - v.width * 0.5
        }
        minX = min(minX, pageWidth - v.width)
        guard minX > v.minX + 0.5 else { return .none }
        return .pan(CGPoint(x: minX + v.width / 2, y: v.midY))
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
