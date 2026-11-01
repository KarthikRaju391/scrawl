// checks/writing-verify.sh: the formal checks of writing mode (bench/writingVerify.swift, docs/writing-spec.md).
//   writing-verify --test-writing-verify [--explore DEPTH] [--fuzz N] [--replay DIR] [--waits 200,400,1000] [--seed S]
// (--test-… keeps the canvas off the real notebook and settings.)
import AppKit
import Foundation

Diagnostics.off = true
let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let waits = (arg("--waits") ?? "200,400,1000").split(separator: ",").compactMap { Double($0) }
var failures = 0
func out(_ s: String) { print(s); fflush(stdout) }

if let d = arg("--explore").flatMap(Int.init) {
    let onlyStarts = arg("--starts").flatMap(Int.init)
    for w in waits {
        let t0 = Date()
        var total = (states: 0, transitions: 0, recoveries: 0)
        var found: [String: (WModel, [WEv], String)] = [:]
        var starts = WExplore.starts(waitMs: w)
        if let n = onlyStarts { starts = Array(starts.prefix(n)) }
        let lock = NSLock()
        let q = OperationQueue(); q.maxConcurrentOperationCount = Int(arg("--workers") ?? "4") ?? 4   // leave cores for the other checks on this Mac
        let core = args.contains("--core")
        for i in starts.indices { q.addOperation {
            var x = WExplore(waitMs: w, depth: d, alphabet: core ? WExplore.coreAlphabet(w / 1000) : nil)
            x.checkRecovery = !args.contains("--no-recovery")
            x.run(from: starts[i])
            lock.lock()
            total.states += x.states; total.transitions += x.transitions; total.recoveries += x.recoveries
            for (p, path) in x.found where found[p] == nil || found[p]!.1.count > path.count { found[p] = (x.foundStart[p]!, path, x.foundMsg[p]!) }
            lock.unlock()
        } }
        q.waitUntilAllOperationsAreFinished()
        out(String(format: "EXPLORE wait %.0f ms, depth %d, %d starts, %d events: %d distinct states, %d transitions, %d recovery runs, %.0f s",
                   w, d, starts.count, (core ? WExplore.coreAlphabet(w / 1000) : WExplore.fullAlphabet(w / 1000)).count, total.states, total.transitions, total.recoveries, Date().timeIntervalSince(t0)))
        for p in ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8a", "P8b", "P8c"] {
            guard let (start, path, msg) = found[p] else { out("  \(p): holds within the bound"); continue }
            failures += 1
            let small = WExplore.shrink(start, path, prop: p)
            let why = WExplore.replay(start, small, prop: p)?.1 ?? msg
            out("  \(p): COUNTEREXAMPLE (\(small.count) events) from \(wDescribe(start)): \(small.map(wName).joined(separator: ", "))")
            out("      -> \(why)")
        }
    }
}

if let n = arg("--fuzz").flatMap(Int.init) {
    let seed = UInt64(arg("--seed") ?? "1") ?? 1
    let len = Int(arg("--len") ?? "40") ?? 40
    for w in waits {
        let t0 = Date()
        var fz = WFuzz(rng: TestRNG(s: seed &+ UInt64(w)), waitMs: w)
        fz.skip = Set((arg("--skip") ?? "").split(separator: ",").map(String.init))
        var fails: [String: (WFuzz.Start, [WEv], String)] = [:]
        var steps = 0
        for _ in 0..<n {
            let start = WFuzz.Start(widthIdx: Int(fz.rng.next() * 3), zoom: [1, 2, 3, 4, 5][Int(fz.rng.next() * 5)], viewX: [0, 0.3, 0.5, 1][Int(fz.rng.next() * 4)])
            let evs = (0..<len).map { _ in fz.randomEvent() }
            steps += evs.count
            if let (k, p, m) = WFuzz.run(start, evs, waitMs: w), fails[p] == nil || fails[p]!.1.count > k + 1 { fails[p] = (start, Array(evs.prefix(k + 1)), m) }
        }
        out(String(format: "FUZZ wait %.0f ms: %d runs x %d events (%d steps) on the real CanvasView, %.0f s", w, n, len, steps, Date().timeIntervalSince(t0)))
        out("  reached: " + WFuzz.stats.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        WFuzz.stats = [:]
        for p in ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8a", "P8b", "P8c", "model"] {
            guard let (start, evs, _) = fails[p] else { out("  \(p): no failure"); continue }
            failures += 1
            let small = WFuzz.shrink(start, evs, waitMs: w, prop: p)
            let res = WFuzz.run(start, small, waitMs: w)
            out(String(format: "  %@: FAIL, shrunk to %d events from width %.0f%%, zoom %.0f, view x %.1f: %@", p, small.count, ToolState.lineWidths[start.widthIdx] * 100, start.zoom, start.viewX,
                       small.map(wName).joined(separator: ", ")))
            out("      -> \(res.map { "\($0.1): \($0.2)" } ?? "(did not reproduce after shrinking)")")
        }
    }
}

if let dir = arg("--replay") {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("session-2026") && $0.hasSuffix(".jsonl") }.sorted()
    for w in waits {
        var tot = WReplayResult(), byProp: [String: Int] = [:]
        for f in files {
            CanvasView.clickToDraw = false
            let r = wReplaySession(dir + "/" + f, waitMs: w)
            tot.events += r.events; tot.commits += r.commits; tot.moves += r.moves; tot.pendings += r.pendings
            for v in r.violations { byProp[v.0, default: 0] += 1 }
            if !r.violations.isEmpty || args.contains("--verbose") {
                out(String(format: "  %@: %d events, %d commits, %d moves, %d violations", f, r.events, r.commits, r.moves, r.violations.count))
                var shown: [String: Int] = [:]
                for v in r.violations where shown[v.0, default: 0] < 3 { shown[v.0, default: 0] += 1; out(String(format: "      %@ at %.1f s: %@", v.0, v.2, v.1)) }
            }
            tot.violations += r.violations
            for n in r.notes { out("      note: " + n) }
        }
        out(String(format: "REPLAY wait %.0f ms: %d sessions, %d events, %d strokes committed, %d moves, %d violations %@", w, files.count, tot.events, tot.commits, tot.moves,
                   tot.violations.count, byProp.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")))
        if !tot.violations.isEmpty { failures += 1 }
    }
    var checked = 0, moves = 0, bad: [String] = []
    for f in files { let r = wCheckRecordedMoves(dir + "/" + f); checked += r.checked; moves += r.moves; bad += r.bad.map { "\(f) \($0)" } }
    out("RECORDED moves (the app as it was when recorded): \(moves) moves, \(checked) with a logged reason, \(bad.count) against the spec")
    for b in bad.prefix(40) { out("  " + b) }
}

out(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
