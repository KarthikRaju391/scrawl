// Scratch-out: a quick zig-zag over ink erases what it covers, and the zig-zag itself goes too, in one undo
// step. Tuned on every committed stroke Karthik recorded (tools/scratch_analysis.py: 6,056 strokes, none
// detected; 97.5% of 2,000 synthetic scratches detected). Shape is measured in pad millimetres, so it
// doesn't depend on the zoom:
//   legs      the stroke projected on its main axis, split where it turns back (hysteresis 30% of the extent)
//   big legs  legs at least 55% of the extent: a scratch has 4 or more (3 turn-backs)
//   ratio     path length / extent along the axis, >= 3.2
//   speed     >= 60 mm/s (writing a letter is slower and smaller)
//   loops     net turning under 0.75 turns: circling (a wheel drawn round and round) isn't scratching
// Then it must lie on ink: >= 60% of its points within 1.5 mm of strokes already on the page. Pen and marker
// only: a highlighter zig-zag over text is highlighting.
import CoreGraphics

enum ScratchOut {
    struct Features { var bigLegs = 0, legs = 0; var ratio = 0.0, speed = 0.0, extent = 0.0, loops = 0.0 }

    static let minBigLegs = 4, minRatio = 3.2, minSpeed = 60.0, minExtent = 4.0, maxLoops = 0.75, minOverlap = 0.6, reachMM = 1.5
    /// Settings › Scratch to erase (on by default).
    nonisolated(unsafe) static var enabled = true

    static func features(mm pts: [CGPoint], t: [Double]) -> Features? {
        let n = pts.count
        guard n >= 6, t.count == n else { return nil }
        let mx = pts.reduce(0) { $0 + $1.x } / Double(n), my = pts.reduce(0) { $0 + $1.y } / Double(n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts { sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my); sxy += (p.x - mx) * (p.y - my) }
        let ang = 0.5 * atan2(2 * sxy, sxx - syy), ux = cos(ang), uy = sin(ang)
        let s = pts.map { ($0.x - mx) * ux + ($0.y - my) * uy }
        let ext = s.max()! - s.min()!
        guard ext > 0 else { return nil }
        let h = 0.3 * ext
        var legs: [Double] = [], start = s[0], extreme = s[0], dir = 0
        for v in s.dropFirst() {
            if dir >= 0 && v > extreme { extreme = v; if v - start > h { dir = 1 } }
            else if dir <= 0 && v < extreme { extreme = v; if start - v > h { dir = -1 } }
            if dir == 1 && extreme - v > h { legs.append(extreme - start); start = extreme; extreme = v; dir = -1 }
            else if dir == -1 && v - extreme > h { legs.append(start - extreme); start = extreme; extreme = v; dir = 1 }
        }
        legs.append(abs(extreme - start))
        var f = Features()
        f.legs = legs.count
        f.bigLegs = legs.filter { $0 >= 0.55 * ext }.count
        var len = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) { len += hypot(b.x - a.x, b.y - a.y) }
        f.ratio = len / ext
        f.speed = len / max(t[n - 1] - t[0], 1e-3)
        f.extent = ext
        // Net turning on points 0.5 mm apart; a cusp (turning back) has no side and doesn't count.
        var rs = [pts[0]], acc = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) { acc += hypot(b.x - a.x, b.y - a.y); if acc >= 0.5 { rs.append(b); acc = 0 } }
        var net = 0.0
        if rs.count >= 3 {
            for i in 2..<rs.count {
                let a = rs[i - 2], b = rs[i - 1], c = rs[i]
                var d = atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x)
                d = (d + .pi).truncatingRemainder(dividingBy: 2 * .pi); if d < 0 { d += 2 * .pi }; d -= .pi
                if abs(d) < 0.8 * .pi { net += d }
            }
        }
        f.loops = abs(net) / (2 * .pi)
        return f
    }

    static func shapeMatches(_ f: Features?) -> Bool {
        guard let f else { return false }
        return f.bigLegs >= minBigLegs && f.ratio >= minRatio && f.speed >= minSpeed && f.extent >= minExtent && f.loops < maxLoops
    }

    /// The strokes a scratch (canvas points) erases: the ones it touches whose bounds lie mostly inside the
    /// scratch's (inflated a little). Nil unless enough of the scratch lies on ink.
    static func covered(scratch: [CGPoint], in strokes: [Stroke], reach: Double) -> [Stroke]? {
        guard !scratch.isEmpty else { return nil }
        var box = CGRect.null
        for p in scratch { box = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        let near = strokes.filter { $0.bounds.insetBy(dx: -reach, dy: -reach).intersects(box.insetBy(dx: -reach, dy: -reach)) }
        guard !near.isEmpty else { return nil }
        let onInk = scratch.filter { p in near.contains { $0.hit(p, r: reach) } }.count
        guard Double(onInk) / Double(scratch.count) >= minOverlap else { return nil }
        let zone = box.insetBy(dx: -box.width * 0.15 - reach, dy: -box.height * 0.15 - reach)
        let hitStrokes = near.filter { s in
            let inside = s.bounds.intersection(zone)
            let a = s.bounds.width * s.bounds.height
            let mostlyInside = a <= 0 ? zone.contains(CGPoint(x: s.bounds.midX, y: s.bounds.midY)) : (inside.isNull ? 0 : inside.width * inside.height) / a >= 0.5
            return mostlyInside && scratch.contains { s.hit($0, r: reach) }
        }
        return hitStrokes.isEmpty ? nil : hitStrokes
    }
}
