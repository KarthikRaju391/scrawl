// Multi-finger taps in draw mode: two-finger double tap = undo, three-finger double tap = redo. Keeping the
// second tap of a double tap down (still, 0.25 s) is a hold: the undo scrub (slide to step through history).
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
    var holdTime = 0.25     // second tap still down (and still) this long: a hold

    enum Event: Equatable { case tap(Int), doubleTap(Int), hold(Int) }
    private var held = false

    private var down: [Int32: (t: Double, at: CGPoint)] = [:]
    private var lifted: [Int32: Double] = [:]
    private var moved = 0.0
    private var lastTap: (fingers: Int, end: Double, edge: Bool)?

    // Edge-band contacts (0.1.7). A tap with one finger in the edge band never reached the detector (it saw only the contacts the
    // edge guard keeps), so the undo or redo never came. Edge contacts are auxiliary: one that lands and lifts with a tap of one
    // or two counted fingers (within the same windows) and stays still makes it a two- or three-finger tap. It never changes a
    // tap of three, never keeps an episode open (a resting palm or thumb can't block a tap), and an edge tap never starts a hold.
    // The caller passes only candidates: not in the bottom band (the heel of the hand lands there with every touch: in Karthik's
    // sessions it came with 117 one-finger touches and turned two-finger undo taps into three), not palm-sized, not down when draw
    // mode started, each with when it touched down.
    private var aux: [Int32: (down: Double, at: CGPoint, up: Double?, moved: Double)] = [:]
    /// The counted fingers have lifted and an edge contact hasn't yet: the decision waits up to the lift window for it.
    private var pending: (t: Double, down: [Int32: (t: Double, at: CGPoint)], lifted: [Int32: Double], moved: Double)?
    /// Whether the last event's tap had an edge finger (the canvas then drops the dots its counted finger drew).
    private(set) var lastUsedEdge = false

    /// One frame of counted fingers (down contacts the edge guard keeps), and edge-band candidates with when each touched down,
    /// at time t. Returns an event when an episode (first touch-down to all lifted) ends as a tap.
    mutating func frame(_ fingers: [Contact], edge: [(contact: Contact, down: Double)] = [], t: Double) -> Event? {
        var early: Event?   // a waiting decision made on this frame (a new touch may start the next episode in it)
        if let p = pending {
            noteEdge(edge.filter { aux[$0.contact.id] != nil }, t: t)
            guard aux.values.allSatisfy({ $0.up != nil }) || t - p.t > liftWindow || !fingers.isEmpty else { return nil }
            pending = nil
            down = p.down; lifted = p.lifted; moved = p.moved
            early = decide(t: t)
            if fingers.isEmpty { return early }
        }
        let ids = Set(fingers.map(\.id))
        for f in fingers {
            if down[f.id] == nil { down[f.id] = (t, f.mm) }
            if let d = down[f.id] { moved = max(moved, hypot(f.mm.x - d.at.x, f.mm.y - d.at.y)) }
        }
        for id in down.keys where !ids.contains(id) && lifted[id] == nil { lifted[id] = t }
        if !down.isEmpty { noteEdge(edge, t: t) }
        // The second tap of a double tap, held: all its fingers landed together soon after the first tap,
        // none has lifted or moved, and it has lasted `holdTime`.
        if !fingers.isEmpty, !held, lifted.isEmpty, let l = lastTap, l.fingers == down.count, !l.edge {
            let downs = down.values.map(\.t), start = downs.min()!
            if downs.max()! - start <= landWindow && start - l.end <= doubleGap && t - start >= holdTime && moved <= maxMove {
                held = true; lastTap = nil
                return .hold(down.count)
            }
        }
        guard fingers.isEmpty, !down.isEmpty else { return early }
        if held { held = false; down = [:]; lifted = [:]; moved = 0; aux = [:]; return nil }
        // The episode is over. An edge contact still down might lift with it: wait for it (at most the lift window).
        if down.count <= 2, aux.values.contains(where: { $0.up == nil }) { pending = (t, down, lifted, moved); down = [:]; lifted = [:]; moved = 0; return nil }
        return decide(t: t)
    }
    private mutating func noteEdge(_ edge: [(contact: Contact, down: Double)], t: Double) {
        let ids = Set(edge.map(\.contact.id))
        for (c, d0) in edge {
            if aux[c.id] == nil { aux[c.id] = (d0, c.mm, nil, 0) }
            aux[c.id]!.moved = max(aux[c.id]!.moved, hypot(c.mm.x - aux[c.id]!.at.x, c.mm.y - aux[c.id]!.at.y))
        }
        for (id, a) in aux where a.up == nil && !ids.contains(id) { aux[id]!.up = t }
    }
    /// Was the episode just over a tap?
    private mutating func decide(t: Double) -> Event? {
        let downs = down.values.map(\.t), ups = Array(lifted.values)
        var n = down.count
        let start = downs.min()!, end = ups.max() ?? t
        let together = downs.max()! - start <= landWindow && (ups.max() ?? t) - (ups.min() ?? t) <= liftWindow && end - start <= maxDuration && moved <= maxMove
        var isTap = (2...3).contains(n) && together
        lastUsedEdge = false
        if together && n <= 2 && aux.count == 1, let a = aux.values.first, let up = a.up,
           abs(a.down - start) <= landWindow, abs(up - end) <= liftWindow, up - a.down <= maxDuration, a.moved <= maxMove {
            n += 1; isTap = true; lastUsedEdge = true
        }
        down = [:]; lifted = [:]; moved = 0; aux = [:]
        guard isTap else { lastTap = nil; return nil }
        if let l = lastTap, l.fingers == n, start - l.end <= doubleGap {
            lastUsedEdge = lastUsedEdge || l.edge
            lastTap = nil
            return .doubleTap(n)
        }
        lastTap = (n, end, lastUsedEdge)
        return .tap(n)
    }
    mutating func reset() { down = [:]; lifted = [:]; moved = 0; lastTap = nil; held = false; aux = [:]; pending = nil; lastUsedEdge = false }
}
