// checks/writing-verify.sh: the formal checks of writing mode (bench/writingVerify.swift).
//   writing-verify --test-writing-verify [--explore DEPTH] [--fuzz N] [--replay DIR] [--waits 200,400,1000] [--seed S]
// (--test-… keeps the canvas off the real notebook and settings.)
import AppKit
import Foundation

Diagnostics.off = true
let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let waits = (arg("--waits") ?? "200,400,1000").split(separator: ",").compactMap { Double($0) }
var failures = 0
// --cutoff: the cutoff spec's properties (bench/cutoffSpec.swift) instead of WSpec's; --rule a|b (default b, the spec).
let cutoffMode = args.contains("--cutoff")
if cutoffMode { CutoffSpec.enabled = true; CutoffSpec.rule = arg("--rule") == "a" ? .a : .b }
// --rule a also runs the app on rule A (the view's width when the block started: the build Karthik had on 6 Nov).
if arg("--rule") == "a" { WritingLayout.measureFromView = true }
func props(_ found: [String]) -> [String] {
    let base = cutoffMode ? ["C1", "C3", "C4", "C5:held", "C5:hand", "C5:touch", "C5:undo", "C5:width", "C5:other", "C6", "C7", "C8", "P8c", "model"]
                          : ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8a", "P8b", "P8c", "P9", "model"]
    return base + found.filter { !base.contains($0) }.sorted()
}
func out(_ s: String) { print(s); fflush(stdout) }

if let d = arg("--explore").flatMap(Int.init) {
    let onlyStarts = arg("--starts").flatMap(Int.init)
    for w in waits {
        let t0 = Date()
        var total = (states: 0, transitions: 0, recoveries: 0)
        var found: [String: (WModel, [WEv], String)] = [:]
        var starts = cutoffMode ? WExplore.cutoffStarts(waitMs: w) : WExplore.starts(waitMs: w)
        if let n = onlyStarts { starts = Array(starts.prefix(n)) }
        let lock = NSLock()
        let q = OperationQueue(); q.maxConcurrentOperationCount = Int(arg("--workers") ?? "4") ?? 4   // leave cores for the other checks on this Mac
        let core = args.contains("--core")
        let ccore = cutoffMode && core
        for i in starts.indices { q.addOperation {
            var x = WExplore(waitMs: w, depth: d, alphabet: ccore ? WExplore.cutoffCore(w / 1000) : core ? WExplore.coreAlphabet(w / 1000) : cutoffMode ? WExplore.cutoffAlphabet(w / 1000) : nil)
            x.checkRecovery = !args.contains("--no-recovery")
            x.run(from: starts[i])
            lock.lock()
            total.states += x.states; total.transitions += x.transitions; total.recoveries += x.recoveries
            for (p, path) in x.found where found[p] == nil || found[p]!.1.count > path.count { found[p] = (x.foundStart[p]!, path, x.foundMsg[p]!) }
            lock.unlock()
        } }
        q.waitUntilAllOperationsAreFinished()
        out(String(format: "EXPLORE wait %.0f ms, depth %d, %d starts, %d events: %d distinct states, %d transitions, %d recovery runs, %.0f s",
                   w, d, starts.count, (ccore ? WExplore.cutoffCore(w / 1000) : core ? WExplore.coreAlphabet(w / 1000) : cutoffMode ? WExplore.cutoffAlphabet(w / 1000) : WExplore.fullAlphabet(w / 1000)).count, total.states, total.transitions, total.recoveries, Date().timeIntervalSince(t0)))
        for p in props(Array(found.keys)).filter({ $0 != "model" }) {
            guard let (start, path, msg) = found[p] else { out("  \(p): holds within the bound"); continue }
            failures += 1
            let small = WExplore.shrink(start, path, prop: p)
            let why = WExplore.replay(start, small, prop: p)?.1 ?? msg
            out("  \(p): COUNTEREXAMPLE (\(small.count) events) from \(wDescribe(start)): \(small.map(wName).joined(separator: ", "))")
            out("      -> \(why)")
        }
    }
}

// --trace SEED,RUN,WAIT: the fuzz run RUN (0-based) of that seed and wait, step by step, then the recovery writer's steps.
if let t = arg("--trace")?.split(separator: ",").compactMap({ Double($0) }), t.count == 3 {
    var fz = WFuzz(rng: TestRNG(s: UInt64(t[0]) &+ UInt64(t[2])), waitMs: t[2])
    let len = Int(arg("--len") ?? "40") ?? 40
    var start = WFuzz.Start(widthIdx: 0, zoom: 1, viewX: 0), evs: [WEv] = []
    for _ in 0...Int(t[1]) {
        start = WFuzz.Start(widthIdx: Int(fz.rng.next() * 3), zoom: [0.5, 1, 2.5, 4][Int(fz.rng.next() * 4)], viewX: [-1.3, 0, 0.3, 1, 1.8][Int(fz.rng.next() * 5)])
        evs = (0..<len).map { _ in fz.randomEvent() }
    }
    if let k = arg("--events") { evs = k.split(separator: ";").compactMap { n in fz.alphabet().first { wName($0) == n } } }
    print(WFuzz.run(start, evs, waitMs: t[2], differential: false, log: { print($0) }).map { "\($0)" } ?? "no failure")
}

if args.contains("--p8c-case") {   // the fuzzer's shrunk P8c case, traced
    let r = WFuzz.run(WFuzz.Start(widthIdx: 0, zoom: 1, viewX: -1.3), [.write(.nextLine), .write(.nextLine), .pinch(2.0), .pinch(1.5)], waitMs: 400, differential: false, log: { print($0) })
    print(r.map { "\($0)" } ?? "no failure")
}

if let n = arg("--fuzz").flatMap(Int.init) {
    CutoffSpec.collect = cutoffMode
    let seed = UInt64(arg("--seed") ?? "1") ?? 1
    let len = Int(arg("--len") ?? "40") ?? 40
    for w in waits {
        let t0 = Date()
        var fz = WFuzz(rng: TestRNG(s: seed &+ UInt64(w)), waitMs: w)
        fz.skip = Set((arg("--skip") ?? "").split(separator: ",").map(String.init))
        var fails: [String: (WFuzz.Start, [WEv], String)] = [:]
        var steps = 0
        for _ in 0..<n {
            let start = cutoffMode ? WFuzz.Start(widthIdx: Int(fz.rng.next() * 3), zoom: [0.5, 1, 2.5, 4][Int(fz.rng.next() * 4)], viewX: [-1.3, 0, 0.3, 1, 1.8][Int(fz.rng.next() * 5)])
                                   : WFuzz.Start(widthIdx: Int(fz.rng.next() * 3), zoom: [1, 2, 3, 4, 5][Int(fz.rng.next() * 5)], viewX: [0, 0.3, 0.5, 1][Int(fz.rng.next() * 4)])
            let evs = (0..<len).map { _ in fz.randomEvent() }
            steps += evs.count
            if let (k, p, m) = WFuzz.run(start, evs, waitMs: w, differential: !args.contains("--no-diff")), fails[p] == nil || fails[p]!.1.count > k + 1 { fails[p] = (start, Array(evs.prefix(k + 1)), m) }
        }
        out(String(format: "FUZZ wait %.0f ms: %d runs x %d events (%d steps) on the real CanvasView, %.0f s", w, n, len, steps, Date().timeIntervalSince(t0)))
        out("  reached: " + WFuzz.stats.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        WFuzz.stats = [:]
        if cutoffMode { out(cutoffRunOnReport()); CutoffSpec.runOns = [] }
        for p in props(Array(fails.keys)) {
            guard let (start, evs, _) = fails[p] else { out("  \(p): no failure"); continue }
            failures += 1
            let small = WFuzz.shrink(start, evs, waitMs: w, prop: p)
            let res = WFuzz.run(start, small, waitMs: w, differential: !args.contains("--no-diff"))
            out(String(format: "  %@: FAIL, shrunk to %d events from width %.0f%%, zoom %.2f, view x %.1f: %@", p, small.count, ToolState.lineWidths[start.widthIdx] * 100, start.zoom, start.viewX,
                       small.map(wName).joined(separator: ", ")))
            out("      -> \(res.map { "\($0.1): \($0.2)" } ?? "(did not reproduce after shrinking)")")
        }
    }
}

if let n = arg("--p2").flatMap(Int.init) {
    for w in waits {
        let t0 = Date()
        let r = cutoffP2(runs: n, len: Int(arg("--len") ?? "30") ?? 30, waitMs: w, seed: UInt64(arg("--seed") ?? "1") ?? 1)
        out(String(format: "C2 wait %.0f ms: %d streams x 16 placements (4 camera offsets x 4 start positions on screen) on the real CanvasView, %d cutoff comparisons, %.0f s: %@",
                   w, n, r.checked, Date().timeIntervalSince(t0), r.fails.isEmpty ? "holds" : "FAIL"))
        for f in r.fails.prefix(5) { out("  " + f) }
        if !r.fails.isEmpty { failures += 1 }
    }
}

if let dir = arg("--replay") {
    CutoffSpec.collect = cutoffMode
    let only = arg("--only")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("session-2026") && $0.hasSuffix(".jsonl") && (only == nil || $0.contains(only!)) }.sorted()
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
        if cutoffMode { out(cutoffRunOnReport()); CutoffSpec.runOns = [] }
    }
    var checked = 0, moves = 0, bad: [String] = []
    for f in files { let r = wCheckRecordedMoves(dir + "/" + f); checked += r.checked; moves += r.moves; bad += r.bad.map { "\(f) \($0)" } }
    out("RECORDED moves (the app as it was when recorded): \(moves) moves, \(checked) with a logged reason, \(bad.count) against the spec")
    for b in bad.prefix(40) { out("  " + b) }
}

if args.contains("--cutoff-targeted") {
    for w in waits {
        let bad = cutoffReachChecks(waitMs: w)
        out(String(format: "CUTOFF TARGETED wait %.0f ms: a block started at the canvas's right reach still gets its next line: %@", w, bad.isEmpty ? "PASS" : "FAIL"))
        for b in bad { out("  " + b) }
        if !bad.isEmpty { failures += 1 }
    }
}

if args.contains("--targeted") {
    for w in waits {
        let bad = wSlideChecks(waitMs: w)
        out(String(format: "TARGETED wait %.0f ms: page switch during the new-line slide: %@", w, bad.isEmpty ? "PASS" : "FAIL"))
        for b in bad { out("  " + b) }
        if !bad.isEmpty { failures += 1 }
        let sc = wStaleCountChecks(waitMs: w)
        out(String(format: "TARGETED wait %.0f ms: draw mode left between a commit and the next frame: %@", w, sc.isEmpty ? "PASS" : "FAIL"))
        for b in sc { out("  " + b) }
        if !sc.isEmpty { failures += 1 }
        let ab = wArrowChecks(waitMs: w)
        out(String(format: "TARGETED wait %.0f ms: one arrow press counts as a deliberate move: %@", w, ab.isEmpty ? "PASS" : "FAIL"))
        for b in ab { out("  " + b) }
        if !ab.isEmpty { failures += 1 }
    }
}

out(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
