// Writing mode: the page moves, not your finger (a typewriter carriage, like the "zoom box" in
// note apps). You keep writing around the same spot on the pad; after a pause, the page slides so
// the end of what you wrote sits back at that spot, and a caret shows where the next letter goes.
// At the right margin it wraps to the next line. UI-free so the bench can test it.
import CoreGraphics
import Foundation

struct WritingGuide {
    var advanceAt = 0.55   // pan once the line's ink passes this fraction of the visible width
    var continueAt = 0.30  // ...so that the caret lands at this fraction (same pad spot every time)
    var gap = 0.05         // space between the ink and the caret, fraction of the visible width
    var margin = 0.03      // page margins, fraction of the page width
    var lineStep = 0.6     // next line, fraction of the visible height

    /// Where the next letter goes: just right of the line's ink, centred on it vertically.
    func caret(lineInk: CGRect?, visible v: CGRect, page: CGSize) -> CGRect {
        let h = max(lineInk?.height ?? 0, v.height * 0.18)
        guard let ink = lineInk else {
            // Empty line: at the "home" spot, or the left margin if that's in view.
            let x = max(v.minX + v.width * continueAt * 0.5, page.width * margin)
            return CGRect(x: x, y: v.midY - h / 2, width: 0, height: h)
        }
        return CGRect(x: ink.maxX + v.width * gap, y: ink.midY - h / 2, width: 0, height: h)
    }

    enum Move: Equatable { case none, advance(CGPoint), wrap(CGPoint) }

    /// After a pause: new camera centre, if the page should move.
    func afterPause(lineInk: CGRect?, visible v: CGRect, page: CGSize) -> Move {
        guard let ink = lineInk else { return .none }
        let caretX = ink.maxX + v.width * gap
        if caretX > page.width * (1 - margin) { return .wrap(newLine(lineInk: ink, visible: v, page: page)) }
        guard caretX > v.minX + v.width * advanceAt else { return .none }
        let minX = min(caretX - v.width * continueAt, page.width - v.width)
        return .advance(CGPoint(x: minX + v.width / 2, y: v.midY))
    }

    /// Camera centre for the start of the next line: left margin in view, one line below.
    func newLine(lineInk: CGRect?, visible v: CGRect, page: CGSize) -> CGPoint {
        let lineMid = lineInk?.midY ?? v.midY
        let nextMid = lineMid - v.height * lineStep
        let minX = max(page.width * margin - v.width * continueAt * 0.5, 0)
        return CGPoint(x: minX + v.width / 2, y: nextMid)
    }
}
