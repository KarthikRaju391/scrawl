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
    var stag = MultiTapDetector()
    _ = stag.frame(Array(fingers(2).prefix(1)), t: 0); _ = stag.frame(fingers(2), t: 0.1)
    check(stag.frame([], t: 0.15) == nil, "detector: fingers landing 100 ms apart are not a tap")
    // Replay.
    let files = (try? FileManager.default.contentsOfDirectory(atPath: "data"))?.filter { $0.hasPrefix("session-2026") && $0.hasSuffix(".jsonl") }.sorted() ?? []
    var frames = 0, singles = 0, doubles = [Int: Int]()
    for f in files {
        guard let text = try? String(contentsOfFile: "data/" + f, encoding: .utf8) else { continue }
        var det = MultiTapDetector()
        var banned = Set<Int32>(), seen = Set<Int32>()
        for line in text.split(separator: "\n") where line.contains("\"touch\"") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let cs = d["c"] as? [[Double]], let m = d["m"] as? Double else { continue }
            frames += 1
            let contacts = cs.map { Contact(id: Int32($0[0]), state: 4, norm: CGPoint(x: $0[2], y: $0[3]), mm: CGPoint(x: $0[2] * 124.8, y: $0[3] * 76.8), pressure: $0[4], size: 0.5, major: 7.5) }
            for c in contacts where !seen.contains(c.id) && GestureEngine.inBand(c.norm, Settings.defaultEdgeGuard) { banned.insert(c.id) }
            let ids = Set(contacts.map(\.id)); seen = ids; banned = banned.intersection(ids)
            switch det.frame(contacts.filter { !banned.contains($0.id) }, t: m) {
            case .doubleTap(let n): doubles[n, default: 0] += 1
            case .tap: singles += 1
            case nil: break
            }
        }
    }
    check(files.count >= 7 && frames > 10_000 && doubles.isEmpty,
          "replay of \(files.count) recorded sessions (\(frames) touch frames): no false double tap (\(singles) multi-finger touches counted as single taps, which do nothing; doubles: \(doubles))")
}
