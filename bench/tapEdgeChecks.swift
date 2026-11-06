// 0.1.7 taps and the edge guard (BENCH_ONLY=tapedge): a two- or three-finger double tap with one finger in the edge band is an
// undo / redo; a resting edge palm or thumb, a palm landing during a stroke and an edge brush during a pan never are. Only
// API that f5046c7 has too, so the same checks run on both. Plus a replay of Karthik's recorded sessions through the real
// CanvasView (TAPEDGE_OUT: one JSON line per gesture undo / redo / scrub, to compare two builds).
import AppKit
import CoreGraphics
import Foundation

func tapEdgeChecks(_ check: (Bool, String) -> Void) {
    let pad = Multitouch.padMM
    Camera.margin = Settings.defaultEdgeGuard
    func contact(_ id: Int32, _ x: Double, _ y: Double, major: Double = 7.5, size: Double = 0.5) -> Contact {
        Contact(id: id, state: 4, norm: CGPoint(x: x, y: y), mm: CGPoint(x: x * pad.width, y: y * pad.height), pressure: 25, size: size, major: major)
    }
    final class Rig {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
        var acts: [String] = []
        var t = 100.0
        init() {
            c.resumeOnDrawStart = false
            c.tools = ToolState()
            for k in 0..<3 {   // three strokes to undo
                let y = 700.0 - Double(k) * 60
                c.testAddStroke((0...20).map { StrokePoint(p: CGPoint(x: 300 + Double($0) * 10, y: y), pressure: 0.5) })
            }
            c.drawMode = true
            c.onAct = { [unowned self] a, _ in self.acts.append(a) }
        }
        func count(_ a: String) -> Int { acts.filter { $0 == a }.count }
        /// Frames every 8 ms from now for `dur` seconds; `at(dt)` gives the contacts down at dt into it.
        func run(_ dur: Double, _ at: (Double) -> [Contact]) {
            let t0 = t
            var dt = 0.0
            while dt <= dur + 1e-9 { t = t0 + dt; c.handle(at(dt), arrival: t, sensorT: t); dt += 0.008 }
            t = t0 + dur + 0.008
        }
    }
    let edgeX = 0.02   // inside the 5% band (the pad's left edge)
    /// A two-finger double tap: taps 100 ms long, 190 ms apart; `edge` adds an edge finger landing `lead` s before the centre
    /// one (negative: after) and lifting `lag` s after it.
    func doubleTap(_ r: Rig, fingers n: Int, edge: Bool, lead: Double = 0, lag: Double = 0, extra: [Contact] = []) {
        var id: Int32 = 500
        for _ in 0..<2 {
            id += 10
            let a = id, e = id + 5
            let span = 0.1 + max(lead, 0) + max(lag, 0)
            r.run(span) { dt in
                var cs = extra
                let centreStart = max(lead, 0), centreEnd = centreStart + 0.1
                let edgeStart = max(lead, 0) - lead, edgeEnd = centreEnd + lag
                if dt >= centreStart && dt < centreEnd { for k in 0..<(edge ? n - 1 : n) { cs.append(contact(a + Int32(k), 0.45 + 0.1 * Double(k), 0.5)) } }
                if edge && dt >= edgeStart && dt < edgeEnd { cs.append(contact(e, edgeX, 0.5)) }
                return cs
            }
            r.run(0.18) { _ in extra }   // the gap (and the lift frame)
        }
        r.run(0.1) { _ in extra }
    }

    // MARK: should work
    do {
        let r = Rig(); doubleTap(r, fingers: 2, edge: true)
        check(r.count("gestureUndo") == 1 && r.c.doc.strokes.count == 2, "taps: an edge finger + a centre finger, double tap = one undo, no ink (undos \(r.count("gestureUndo")), strokes \(r.c.doc.strokes.count) of 3 -> want 2)")
    }
    do {
        let r = Rig(); doubleTap(r, fingers: 2, edge: true, lead: 0.03)
        check(r.count("gestureUndo") == 1 && r.c.doc.strokes.count == 2, "taps: the edge finger lands 30 ms first: one undo, no ink (undos \(r.count("gestureUndo")), strokes \(r.c.doc.strokes.count))")
    }
    do {
        let r = Rig(); doubleTap(r, fingers: 2, edge: true, lag: 0.04)
        check(r.count("gestureUndo") == 1 && r.c.doc.strokes.count == 2, "taps: the edge finger lifts 40 ms after (the centre finger's dot is committed first): one undo, no dot left (undos \(r.count("gestureUndo")), strokes \(r.c.doc.strokes.count))")
    }
    do {
        let r = Rig(); r.c.undo()
        doubleTap(r, fingers: 3, edge: true)
        check(r.count("gestureRedo") == 1 && r.c.doc.strokes.count == 3, "taps: an edge finger + two centre fingers, double tap = one redo (redos \(r.count("gestureRedo")), strokes \(r.c.doc.strokes.count) -> want 3)")
    }
    do {
        let r = Rig()
        r.run(0.5) { _ in [contact(900, edgeX, 0.3)] }   // a thumb resting at the edge first
        doubleTap(r, fingers: 2, edge: false, extra: [contact(900, edgeX, 0.3)])
        check(r.count("gestureUndo") == 1 && r.c.doc.strokes.count == 2, "taps: a resting edge thumb + a two-finger centre double tap = one undo (undos \(r.count("gestureUndo")), strokes \(r.c.doc.strokes.count))")
    }
    do {
        let r = Rig()
        r.run(0.5) { _ in [contact(901, edgeX, 0.3, major: 14, size: 2)] }   // a palm (palm-sized) resting at the edge
        doubleTap(r, fingers: 2, edge: false, extra: [contact(901, edgeX, 0.3, major: 14, size: 2)])
        check(r.count("gestureUndo") == 1, "taps: a resting edge palm + a two-finger centre double tap = one undo (undos \(r.count("gestureUndo")))")
    }
    do {   // Karthik's case (sessions of 28 Oct - 4 Nov): the second finger near the pad's top edge
        let r = Rig()
        var id: Int32 = 700
        for _ in 0..<2 { id += 2; let a = id
            r.run(0.06) { _ in [contact(a, 0.5, 0.7), contact(a + 1, 0.56, 0.985)] }; r.run(0.18) { _ in [] } }
        r.run(0.1) { _ in [] }
        check(r.count("gestureUndo") == 1 && r.c.doc.strokes.count == 2, "taps: a centre finger + a finger at the top edge, double tap = one undo, no dots (undos \(r.count("gestureUndo")), strokes \(r.c.doc.strokes.count))")
    }
    // MARK: must never trigger
    do {   // the heel of the hand lands at the bottom edge with every touch: a two-finger undo stays an undo (not a three-finger redo)
        let r = Rig()
        var id: Int32 = 720
        for _ in 0..<2 { id += 3; let a = id
            r.run(0.06) { _ in [contact(a, 0.3, 0.8), contact(a + 1, 0.22, 0.56), contact(a + 2, 0.82, 0.0)] }; r.run(0.18) { _ in [] } }
        r.run(0.1) { _ in [] }
        check(r.count("gestureUndo") == 1 && r.count("gestureRedo") == 0, "taps: two centre fingers + the heel at the bottom edge, double tap = one undo, no redo (undos \(r.count("gestureUndo")), redos \(r.count("gestureRedo")))")
    }
    do {   // dots written with one finger while the heel lands at the bottom edge each time: ink, no undo
        let r = Rig()
        var id: Int32 = 740
        for _ in 0..<2 { id += 2; let a = id
            r.run(0.06) { _ in [contact(a, 0.4, 0.6), contact(a + 1, 0.9, 0.002)] }; r.run(0.18) { _ in [] } }
        r.run(0.1) { _ in [] }
        check(r.count("gestureUndo") == 0 && r.c.doc.strokes.count == 5, "taps: two dots with the heel landing at the bottom edge each time: no undo, both dots kept (undos \(r.count("gestureUndo")), strokes \(r.c.doc.strokes.count) of 5)")
    }
    do {
        let r = Rig()
        r.run(3.0) { _ in [contact(902, edgeX, 0.4)] }; r.run(0.1) { _ in [] }
        check(r.count("gestureUndo") + r.count("gestureRedo") + r.count("scrubStart") == 0 && r.c.doc.strokes.count == 3, "taps: a palm resting at the edge alone does nothing")
    }
    do {
        let r = Rig()
        // A palm landing at the edge during a stroke (and staying), twice, as if double tapping with the stroke.
        for k in 0..<2 {
            r.run(0.3) { dt in
                var cs = [contact(910 + Int32(k), 0.3 + dt, 0.6)]
                if dt > 0.05 { cs.append(contact(920 + Int32(k), edgeX, 0.5)) }
                return cs
            }
            r.run(0.15) { _ in [contact(920 + Int32(k), edgeX, 0.5)] }
            r.run(0.05) { _ in [] }
        }
        check(r.count("gestureUndo") + r.count("gestureRedo") == 0 && r.c.doc.strokes.count == 5, "taps: a palm landing at the edge during strokes: no undo, both strokes kept (undos \(r.count("gestureUndo")), strokes \(r.c.doc.strokes.count) of 3 + 2)")
    }
    do {
        let r = Rig()
        let z0 = r.c.camera.center
        for _ in 0..<2 {   // two quick pans with an edge brush in each
            r.run(0.25) { dt in
                var cs = [contact(930, 0.45 - dt * 0.6, 0.5), contact(931, 0.6 - dt * 0.6, 0.5)]
                if dt > 0.02 && dt < 0.1 { cs.append(contact(932, edgeX, 0.6)) }
                return cs
            }
            r.run(0.1) { _ in [] }
        }
        check(r.count("gestureUndo") + r.count("gestureRedo") == 0 && r.c.camera.center != z0, "taps: an edge brush during two quick pans: no undo, the view panned")
    }
    do {
        let r = Rig(); doubleTap(r, fingers: 2, edge: true, lead: 0.1)   // the edge finger landed 100 ms before: resting, not part of it
        check(r.count("gestureUndo") == 0, "taps: an edge contact that landed 100 ms before the centre finger isn't part of the tap (undos \(r.count("gestureUndo")))")
    }
    do {
        let r = Rig()   // writing with a thumb resting at the edge: strokes, no taps
        for k in 0..<4 {
            r.run(0.2) { dt in [contact(950, edgeX, 0.2), contact(960 + Int32(k), 0.3 + dt, 0.6 - 0.05 * Double(k))] }
            r.run(0.12) { _ in [contact(950, edgeX, 0.2)] }
        }
        check(r.count("gestureUndo") + r.count("gestureRedo") == 0 && r.c.doc.strokes.count == 7, "taps: writing with a thumb resting at the edge: 4 strokes, no undo (strokes \(r.c.doc.strokes.count) of 7)")
    }
    tapEdgeReplay(check)
}

/// Every recorded session through the real CanvasView (frames at the sensor's timestamps, draw mode as recorded). Writes each
/// gesture undo / redo / scrub start to TAPEDGE_OUT, for the comparison with another build.
func tapEdgeReplay(_ check: (Bool, String) -> Void) {
    let dir = ProcessInfo.processInfo.environment["TAPEDGE_SESSIONS"] ?? (NSHomeDirectory() + "/code/trackpad-draw/data")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("session-2026") && $0.hasSuffix(".jsonl") }.sorted()
    let out = ProcessInfo.processInfo.environment["TAPEDGE_OUT"].flatMap { p -> FileHandle? in FileManager.default.createFile(atPath: p, contents: nil); return FileHandle(forWritingAtPath: p) }
    var events = [String: Int](), logged = [String: Int]()
    for f in files {
        guard let text = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) else { continue }
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
        c.resumeOnDrawStart = false
        c.tools = ToolState()
        for k in 0..<200 { c.testAddStroke((0...5).map { StrokePoint(p: CGPoint(x: 100 + Double($0) * 5, y: 900 - Double(k) * 3), pressure: 0.5) }) }   // history to undo
        var t = 0.0, m0: Double?
        c.onAct = { a, _ in
            guard ["gestureUndo", "gestureRedo", "scrubStart", "tapInkUndone"].contains(a) else { return }
            events[a, default: 0] += 1
            let line: [String: Any] = ["file": f, "t": (t * 1000).rounded() / 1000, "event": a]
            if let out, let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) { out.write(d); out.write(Data("\n".utf8)) }
        }
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let k = o["k"] as? String else { continue }
            if k == "act", let a = o["a"] as? String {
                if a == "drawMode" { c.drawMode = o["on"] as? Bool ?? false }
                if a == "gestureUndo" || a == "gestureRedo" { logged[a, default: 0] += 1 }
                continue
            }
            guard k == "touch", let cs = o["c"] as? [[Double]], let st = o["t"] as? Double else { continue }
            if m0 == nil { m0 = st }
            t = st - (m0 ?? 0)
            if !c.drawMode { c.drawMode = true }
            let contacts = cs.compactMap { a -> Contact? in
                guard a.count >= 5 else { return nil }
                return Contact(id: Int32(a[0]), state: Int32(a[1]), norm: CGPoint(x: a[2], y: a[3]), mm: CGPoint(x: a[2] * 124.8, y: a[3] * 76.8), pressure: a[4], size: 0.5, major: 7.5)
            }
            c.handle(contacts, arrival: st, sensorT: st)
        }
    }
    try? out?.close()
    print("TAPEDGE replay: \(files.count) sessions; events \(events.sorted { $0.key < $1.key }); the app logged when recorded \(logged.sorted { $0.key < $1.key })")
    check(!files.isEmpty, "taps replay: \(files.count) recorded sessions replayed through the canvas")
}
