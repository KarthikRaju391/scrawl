// The writing-mode cutoff spec (docs/writing-cutoff-spec.md) as an oracle: properties C1-C8, checked on every event
// by the model explorer (WModel, which calls the real WritingLayout), the fuzzer of the real CanvasView, and the replay
// of recorded sessions (writing-verify --cutoff). Independent of WSpec: its own constants, its own block width (taken
// from the camera when it sees a block start), its own hand-move measure, its own clock of contacts.
//
//   C1 fixed cutoff      cutoff = blockStart + w x Vw0 (rule B, the spec: Vw0 = the screen's width at 100% zoom, the page
//                        width; rule A, --rule a: the view's width in canvas units when the block started),
//                        unchanged by anything but a new block or the width setting
//   C2 viewport-free     (cutoffP2, a metamorphic runner) the cutoff relative to the start is the same wherever the start
//                        sits on screen and wherever the camera is
//   C3 block start       changes only by the rules (writing mode on, a page change, writing well above/below the line,
//                        a deliberate hand move away); never by the app's next-line or follow moves
//   C4 next line         scheduled at a commit iff the line's ink is at or past cutoff - 3% of the line; a counted touch
//                        cancels it; it fires only after the wait with no counted touch; it goes to (blockStart, a line down)
//   C5 progress          ink past the marker + a pause of the wait with no counted contact => the move. Split by what
//                        blocked it: C5:held, C5:hand, C5:touch, C5:undo, C5:width, C5:other
//   C6 guide             target strength > 0 iff the line's ink is within 15% of the line of the cutoff; hidden after the move
//   C7 edge              edge-band contacts never cancel, reschedule or hold back a move
//   C8 no stuck states   nothing pending past its time with no counted touch; writing mode off clears the block, the
//                        line and the pending move (P8c, the drivers' "a writer carrying on gets a move", is reported too)
import CoreGraphics
import Foundation

struct CutoffSpec {
    nonisolated(unsafe) static var enabled = false
    /// The rule for the line's length. B (Karthik, 6 Nov evening, the spec): the setting x the screen's width at 100% zoom
    /// (the page width, 1,600 units), whatever the zoom. A (0.1.7 build 13): the setting x the view's width when the block started.
    enum Rule { case a, b }
    nonisolated(unsafe) static var rule = Rule.b
    /// Vw0 for a block starting with this camera.
    static func blockView(_ c: Camera) -> Double { rule == .b ? wPage.width : c.visible.width }
    /// Collect run-on statistics (fuzz and replay; off in the explorer, whose branches would double count).
    nonisolated(unsafe) static var collect = false
    nonisolated(unsafe) static var runOns: [(over: Double, causes: String)] = []
    static let nearMarker = 0.03, showWithin = 0.15, deliberate = 0.10, newRun = 0.10, inset = 0.05, fromTop = 0.575
    /// Clock granularity: the fuzzer ticks every 8 ms; recorded sessions have gaps between records.
    static let slack = 0.02
    var waitMs = 400.0

    struct Ghost {
        var seeded = false
        var start: Double?            // the block's start (C3 polices how it changes)
        var vw0: Double?              // the view's width when it started (the oracle's own capture)
        var hand = 0.0                // sideways moves of the view by hand since the last commit or app move
        var lastUp: Double?           // when the last counted contact lifted
        var dueSince: Double?         // since when the open line's ink has been past its marker
        var dropCause: String?        // what last dropped (or failed to re-arm) a due line's move
        var schedAt: Double?          // when the pending move (or follow) was scheduled
        var touchedSinceSched = false
        var lineOver: Double?         // run-on: the line's ink past the cutoff, in line widths (max so far)
        var lineCauses: Set<String> = []
    }
    var g = Ghost()

    func hash(into h: inout Hasher, clock: Double) {
        func q(_ d: Double?) { if let d { h.combine(Int((d * 1000).rounded())) } else { h.combine(Int.min) } }
        q(g.start); q(g.vw0); q(g.hand); q(g.lastUp.map { clock - $0 }); q(g.dueSince.map { clock - $0 }); h.combine(g.dropCause)
        q(g.schedAt.map { clock - $0 }); h.combine(g.touchedSinceSched)
    }

    /// The amendment (cutoff-verify's reach fix): the cutoff never past the furthest ink can go at any zoom
    /// (WritingLayout.reachRight). --no-reach-cap: the spec without it (for builds before the fix).
    nonisolated(unsafe) static var reachCap = !CommandLine.arguments.contains("--no-reach-cap")
    static func capped(_ start: Double, _ bw: Double, _ cam: Camera) -> Double {
        reachCap ? min(start + bw, max(wPage.width * (1 + Camera.reach) + cam.visible.width * 0.45, start)) : start + bw
    }
    static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol * max(1, abs(a), abs(b)) }

    static func countedTouch(_ e: WEv) -> Bool { switch e { case .write, .down, .pan, .pinch, .scratch: return true; default: return false } }
    static func handMove(_ e: WEv) -> Bool { switch e { case .pan, .pinch, .arrow, .scroll: return true; default: return false } }
    static func cause(_ e: WEv) -> String {
        switch e {
        case .pan, .pinch, .arrow, .scroll: return "hand"
        case .write, .down, .up, .scratch: return "touch"
        case .undo, .redo: return "undo"
        case .width: return "width"
        default: return "other"
        }
    }

    /// The stroke is well above or below the line it would join (a new line there), loosely: a necessary condition for C3.
    static func wellOff(_ o: WObs, _ s: CGRect) -> Bool {
        guard let l = o.lineInk ?? o.prevLine else { return false }
        let vh = o.cam.visible.height
        return abs(s.midY - l.midY) > max(l.height, vh * 0.12) * 1.2 * (1 - 1e-9) || s.midY < l.minY
    }

    mutating func check(_ e: WEv, pre: WObs, post: WObs, committed: CGRect?) -> [(String, String)] {
        var bad: [(String, String)] = []
        func fail(_ p: String, _ m: String) { bad.append((p, m)) }
        let wait = waitMs / 1000
        let moved = post.newLines - pre.newLines, followed = post.follows - pre.follows
        let auto = moved > 0 && e != .ret
        if !g.seeded { g.seeded = true; g.start = pre.runStart; g.vw0 = pre.runStart == nil ? nil : (Self.rule == .b ? wPage.width : pre.blockView) }

        // Contacts: a counted touch in this event, and when the last one lifted.
        let touched = Self.countedTouch(e) || post.counted > 0 || pre.counted > 0
        if touched && post.counted == 0 { g.lastUp = post.clock }
        if Self.handMove(e) { g.hand += abs(post.cam.center.x - pre.cam.center.x); if g.dropCause == "touch" { g.dropCause = "hand" } }   // the touch that dropped it was a pan or pinch

        // C3: the block's start changes only by the rules.
        var fresh = false
        if pre.runStart != post.runStart {
            if post.runStart == nil {
                switch e { case .toggle, .page: break; default: fail("C3", "block ended by \(wName(e))") }
            } else if let s = committed, post.writing {
                if !Self.near(post.runStart!, s.minX) { fail("C3", String(format: "block start %.1f, not the stroke's start %.1f", post.runStart!, s.minX)) }
                let vw = pre.cam.visible.width
                let ok = pre.runStart == nil || !pre.writing || Self.wellOff(pre, s) ||
                    (g.hand >= Self.deliberate * vw * (1 - 1e-9) && (abs(s.minX - pre.runStart!) > Self.newRun * wPage.width * (1 - 1e-9) ||
                        pre.lineInk.map { l in s.maxX < l.minX - max(l.height * 1.5, vw * 0.08) * (1 - 1e-9) } == true))   // away: 10% of the page, or left of the line
                if !ok { fail("C3", String(format: "block start %.1f -> %.1f with no cause (hand move %.0f%% of the view, stroke %.1f-%.1f, line %@)", pre.runStart!, s.minX,
                                           g.hand / vw * 100, s.minX, s.maxX, pre.lineInk.map { String(format: "%.0f-%.0f y %.0f", $0.minX, $0.maxX, $0.midY) } ?? "none")) }
                fresh = true
            } else if e == .redo, pre.runStart == nil, post.writing, let l = post.lineInk, Self.near(post.runStart!, l.minX) {
                fresh = true   // 3cfa1a5: a redo with no block (writing mode off/on, a page change, Clear) starts one at the ink it brings back
            } else {
                fail("C3", "block start changed by \(wName(e)) (\(pre.runStart.map { String(format: "%.1f", $0) } ?? "nil") -> \(post.runStart.map { String(format: "%.1f", $0) } ?? "nil"))\(auto ? ", the app's own move" : "")")
                fresh = true
            }
        } else if let s = committed, post.writing, pre.writing, WSpec.expectedBlock(pre, s, hand: g.hand).fresh {
            fresh = true   // a new block at exactly the old start's x (writing well above it): it takes the zoom now
        }
        if fresh || post.runStart != g.start || !post.writing {
            g.start = post.writing ? post.runStart : nil
            g.vw0 = g.start == nil ? nil : Self.blockView(pre.cam)
        }

        // C1: the cutoff, from the start and the width of the view the block started in.
        var cutoff: Double?, bw: Double?
        if let s = g.start, let v0 = g.vw0 { bw = post.width * v0; cutoff = Self.capped(s, bw!, post.cam) }
        if post.writing {
            switch (post.limit, cutoff) {
            case let (lim?, c?): if !Self.near(lim, c) { fail("C1", String(format: "cutoff %.2f, want start %.2f + %.0f%% x Vw0 %.2f = %.2f (zoom now %.2f, view x %.0f-%.0f)", lim, g.start!, post.width * 100, g.vw0!, c, post.cam.zoom, post.cam.visible.minX, post.cam.visible.maxX)) }
            case (nil, nil): break
            default: fail("C1", "cutoff \(post.limit.map { String(format: "%.1f", $0) } ?? "none") with block start \(g.start.map { String(format: "%.1f", $0) } ?? "none")")
            }
            // The reach cap (the amendment) moves the cutoff with the zoom, and only while it caps it.
            let s0 = g.start ?? 0, v0 = g.vw0 ?? 0
            let capChanged = Self.reachCap && ((pre.limit ?? .infinity) < s0 + pre.width * v0 - 1e-6 || (post.limit ?? .infinity) < s0 + post.width * v0 - 1e-6)
            if pre.writing && !fresh && !capChanged && pre.runStart == post.runStart && pre.width == post.width, let a = pre.limit, let b = post.limit, !Self.near(a, b) {
                fail("C1", String(format: "cutoff moved %.2f -> %.2f during %@ (same block, same setting)", a, b, wName(e)))
            }
        }
        let marker = cutoff.map { $0 - Self.nearMarker * bw! }
        let right = WSpec.liveMaxX(post)

        // C4: the next line.
        if post.pendingLiftAt != nil && post.pendingFollow != nil { fail("C4", "two moves pending") }
        if (committed != nil || e == .redo), post.writing, !post.lineHeld, let m = marker, let r = right ?? committed.map({ Double($0.maxX) }) {
            let want = r >= m - 1e-6
            let has = post.pendingLiftAt != nil || moved > 0
            if want != has { fail("C4", String(format: "line's ink to %.2f, marker %.2f (cutoff %.2f): next line %@, want %@ [%@]", r, m, cutoff!, has ? "pending" : "none", want ? "pending" : "none", wName(e))) }
        }
        if Self.countedTouch(e), let t = pre.pendingLiftAt, post.pendingLiftAt == t { fail("C4", "a counted touch (\(wName(e))) left the pending move in place") }
        if auto || followed > 0 {
            if let t = g.schedAt {
                if post.clock - t < wait - 1e-6 { fail("C4", String(format: "move %.0f ms after it was scheduled (wait %.0f ms)", (post.clock - t) * 1000, waitMs)) }
                if g.touchedSinceSched { fail("C4", "move after a counted touch since it was scheduled") }
            } else { fail("C4", "a move with nothing scheduled (\(wName(e)))") }
            if post.counted > 0 { fail("C4", "a move with a counted finger down") }
        }
        if auto, let s = g.start ?? pre.runStart, let l = pre.lineInk {
            let v = post.cam.visible
            var c = post.cam
            c.center = CGPoint(x: s - Self.inset * v.width + v.width / 2, y: l.midY - max(l.height * 1.35, v.height * 0.12) + (Self.fromTop - 0.5) * v.height)
            c.clamp()
            if !Self.near(post.cam.center.x, c.center.x) || !Self.near(post.cam.center.y, c.center.y) {
                fail("C4", String(format: "next line went to (%.1f, %.1f), want (%.1f, %.1f): the block's start %.1f at 5%% of the view, one line down", post.cam.center.x, post.cam.center.y, c.center.x, c.center.y, s))
            }
        }

        // C7 (edge contacts) and C8 (stuck pending).
        if e == .edgeDown || e == .edgeUp, let t = pre.pendingLiftAt, post.pendingLiftAt != t, moved == 0 {
            fail("C7", "an edge contact (\(wName(e))) \(post.pendingLiftAt == nil ? "cancelled" : "rescheduled") the pending move")
        }
        if let t = post.pendingLiftAt, post.counted == 0, post.clock - t >= wait + Self.slack {
            fail(post.edge > 0 ? "C7" : "C8", String(format: "a move still pending %.0f ms after its lift with no counted touch%@", (post.clock - t) * 1000, post.edge > 0 ? " (an edge contact down)" : ""))
        }
        if !post.writing {
            if post.runStart != nil || post.lineInk != nil || post.pendingLiftAt != nil || post.pendingFollow != nil || post.prevLine != nil || post.lineHeld || post.limit != nil || (post.guide ?? 0) > 0 {
                fail("C8", "writing mode off but state left: block \(post.runStart != nil), line \(post.lineInk != nil), pending \(post.pendingLiftAt != nil || post.pendingFollow != nil), previous line \(post.prevLine != nil), held \(post.lineHeld), guide \(post.limit != nil)")
            }
        }

        // C6: the guide.
        if post.writing, let gd = post.guide, let c = cutoff, let b = bw {
            let r = post.inkRight ?? post.lineInk.map { Double($0.maxX) }   // with the stroke being drawn
            let want = r.map { c - $0 < Self.showWithin * b - 1e-6 } ?? false
            let edgeCase = r.map { abs(c - $0 - Self.showWithin * b) < 1e-6 } ?? false
            if !edgeCase && want != (gd > 1e-9) { fail("C6", String(format: "guide %@, want %@: ink to %@, cutoff %.1f, show within %.1f%@", gd > 1e-9 ? "shown" : "hidden", want ? "shown" : "hidden", r.map { String(format: "%.1f", $0) } ?? "none", c, Self.showWithin * b, auto ? " (just after the move)" : "")) }
        }

        // C5: progress.
        if let t = pre.pendingLiftAt, post.pendingLiftAt == nil, moved == 0 { g.dropCause = Self.cause(e) }
        let due = post.writing && post.lineInk != nil && moved == 0 && marker != nil && (right ?? -.infinity) >= marker! - 1e-6
        if due {
            if g.dueSince == nil { g.dueSince = post.clock; if post.pendingLiftAt == nil && committed == nil && e != .redo { g.dropCause = Self.cause(e) } }
            if post.lineHeld { g.lineCauses.insert("held") }
            if let c = g.dropCause { g.lineCauses.insert(c) }
            let quiet = max(g.dueSince!, g.lastUp ?? -.infinity)
            if post.counted == 0, post.pendingLiftAt == nil, post.clock - quiet >= wait + Self.slack {
                let why = post.lineHeld ? "held" : (g.dropCause ?? "other")
                fail("C5:" + why, String(format: "ink to %.1f past the marker %.1f (cutoff %.1f), quiet %.0f ms, no move: %@", right ?? .nan, marker!, cutoff!, (post.clock - quiet) * 1000,
                                         post.lineHeld ? "the line is held (written on after its move: lineContinued)" : "the move was dropped by \(g.dropCause ?? "?") and nothing re-armed it"))
            }
        } else { g.dueSince = nil; if post.pendingLiftAt == nil { g.dropCause = nil } }
        if committed != nil || e == .redo, post.pendingLiftAt != nil { g.dropCause = nil }

        // Run-on: how far a line's ink got past its cutoff, and what besides writing on let it.
        if Self.collect {
            if let r = right, let c = cutoff, let b = bw, post.lineInk != nil { g.lineOver = max(g.lineOver ?? -.infinity, (r - c) / b) }
            if post.lineInk == nil || fresh, let o = g.lineOver {
                if o > 0 { Self.runOns.append((o, g.lineCauses.sorted().joined(separator: "+"))) }
                g.lineOver = nil; g.lineCauses = []
            }
        }

        // The scheduling monitor.
        if touched { g.touchedSinceSched = true }
        let newSched = (post.pendingLiftAt != nil && post.pendingLiftAt != pre.pendingLiftAt) || (post.pendingFollow != nil && (pre.pendingFollow != post.pendingFollow || committed != nil || e == .redo))
        if newSched { g.schedAt = post.pendingLiftAt ?? post.clock; g.touchedSinceSched = false }
        else if post.pendingLiftAt == nil && post.pendingFollow == nil { g.schedAt = nil }
        if (committed != nil && post.writing) || auto || followed > 0 { g.hand = 0 }
        return bad
    }
}

// MARK: - C2, metamorphic: the same writing, started at different places on screen and with the camera elsewhere

/// Runs the same event stream on fresh real canvases that differ only in where the camera is (page widths left or right)
/// and where on screen the block's first stroke lands. Within the first block (until either run's block start moves),
/// the cutoff relative to the start must be the same in every run, and equal to the setting x the view's width then.
func cutoffP2(runs: Int, len: Int, waitMs: Double, seed: UInt64) -> (checked: Int, fails: [String]) {
    var rng = TestRNG(s: seed)
    var fz = WFuzz(rng: TestRNG(s: seed &+ 7), waitMs: waitMs)
    var fails: [String] = [], checked = 0
    for _ in 0..<runs {
        let zoom = [0.5, 1, 2.5, 4][Int(rng.next() * 4)], wi = Int(rng.next() * 3)
        let evs = (0..<len).map { _ in fz.randomEvent() }.filter { e in
            switch e { case .page, .toggle, .undo, .redo, .scratch: return false; default: return true } }   // events that end or rewrite the block
        var rels: [[Double?]] = []
        var labels: [String] = []
        for off in [-1.4, 0.0, 0.7, 1.6] { for f in [0.05, 0.35, 0.65, 0.92] {
            let real = WReal(waitMs: waitMs, widthIdx: wi, zoom: zoom, viewX: 0)
            let v0 = real.canvas.camera.visible
            real.canvas.setVisibleForReplay(x: v0.minX + off * wPage.width, y: v0.minY, w: v0.width, z: zoom)
            let v = real.canvas.camera.visible
            let h = min(max(v.height * 0.06, 6), 60)
            let first = CGRect(x: v.minX + f * v.width, y: v.maxY - WritingLayout.lineFromTop * v.height - h / 2, width: min(h * 3, v.maxX - v.minX - f * v.width - 1), height: h)
            _ = real.apply(.write(.at(f)), place: first)
            guard let s0 = real.obs.runStart else { fails.append("no block after the first stroke"); continue }
            var rel: [Double?] = [real.obs.limit.map { $0 - s0 }], widths: [Double] = [real.obs.width], cams: [Camera] = [real.obs.cam]
            for e in evs {
                let pre = real.obs
                let place: CGRect? = { switch e { case .write(let p), .down(let p): return wPlace(p, pre); default: return nil } }()
                if case .write = e, place == nil { rel.append(nil); widths.append(pre.width); cams.append(pre.cam); continue }
                if case .down = e, place == nil { rel.append(nil); widths.append(pre.width); cams.append(pre.cam); continue }
                _ = real.apply(e, place: place)
                let o = real.obs
                rel.append(o.runStart == s0 ? o.limit.map { $0 - s0 } : nil); widths.append(o.width); cams.append(o.cam)
                if o.runStart != s0 { break }
            }
            let vw0 = CutoffSpec.rule == .b ? wPage.width : wPage.width / zoom
            rels.append(rel.indices.map { k in rel[k].flatMap { r in CutoffSpec.near(r, widths[k] * vw0) ? r / widths[k] : (CutoffSpec.reachCap ? nil : r / widths[k]) } }); labels.append(String(format: "camera %+.1f page widths, start at %.0f%% of the view", off, f * 100))
            for (k, r) in rel.enumerated() { if let r { checked += 1; let wnt = CutoffSpec.capped(s0, widths[k] * vw0, cams[k]) - s0; if !CutoffSpec.near(r, wnt) {
                fails.append(String(format: "%@, zoom %.2f: after event %d the cutoff is start %+.2f, want %+.2f (%.0f%% x %.1f)", labels.last!, zoom, k, r, wnt, widths[k] * 100, vw0)); break } } }
        } }
        // Across runs: the same relative cutoff per unit of setting (the measure) at every step all of them reach within their
        // first block (the setting itself can differ: a width change is refused while one run has a finger held).
        let n = rels.map(\.count).min() ?? 0
        for k in 0..<n {
            let vals = rels.compactMap { $0[k] }
            if vals.count == rels.count, let a = vals.min(), let b = vals.max(), !CutoffSpec.near(a, b) {
                fails.append(String(format: "zoom %.2f: after event %d the cutoff relative to the start, per unit of setting, differs between runs: %.2f to %.2f", zoom, k, a, b)); break
            }
        }
    }
    return (checked, fails)
}

// MARK: - The explorer's grid for the cutoff spec

extension WExplore {
    /// Starts: 3 settings x 4 zooms (50% to 400%) x 3 camera positions (left of the page, at its left, past its right).
    static func cutoffStarts(waitMs: Double) -> [WModel] {
        var out: [WModel] = []
        for wi in 0..<3 { for z in [0.5, 1.0, 2.5, 4.0] { for off in [-1.3, 0.0, 1.1] {
            var m = WModel(); m.waitMs = waitMs; m.widthIdx = wi
            m.cam.zoom = z; m.cam.home()
            m.cam.center.x += off * wPage.width; m.cam.clamp()
            out.append(m)
        } } }
        return out
    }
    /// Blocks started at 5%, 50% and 90% of the view; words up to, into and across the marker; the pause; edge contacts;
    /// a held finger; hand pans and pinches; arrows; undo/redo; Return; page; writing mode off/on; the setting.
    static func cutoffAlphabet(_ W: Double) -> [WEv] {
        [.write(.at(0.05)), .write(.at(0.5)), .write(.at(0.9)), .write(.next), .write(.short), .write(.zone), .write(.cross), .write(.idot),
         .write(.nextLine), .write(.prevEnd), .write(.farRight), .write(.above), .tick(0.5 * W), .tick(1.1 * W), .edgeDown, .edgeUp,
         .down(.next), .up, .pan(0.3), .pan(-0.3), .pinch(1.5), .pinch(1 / 1.5), .arrow(1), .undo, .redo, .ret, .page, .toggle, .width(0), .width(2)]
    }
    /// The events around the move itself, for deeper runs.
    static func cutoffCore(_ W: Double) -> [WEv] {
        [.write(.at(0.5)), .write(.next), .write(.zone), .write(.cross), .write(.prevEnd), .write(.nextLine), .tick(1.1 * W), .edgeDown,
         .down(.next), .up, .pan(0.3), .pinch(1.5), .undo, .redo]
    }
}

/// Run-on: how far lines' ink went past their cutoff (in line widths), by what besides writing on allowed it.
func cutoffRunOnReport() -> String {
    let r = CutoffSpec.runOns
    guard !r.isEmpty else { return "  run-on: no line went past its cutoff" }
    var byCause: [String: [Double]] = [:]
    for x in r { byCause[x.causes.isEmpty ? "writing on (every gap under the wait)" : x.causes, default: []].append(x.over) }
    return "  run-on past the cutoff (lines, median / max in line widths): " + byCause.sorted { $0.key < $1.key }.map { k, v in
        let s = v.sorted(); return String(format: "%@: %d, %.2f / %.2f", k, s.count, s[s.count / 2], s.last!) }.joined(separator: "; ")
}

// MARK: - Targeted checks on the real canvas

/// A block started where its cutoff is past the furthest the view can go (the camera's reach): the follow stops at the
/// reach, ink can't get to the marker, and no next line ever comes. Writes words to the right (panning on when out of
/// room) for 60 words; returns failures.
func cutoffReachChecks(waitMs: Double) -> [String] {
    var bad: [String] = []
    // The block's first word near the view's left, and (the corner the first fix missed) at its very right.
    for (wi, zoom, f) in [(0, 2.5, 0.05), (2, 1.0, 0.05), (1, 4.0, 0.05), (2, 2.5, 0.9), (2, 4.0, 0.88), (0, 1.0, 0.92)] {
        let real = WReal(waitMs: waitMs, widthIdx: wi, zoom: zoom, viewX: 0)
        var c = real.canvas.camera; c.center.x = .infinity; c.clamp()   // as far right as the view goes
        let v = c.visible
        real.canvas.setVisibleForReplay(x: v.minX, y: v.minY, w: v.width, z: zoom)
        let h = min(max(v.height * 0.06, 6), 60)
        _ = real.apply(.write(.at(f)), place: CGRect(x: v.minX + f * v.width, y: v.maxY - 0.5 * v.height - h / 2, width: min(h * 3, v.maxX - v.minX - f * v.width - 1), height: h))
        let n0 = real.canvas.newLineCount - (real.obs.pendingLiftAt != nil || real.canvas.newLineCount > 0 ? 0 : 0)
        let wait = waitMs / 1000
        let before = real.canvas.newLineCount
        real.tick(1.5 * wait)   // the pause after the first word (it may already be past the marker)
        if real.canvas.newLineCount > before { continue }
        var words = 0, steps = 0
        while words < 60 && steps < 200 && real.canvas.newLineCount == n0 {
            steps += 1
            let o = real.obs
            if let r = wPlace(.next, o), r.maxX <= o.cam.visible.maxX + o.cam.visible.width * 0.05 + 1e-6 { _ = real.apply(.write(.next), place: r); words += 1 } else { _ = real.apply(.pan(0.5), place: nil) }
            real.tick(1.5 * wait)
        }
        let o = real.obs
        if real.canvas.newLineCount == n0 {
            bad.append(String(format: "width %.0f%%, zoom %.1f, first word at %.0f%% of the view: block at %.0f, cutoff %.0f, but the view stops at x %.0f (its reach): %d words and no next line; ink to %.0f",
                              ToolState.lineWidths[wi] * 100, zoom, f * 100, o.runStart ?? .nan, o.limit ?? .nan, o.cam.visible.maxX, words, o.lineInk?.maxX ?? .nan))
        }
    }
    return bad
}

/// P7 with the edge-tap rule (thr_ra4euq2qri): with the line due and its move waiting, (a) an edge contact alone touching
/// and lifting must not cancel or delay it; (b) a two-finger tap with one finger in the edge band is a counted touch: it may
/// cancel, but then the first pause after it should bring the move (P5). Returns (property, message) failures.
func cutoffEdgeTapChecks(waitMs: Double) -> [(String, String)] {
    var bad: [(String, String)] = []
    let wait = waitMs / 1000
    for (edgeOnly, double) in [(true, false), (false, false), (false, true)] {
        let real = WReal(waitMs: waitMs, widthIdx: 0, zoom: 1, viewX: 0)
        let v = real.canvas.camera.visible, h = 30.0, y = v.maxY - 0.5 * v.height
        _ = real.apply(.write(.at(0.05)), place: CGRect(x: v.minX + 0.05 * v.width, y: y, width: 3 * h, height: h))
        let rs = real.obs.runStart ?? 0
        _ = real.apply(.write(.cross), place: CGRect(x: rs + 0.5 * wPage.width - 2 * h, y: y, width: 3 * h, height: h))
        guard real.obs.pendingLiftAt != nil else { bad.append(("setup", "no move pending after crossing the cutoff")); continue }
        let n0 = real.canvas.newLineCount, t0 = real.vclock
        real.tick(0.1 * wait)
        real.edgeTap(edgeOnly: edgeOnly)
        if double { real.tick(0.08); real.edgeTap() }   // a double tap: the edge-band undo (thr_ra4euq2qri)
        let after = real.obs
        real.tick(1.2 * wait)
        let moved = real.canvas.newLineCount > n0
        if ProcessInfo.processInfo.environment["CUTOFF_ACTS"] != nil { print("edge\(edgeOnly ? " alone" : double ? " double tap" : " tap"): acts \(real.acts.suffix(12).joined(separator: ",")), moved \(moved)") }
        if edgeOnly {
            if after.pendingLiftAt == nil && real.canvas.newLineCount == n0 { bad.append(("C7", "an edge contact alone cancelled the waiting move")) }
            if !moved { bad.append(("C7", String(format: "an edge contact alone held back the move (%.0f ms after the lift, no move)", (real.vclock - t0) * 1000))) }
        } else if !moved, let l = real.obs.lineInk, let lim = real.obs.limit, Double(l.maxX) >= lim - CutoffSpec.nearMarker * real.obs.width * wPage.width - 1e-6 {   // still due
            bad.append((double ? "C5:undo" : "C5:touch", String(format: "a two-finger %@tap with one finger at the edge %@ the waiting move, and a %.0f ms pause after it brought none (strokes %d, acts: %@)",
                                              double ? "double " : "", after.pendingLiftAt == nil ? "cancelled" : "kept", 1.2 * waitMs, real.canvas.doc.strokes.count, real.acts.suffix(6).joined(separator: ","))))
        }
    }
    return bad
}
