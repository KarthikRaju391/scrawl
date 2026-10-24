// Gesture engine scenarios: synthetic contact frames at 125 Hz through the app's GestureEngine,
// with sizes taken from the Phase 1 capture (finger major axis 6.5-8.9, total 0.12-0.84).
import CoreGraphics
import Foundation

func gestureChecks(_ check: (Bool, String) -> Void) {
    final class Rec {
        var begins = 0, moves = 0, commits = 0, discards = 0, navs: [Double] = [], centroids: [(CGPoint, CGPoint)] = []
    }
    func run(_ frames: [[Contact]], length: Double = 10, threshold: Double = 0) -> Rec {
        let g = GestureEngine(), r = Rec()
        g.inkThreshold = threshold
        g.onBegin = { _, _ in r.begins += 1 }
        g.onMove = { _, _ in r.moves += 1 }
        g.onEnd = { c in if c { r.commits += 1 } else { r.discards += 1 } }
        g.onNavigate = { a, b, ratio in r.navs.append(ratio); r.centroids.append((a, b)) }
        g.strokeLengthMM = { length }
        for (i, f) in frames.enumerated() { g.frame(f, t: Double(i) * 0.008) }
        return r
    }
    func finger(_ id: Int32, _ x: Double, _ y: Double, major: Double = 7.4, size: Double = 0.48, state: Int32 = 4, pressure: Double = 17) -> Contact {
        Contact(id: id, state: state, norm: CGPoint(x: x, y: y), mm: CGPoint(x: x * 124.8, y: y * 76.8), pressure: pressure, size: size, major: major)
    }

    // 1. One finger drags, lifts: one committed stroke.
    var f: [[Contact]] = (0..<60).map { [finger(1, 0.3 + Double($0) * 0.005, 0.5)] }
    f.append([])
    var r = run(f)
    check(r.begins == 1 && r.commits == 1 && r.discards == 0 && r.moves == 59, "one finger: one stroke committed, begin + 59 moves = 60 frames (begins \(r.begins), commits \(r.commits), moves \(r.moves))")

    // 2. Second finger lands 40 ms after the first: the stroke start is discarded, it's a pan/pinch.
    f = (0..<5).map { [finger(1, 0.4, 0.5 + Double($0) * 0.001)] }
    f += (0..<50).map { i in [finger(1, 0.4 - Double(i) * 0.002, 0.5), finger(2, 0.6 + Double(i) * 0.002, 0.5)] }
    f.append([])
    r = run(f, length: 0.5)
    check(r.commits == 0 && r.discards == 1 && r.navs.count > 40, "two fingers 40 ms apart: no ink, navigation (commits \(r.commits), discards \(r.discards), nav frames \(r.navs.count))")
    let zoom = r.navs.reduce(1, *), expected = (0.2 + 0.004 * 49) / 0.2
    check(abs(zoom - expected) < 0.01, String(format: "spreading fingers zooms by the distance ratio (%.3f, expected %.3f)", zoom, expected))

    // 3. A palm resting while one finger draws: palm never starts or interrupts a stroke.
    f = (0..<60).map { i in [finger(9, 0.8, 0.1, major: 16, size: 2.1), finger(1, 0.3 + Double(i) * 0.005, 0.6)] }
    f.append([])
    r = run(f)
    check(r.begins == 1 && r.commits == 1 && r.navs.isEmpty, "palm + drawing finger: one stroke, no navigation (begins \(r.begins), commits \(r.commits), navs \(r.navs.count))")

    // 4. Palm landing first then growing: it starts finger-sized; once it grows it's discarded.
    f = (0..<10).map { _ in [finger(5, 0.7, 0.1, major: 8.5, size: 0.8)] }
    f += (0..<20).map { _ in [finger(5, 0.7, 0.1, major: 14, size: 1.8)] }
    f.append([])
    r = run(f)
    check(r.commits == 0, "contact that grows into a palm leaves no ink (commits \(r.commits), discards \(r.discards))")

    // 5. After a stroke a leftover finger can't start a new stroke until all fingers lift.
    f = (0..<30).map { i in [finger(1, 0.3 + Double(i) * 0.005, 0.5)] }
    f += (0..<30).map { i in [finger(1, 0.45 + Double(i) * 0.005, 0.5), finger(2, 0.7, 0.3)] }   // second finger mid-stroke (late, long stroke)
    f += (0..<20).map { _ in [finger(2, 0.7 + 0.001, 0.3)] }   // first lifts; second remains
    f.append([])
    r = run(f, length: 20)
    check(r.begins == 1 && r.commits == 1, "late second finger is ignored mid-stroke; leftover finger doesn't draw (begins \(r.begins), commits \(r.commits))")

    // 6. Hover threshold (Inklet-style): light touch moves without ink, pressing harder inks.
    f = (0..<20).map { i in [finger(1, 0.3 + Double(i) * 0.005, 0.5, pressure: 10)] }
    f += (0..<20).map { i in [finger(1, 0.4 + Double(i) * 0.005, 0.5, pressure: 30)] }
    f.append([])
    r = run(f, threshold: 25)
    check(r.begins == 1 && r.commits == 1 && r.moves == 19, "hover threshold 25: 20 light frames leave no ink, ink starts at the first hard frame (begins \(r.begins), moves \(r.moves))")
    f = (0..<20).map { i in [finger(1, 0.3 + Double(i) * 0.005, 0.5, pressure: 10)] } + [[]]
    r = run(f, threshold: 25)
    check(r.begins == 0 && r.commits == 0, "hover only: no stroke at all (begins \(r.begins))")
}
