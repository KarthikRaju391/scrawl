// Replays every recorded touch frame of Karthik's sessions through the tap detector, with the edge guard
// applied as the app does: no two- or three-finger double tap may appear (he never used the gesture, so any
// would be a false undo / redo). Also unit cases for the detector.
import Foundation

func tapReplayChecks(_ check: (Bool, String) -> Void) {
    // Unit cases (times in seconds, positions in mm).
    func fingers(_ n: Int, dx: Double = 0) -> [Contact] {
        (0..<n).map { Contact(id: Int32($0 + 1), state: 4, norm: CGPoint(x: 0.5, y: 0.5), mm: CGPoint(x: 40 + Double($0) * 14 + dx, y: 38), pressure: 30, size: 0.5, major: 7.5) }
    }
    func run(_ seq: [(Double, [Contact])]) -> [MultiTapDetector.Event] {
        var d = MultiTapDetector(); return seq.compactMap { d.frame($0.1, t: $0.0) }
    }
    let quick: [(Double, [Contact])] = [(0, fingers(2)), (0.05, fingers(2)), (0.1, fingers(2)), (0.11, []), (0.3, fingers(2)), (0.38, fingers(2)), (0.39, [])]
    check(run(quick) == [.tap(2), .doubleTap(2)], "detector: two quick two-finger taps = one double tap")
    check(run([(0, fingers(3)), (0.08, fingers(3)), (0.09, []), (0.25, fingers(3)), (0.33, []), ]) == [.tap(3), .doubleTap(3)], "detector: three-finger double tap")
    check(run([(0, fingers(2)), (0.1, fingers(2)), (0.11, []), (0.6, fingers(2)), (0.7, []), ]) == [.tap(2), .tap(2)], "detector: 0.5 s apart = two single taps, no double tap")
    check(run([(0, fingers(2)), (0.1, fingers(2, dx: 4)), (0.11, []), (0.2, fingers(2)), (0.25, []), ]) == [.tap(2)], "detector: a finger moving 4 mm is not a tap")
    check(run([(0, fingers(2)), (0.25, fingers(2)), (0.26, []), (0.3, fingers(2)), (0.35, []), ]) == [.tap(2)], "detector: a 260 ms touch is not a tap")
    check(run([(0, fingers(2)), (0.08, fingers(2)), (0.09, []), (0.25, fingers(2)), (0.43, fingers(2)), (0.44, [])]) == [.tap(2), .doubleTap(2)],
          "detector: a slow second tap (190 ms) is still a double tap, not a hold")
    // Undo scrub: the second tap held still for 0.25 s is a hold (once), and it is no double tap.
    let hold: [(Double, [Contact])] = [(0, fingers(2)), (0.08, fingers(2)), (0.09, []), (0.25, fingers(2)), (0.4, fingers(2)), (0.52, fingers(2)), (0.6, fingers(2, dx: 20)), (0.9, [])]
    check(run(hold) == [.tap(2), .hold(2)], "detector: a double tap whose second tap stays down = one hold (scrub), not an undo (\(run(hold)))")
    check(run([(0, fingers(2)), (0.08, fingers(2)), (0.09, []), (0.25, fingers(2)), (0.42, fingers(2, dx: 3)), (0.6, [])]) == [.tap(2)],
          "detector: a second tap that moves before 0.25 s is neither a hold nor a double tap (it's a pan)")
    check(run([(0, fingers(2)), (0.5, fingers(2)), (0.6, [])]) == [], "detector: two fingers resting 0.5 s without a first tap: no hold")
    var stag = MultiTapDetector()
    _ = stag.frame(Array(fingers(2).prefix(1)), t: 0); _ = stag.frame(fingers(2), t: 0.1)
    check(stag.frame([], t: 0.15) == nil, "detector: fingers landing 100 ms apart are not a tap")
    // Replay, timed by the trackpad's own sensor timestamps (the recorded handling times can bunch up).
    // Sessions from before the gestures existed must give none; sessions recorded with them must give
    // exactly the gesture undos / redos the app logged.
    let files = CommittedData.names("session-2026")
    var frames = 0, singles = 0, falseDoubles = [Int: Int](), matched = 0, mismatched: [String] = [], before = 0, withGestures = 0, holds = 0
    for f in files {
        guard let text = try? String(contentsOfFile: "data/" + f, encoding: .utf8) else { continue }
        var det = MultiTapDetector()
        var banned = Set<Int32>(), seen = Set<Int32>()
        var replayed = [Int: Int](), logged = [Int: Int]()
        var armed: Double?   // after a hold: where the fingers were (x mm); a scrub starts once they slide 4 mm
        for line in text.split(separator: "\n") {
            if line.contains("\"gestureUndo\"") { logged[2, default: 0] += 1; continue }
            if line.contains("\"gestureRedo\"") { logged[3, default: 0] += 1; continue }
            guard line.contains("\"touch\""), let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cs = d["c"] as? [[Double]], let t = d["t"] as? Double else { continue }
            frames += 1
            let contacts = cs.map { Contact(id: Int32($0[0]), state: 4, norm: CGPoint(x: $0[2], y: $0[3]), mm: CGPoint(x: $0[2] * 124.8, y: $0[3] * 76.8), pressure: $0[4], size: 0.5, major: 7.5) }
            for c in contacts where !seen.contains(c.id) && GestureEngine.inBand(c.norm, Settings.defaultEdgeGuard) { banned.insert(c.id) }
            let ids = Set(contacts.map(\.id)); seen = ids; banned = banned.intersection(ids)
            let counted = contacts.filter { !banned.contains($0.id) }
            let cx = counted.isEmpty ? 0 : counted.map(\.mm.x).reduce(0, +) / Double(counted.count)
            if let a = armed {
                if counted.count != 2 { armed = nil } else if abs(cx - a) >= CanvasView.scrubStartMM { holds += 1; armed = nil }
            }
            switch det.frame(counted, t: t) {
            case .doubleTap(let n): replayed[n, default: 0] += 1
            case .tap: singles += 1
            case .hold(2): armed = cx
            case .hold, nil: break
            }
        }
        if logged.isEmpty {
            before += 1
            for (n, k) in replayed { falseDoubles[n, default: 0] += k }
        } else {
            withGestures += 1
            if replayed == logged { matched += replayed.values.reduce(0, +) } else { mismatched.append("\(f): replayed \(replayed), app logged \(logged)") }
        }
    }
    // (6 committed sessions are from before the gestures existed.)
    check(before >= 5 && frames > 10_000 && falseDoubles.isEmpty,
          "replay of \(before) sessions recorded before the gestures (\(frames) touch frames in all): no false double tap (\(singles) multi-finger touches counted as single taps, which do nothing; doubles: \(falseDoubles))")
    check(holds == 0, "replay of every recorded session: no undo scrub would start (\(holds) holds that slid)")
    if withGestures == 0 {
        skip("sessions recorded with the gestures: none is committed to the repo (only sessions from 24 Oct, before the gestures existed); the replay-vs-app undo/redo comparison didn't run")
    } else {
        check(mismatched.isEmpty, "sessions recorded with the gestures (\(withGestures)): the replay finds exactly the \(matched) undos / redos the app made\(mismatched.isEmpty ? "" : ": \(mismatched)")")
    }
}
