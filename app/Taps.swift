// Multi-finger taps in draw mode: two-finger double tap = undo, three-finger double tap = redo.
// Rules from Karthik's 7 recorded sessions (1,209 two-or-more-finger episodes, mostly pans and pinches):
// with these, none of them makes a double tap; looser rules (e.g. 120 ms / 300 ms / 3 mm / 350 ms) let one
// through. tools/tap_analysis.py has the numbers.
import CoreGraphics

struct MultiTapDetector {
    var landWindow = 0.06   // all fingers touch down within 60 ms of each other
    var liftWindow = 0.06   // ... and lift within 60 ms of each other
    var maxDuration = 0.20  // first touch-down to last lift
    var maxMove = 1.5       // mm, any finger
    var doubleGap = 0.30    // second tap starts within 300 ms of the first one's lift

    enum Event: Equatable { case tap(Int), doubleTap(Int) }

    private var down: [Int32: (t: Double, at: CGPoint)] = [:]
    private var lifted: [Int32: Double] = [:]
    private var moved = 0.0
    private var lastTap: (fingers: Int, end: Double)?

    /// One frame of counted fingers (down contacts the edge guard keeps), at time t. Returns an event when an
    /// episode (first touch-down to all lifted) ends as a tap.
    mutating func frame(_ fingers: [Contact], t: Double) -> Event? {
        let ids = Set(fingers.map(\.id))
        for f in fingers {
            if down[f.id] == nil { down[f.id] = (t, f.mm) }
            if let d = down[f.id] { moved = max(moved, hypot(f.mm.x - d.at.x, f.mm.y - d.at.y)) }
        }
        for id in down.keys where !ids.contains(id) && lifted[id] == nil { lifted[id] = t }
        guard fingers.isEmpty, !down.isEmpty else { return nil }
        // The episode is over: was it a tap?
        let downs = down.values.map(\.t), ups = Array(lifted.values)
        let n = down.count, start = downs.min()!, end = ups.max() ?? t
        let isTap = (2...3).contains(n) && downs.max()! - start <= landWindow && (ups.max() ?? t) - (ups.min() ?? t) <= liftWindow
            && end - start <= maxDuration && moved <= maxMove
        down = [:]; lifted = [:]; moved = 0
        guard isTap else { lastTap = nil; return nil }
        if let l = lastTap, l.fingers == n, start - l.end <= doubleGap {
            lastTap = nil
            return .doubleTap(n)
        }
        lastTap = (n, end)
        return .tap(n)
    }
    mutating func reset() { down = [:]; lifted = [:]; moved = 0; lastTap = nil }
}
