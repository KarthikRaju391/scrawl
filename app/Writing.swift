// Writing mode: the page follows your finger, not the screen. Most touch-downs continue right where
// the last stroke lifted (~80% in Karthik's sessions) and need nothing. When you come back well to
// the left (>= 15% of the pad width, the "carriage return", ~12%), the page shifts at that moment so
// the spot under your finger is just after the end of your line, wherever you chose to come back
// to. Once the line reaches the chosen width, the next return starts the next line there instead.
import CoreGraphics

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
