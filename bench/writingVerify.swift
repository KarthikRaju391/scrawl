// Writing mode's rules, checked as properties:
//   P1  the page never moves mid-word: a move comes only once the finger has been up the wait, with no counted touch since
//   P2  written ink never moves
//   P3  the guide line sits at the block's start + the width, at most 95% of the page
//   P4  the move comes exactly when the line's live ink reaches the zone (an i-dot can't cancel it)
//   P5  where the move goes (the block's start, one line down; the clamped target remembered)
//   P6  blocks start and end only by their rules (a hand move of 10% of the view or more, Return, page, writing off)
//   P7  edge-band contacts never cancel or delay a move
//   P8  a move never waits past its time (a), stale moves are dropped (b), and writing mode never wedges (c)
// Formal checks of writing mode: a bounded model checker over WModel, property-based
// fuzzing of the real CanvasView (with WModel run alongside as a differential check, and shrinking), and replay
// of recorded sessions with every property checked on every event. Entry: writingVerifyMain (checks/writing-verify.sh).
import AppKit
import CoreGraphics
import Foundation

// MARK: - Placements: where a stroke goes, from what's on screen

func wPlace(_ p: WPlace, _ o: WObs) -> CGRect? {
    let v = o.cam.visible, W = wPage.width
    let h = min(max(v.height * 0.06, 6), 60), ww = h * 3, gap = h * 0.6
    let lineY = o.lineInk?.midY ?? (v.maxY - v.height * WritingLayout.lineFromTop)
    let rs = o.runStart ?? W * 0.03
    var limit = WSpec.limit(o.runStart, o.width), zone = WSpec.zone(limit, o.width)
    if CutoffSpec.enabled {   // aim at the spec's cutoff and marker (bench/cutoffSpec.swift), not the capped rule before 0.1.6
        let bw = o.width * (CutoffSpec.rule == .b ? W : (o.blockView ?? v.width))
        limit = rs + bw; zone = limit - CutoffSpec.nearMarker * bw
    }
    let pitch = max((o.lineInk?.height ?? h) * 1.35, v.height * 0.12)
    func word(_ x: Double, _ y: Double, _ w: Double = ww) -> CGRect { CGRect(x: x, y: y - h / 2, width: w, height: h) }
    var r: CGRect
    switch p {
    case .next: r = word(o.lineInk.map { $0.maxX + gap } ?? rs, lineY)
    case .zone: r = word(zone + (limit - zone) * 0.5 - ww, lineY)
    case .short: r = word(zone - max(2, 0.004 * o.width * W) - ww, lineY)
    case .cross: r = word(limit - ww * 0.5, lineY)
    case .edge: r = word(0.94 * W - ww, lineY)
    case .idot:
        guard let l = o.lineInk else { return nil }
        r = CGRect(x: l.midX, y: l.maxY + h * 0.2, width: h * 0.25, height: h * 0.25)
    case .nextLine: r = word(rs, lineY - pitch)
    case .indent: r = word(rs + 0.15 * W, lineY - pitch)
    case .prevEnd:
        guard let pl = o.prevLine else { return nil }
        r = word(pl.maxX + gap, pl.midY)
    case .farRight: r = word((o.lineInk?.maxX ?? v.midX) + 0.2 * W, lineY)
    case .below: r = word(v.minX + 0.1 * v.width, lineY - 5 * pitch)
    case .above: r = word(rs, lineY + 3 * pitch)
    case .at(let f): r = word(v.minX + f * v.width, lineY)
    }
    // The user can only start a stroke inside the view, and run it into the pad's edge band (5% past the view's side).
    guard r.minX >= v.minX + 0.5, r.minX < v.maxX - 1, r.minY >= v.minY + 1, r.maxY <= v.maxY - 1 else { return nil }
    let reach = v.maxX + v.width * 0.05
    if r.maxX > reach { r.size.width = reach - r.minX }
    return r
}

// MARK: - The bounded model checker

struct WExplore {
    let waitMs: Double
    var alphabet: [WEv]
    var depth: Int
    var states = 0, transitions = 0, recoveries = 0
    var found: [String: [WEv]] = [:]          // property -> first counterexample path (shrunk later)
    var foundStart: [String: WModel] = [:]
    var foundMsg: [String: String] = [:]
    private var memo: [Int: Int] = [:]       // fingerprint -> most remaining depth explored from it
    var checkRecovery = true

    init(waitMs: Double, depth: Int, alphabet: [WEv]? = nil) {
        self.waitMs = waitMs; self.depth = depth
        let W = waitMs / 1000
        self.alphabet = alphabet ?? Self.fullAlphabet(W)
    }

    static func fullAlphabet(_ W: Double) -> [WEv] {
        [.write(.next), .write(.zone), .write(.short), .write(.cross), .write(.edge), .write(.idot), .write(.nextLine), .write(.indent),
         .write(.prevEnd), .write(.farRight), .write(.below), .write(.above), .write(.at(0.05)), .write(.at(0.6)),
         .down(.next), .up, .tick(0.5 * W), .tick(1.1 * W), .edgeDown, .edgeUp, .pan(0.3), .pan(-0.3), .pinch(1.5), .pinch(1 / 1.5),
         .arrow(1), .arrow(-1), .scroll(0.3), .undo, .redo, .scratch, .ret, .page, .toggle, .width(0), .width(1), .width(2)]
    }

    /// The events that drive the next line, for deeper runs: writing, the pause, the edge, a hand pan, undo, Return.
    static func coreAlphabet(_ W: Double) -> [WEv] {
        [.write(.next), .write(.zone), .write(.cross), .write(.idot), .write(.nextLine), .write(.prevEnd), .write(.indent),
         .tick(0.5 * W), .tick(1.1 * W), .edgeDown, .edgeUp, .pan(0.3), .undo, .ret]
    }

    static func starts(waitMs: Double) -> [WModel] {
        var out: [WModel] = []
        for wi in 0..<3 { for z in [1.0, 2.0, 3.0, 5.0] { for vx in [0.0, 0.5, 1.0] {
            var m = WModel(); m.waitMs = waitMs; m.widthIdx = wi
            m.cam.zoom = z; m.cam.home()
            let vw = m.cam.visible.width
            m.cam.center.x = vw / 2 + vx * (wPage.width - vw); m.cam.clamp()
            if z == 1 && vx > 0 { continue }
            out.append(m)
        } } }
        return out
    }

    static func fingerprint(_ m: WModel, _ sp: WSpec) -> Int {
        let s = sp.mon
        var h = Hasher()
        func q(_ d: Double) { h.combine(Int((d * 1000).rounded())) }
        func q(_ d: Double?) { if let d { h.combine(1); q(d) } else { h.combine(0) } }
        func q(_ d: CGFloat?) { q(d.map(Double.init)) }
        func q(_ r: CGRect?) { if let r { h.combine(1); q(r.minX); q(r.minY); q(r.width); q(r.height) } else { h.combine(0) } }
        h.combine(m.writing); h.combine(m.widthIdx); q(m.cam.zoom); q(m.cam.center.x); q(m.cam.center.y)
        q(m.lineInk); h.combine(m.lineStrokes.count); for r in m.lineStrokes { q(r) }
        q(m.runStart); q(m.segmentStart); q(m.prevLine?.ink); h.combine(m.prevLine?.strokes.count ?? -1)
        h.combine(m.lineHeld); q(m.handPanX); q(m.handRef?.x); q(m.handRef?.y)
        q(m.pending.map { m.clock - $0.liftAt }); q(m.pending?.target.x); q(m.pending?.target.y); h.combine(m.pending?.follow ?? false); q(m.blockView)
        h.combine(m.counted); h.combine(m.edge); q(m.held)
        h.combine(m.pageIdx)
        for p in m.pages { h.combine(p.strokes.count); for r in p.strokes { q(r) }; h.combine(p.undo.count); h.combine(p.redo.count); q(p.cam?.center.x); q(p.cam?.zoom) }
        q(s.schedAt.map { m.clock - $0 }); h.combine(s.downSinceSched); q(s.refX); q(s.panSum)
        if CutoffSpec.enabled { sp.cut.hash(into: &h, clock: m.clock) }
        return h.finalize()
    }

    /// Apply one event to the model, with the placement resolved; nil if it can't happen here.
    static func step(_ m: inout WModel, _ e: WEv) -> CGRect?? {
        var stroke: CGRect?
        switch e {
        case .write(let p), .down(let p):
            guard let r = wPlace(p, m.obs) else { return nil }
            stroke = r
            if case .down = e { stroke = CGRect(x: r.minX, y: r.midY - 1, width: 2, height: 2) }
        case .up: stroke = m.held
        default: break
        }
        guard m.apply(e, stroke: stroke) else { return nil }
        switch e { case .write, .up: return .some(stroke); default: return .some(nil) }
    }

    /// From state m, does a writer who carries on (words to the right, a two-finger pan when out of room) get a move?
    static func recovers(_ m0: WModel) -> Bool {
        guard m0.writing else { return true }
        for startY in [0.85, 0.15, 0.5] {
            var m = m0
            if m.counted > 0 { _ = step(&m, .up) }
            m.apply(.tick(1.1 * m.waitMs / 1000))
            let n0 = m.newLines
            let v = m.cam.visible
            let h = min(max(v.height * 0.06, 6), 60)
            _ = m.apply(.write(.at(0)), stroke: CGRect(x: v.minX + 0.05 * v.width, y: v.maxY - startY * v.height - h / 2, width: h * 3, height: h))
            for _ in 0..<150 {
                if m.newLines > n0 { return true }
                let o = m.obs
                if m.pending != nil { m.apply(.tick(1.1 * m.waitMs / 1000)); continue }
                let lim = WSpec.limit(o.runStart, o.width), zone = WSpec.zone(lim, o.width)
                let vv = o.cam.visible
                if wPlace(.zone, o) != nil && zone + (lim - zone) * 0.5 <= vv.maxX + vv.width * 0.05 - 1 && (o.lineInk?.maxX ?? 0) < zone { _ = step(&m, .write(.zone)) }
                else if let r = wPlace(.next, o), r.maxX <= vv.maxX - 1 { _ = step(&m, .write(.next)) }
                else { _ = step(&m, .pan(0.5)) }
            }
            if m.newLines > n0 { return true }
        }
        return false
    }

    mutating func run(from start: WModel, workers: Int = 1) {
        var path: [WEv] = []
        dfs(start, WSpec(waitMs: waitMs), start, depth, &path)
    }

    private mutating func dfs(_ m: WModel, _ spec: WSpec, _ start: WModel, _ left: Int, _ path: inout [WEv]) {
        let fp = Self.fingerprint(m, spec)
        if let d = memo[fp], d >= left { return }
        if memo[fp] == nil {
            states += 1
            if checkRecovery && found["P8c"] == nil {
                recoveries += 1
                if !Self.recovers(m) { record("P8c", "no move for a writer carrying on from here (writing mode wedged)", path, start) }
            }
        }
        memo[fp] = left
        guard left > 0 else { return }
        for e in alphabet {
            var n = m, s = spec
            let pre = n.obs
            guard let committed = Self.step(&n, e) else { continue }
            transitions += 1
            path.append(e)
            let bad = s.check(e, pre: pre, post: n.obs, committed: committed)
            for (p, msg) in bad where found[p] == nil { record(p, msg, path, start) }
            dfs(n, s, start, left - 1, &path)   // carry on past a violation: the other properties keep their coverage
            path.removeLast()
        }
    }

    private mutating func record(_ p: String, _ msg: String, _ path: [WEv], _ start: WModel) {
        found[p] = path; foundStart[p] = start; foundMsg[p] = msg
    }

    /// Replay a path from a start through model + oracle: the first violation of `prop` (or any, if nil).
    static func replay(_ start: WModel, _ path: [WEv], prop: String?) -> (Int, String)? {
        var m = start, s = WSpec(waitMs: start.waitMs)
        for (i, e) in path.enumerated() {
            let pre = m.obs
            guard let c = step(&m, e) else { return nil }
            let bad = s.check(e, pre: pre, post: m.obs, committed: c)
            if let b = bad.first(where: { prop == nil || $0.0 == prop }) { return (i, b.1) }
            if prop == "P8c", i == path.count - 1, !recovers(m) { return (i, "no move for a writer carrying on") }
        }
        return nil
    }

    /// Delta debugging: drop events while the same property still fails.
    static func shrink(_ start: WModel, _ path: [WEv], prop: String) -> [WEv] {
        var p = path
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < p.count {
                var q = p; q.remove(at: i)
                if let (k, _) = replay(start, q, prop: prop) { p = Array(q.prefix(k + 1)); changed = true } else { i += 1 }
            }
        }
        return p
    }
}

func wName(_ e: WEv) -> String { "\(e)".replacingOccurrences(of: "main.WPlace.", with: "").replacingOccurrences(of: "main.", with: "") }

func wDescribe(_ m: WModel) -> String {
    String(format: "width %.0f%%, zoom %.0f, view x %.0f-%.0f", m.width * 100, m.cam.zoom, m.cam.visible.minX, m.cam.visible.maxX)
}

// MARK: - The real CanvasView, driven through its touch entry point on a virtual clock

final class WReal {
    let canvas: CanvasView
    var vclock = 100.0
    private var edge: Contact?
    private var held: Contact?
    private var nextId: Int32 = 100
    let pad = Multitouch.padMM
    var acts: [String] = []

    init(waitMs: Double, widthIdx: Int, zoom: Double, viewX: Double) {
        Settings.pauseChosenMs = waitMs   // the Settings slider (tests ignore the stored choice)
        canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
        canvas.now = { [unowned self] in self.vclock }
        var t = canvas.tools; t.lineWidthIndex = widthIdx; t.zoomLocked = false; canvas.tools = t   // (the bench's own saved tools may say locked)
        let w = wPage.width / zoom
        canvas.setVisibleForReplay(x: viewX * (wPage.width - w), y: wPage.height - wPage.height / zoom, w: w, z: zoom)
        canvas.drawMode = true
        canvas.writingMode = true
        canvas.onAct = { [unowned self] a, _ in self.acts.append(a) }
    }

    var obs: WObs {
        let s = canvas.writingStateForTest
        return WObs(writing: canvas.writingMode, width: ToolState.lineWidths[canvas.tools.lineWidthIndex], cam: canvas.camera, runStart: s.runStart, lineInk: s.lineInk,
                    lineStrokes: s.lineStrokes, prevLine: s.prevLine, lineHeld: s.lineHeld, handRef: s.handRef, pendingTarget: s.pending?.target,
                    pendingLiftAt: s.pending?.liftAt, counted: s.countedContacts, edge: edge == nil ? 0 : 1, clock: vclock,
                    strokes: canvas.doc.strokes.map(\.bounds), limit: canvas.lineLimitX, newLines: canvas.newLineCount, page: canvas.pageIndex, handPanX: s.handPanX,
                    follows: s.follows, pendingFollow: s.pendingFollow, blockView: s.blockViewWidth, guide: canvas.limitTargetAlphaForTest, inkRight: canvas.lineRightForTest)
    }

    private func contact(_ id: Int32, page p: CGPoint) -> Contact {
        let v = canvas.camera.visible
        let n = Camera.pad(fromActive: CGPoint(x: (p.x - v.minX) / v.width, y: (p.y - v.minY) / v.height))
        return contact(id, norm: n)
    }
    private func contact(_ id: Int32, norm n: CGPoint) -> Contact {
        Contact(id: id, state: 4, norm: n, mm: CGPoint(x: n.x * pad.width, y: n.y * pad.height), pressure: 25, size: 0.5, major: 7.5)
    }
    /// One trackpad frame at time t (plus the edge contact and a held finger, if down), then a display tick.
    private func frame(_ cs: [Contact], at t: Double) {
        vclock = t
        var all = cs
        if let e = edge { all.append(e) }
        if let h = held { all.append(h) }
        canvas.handle(all, arrival: t, sensorT: t)
        canvas.advanceClock()
    }
    /// Frames along `pts` (one per 8 ms), ending exactly `dur` after the first, then the lift.
    private func gesture(_ seq: [[Contact]], dur: Double) {
        let t0 = vclock
        for (k, cs) in seq.enumerated() { frame(cs, at: t0 + dur * Double(k) / Double(seq.count)) }
        frame([], at: t0 + dur)
        canvas.flushInputForTest()
    }
    /// Time passes: frames every 8 ms while anything is down (the sensor reports), display ticks either way.
    func tick(_ dt: Double) {
        let t0 = vclock, n = Int(dt / 0.008)
        for k in 1...max(n, 1) {
            let t = k == max(n, 1) ? t0 + dt : t0 + Double(k) * 0.008
            if edge != nil || held != nil { frame([], at: t) } else { vclock = t; canvas.advanceClock() }
        }
        vclock = t0 + dt
        canvas.flushInputForTest()
    }

    /// A word from (minX, midY) to (maxX, midY), wiggling to its height; settles at the end (the filter lags).
    private func strokeFrames(_ r: CGRect, id: Int32) -> [[Contact]] {
        var out: [[Contact]] = []
        let n = 17
        for k in 0...n {
            let u = Double(k) / Double(n)
            out.append([contact(id, page: CGPoint(x: r.minX + u * r.width, y: r.midY + r.height / 2 * sin(u * .pi * 3)))])
        }
        for _ in 0..<7 { out.append([contact(id, page: CGPoint(x: r.maxX, y: r.midY))]) }
        return out
    }

    /// From here, does a writer who carries on (lift, a word low on the view, then words to the right with a two-finger
    /// pan when out of room) get a move? Several starting heights, as in WExplore.recovers.
    func recovers() -> Bool {
        guard canvas.writingMode else { return true }
        if held != nil { _ = apply(.up, place: nil) }
        if edge != nil { _ = apply(.edgeUp, place: nil) }
        let wait = canvas.settings.pauseBeforeMoveMs / 1000
        tick(1.1 * wait)
        let n0 = canvas.newLineCount
        for startY in [0.85, 0.15, 0.5] {
            let v = canvas.camera.visible, h = min(max(v.height * 0.06, 6), 60)
            _ = apply(.write(.at(0)), place: CGRect(x: v.minX + 0.05 * v.width, y: v.maxY - startY * v.height - h / 2, width: h * 3, height: h))
            for _ in 0..<150 {
                if canvas.newLineCount > n0 { return true }
                let o = obs
                if ProcessInfo.processInfo.environment["CUTOFF_RECOVER_LOG"] != nil {
                    print(String(format: "  recover: view %.0f-%.0f z %.2f, start %@, line %@, limit %@, pending %@, follow %@, held %@", o.cam.visible.minX, o.cam.visible.maxX, o.cam.zoom,
                                 o.runStart.map { String(format: "%.0f", $0) } ?? "nil", o.lineInk.map { String(format: "%.0f-%.0f y %.0f", $0.minX, $0.maxX, $0.midY) } ?? "nil",
                                 o.limit.map { String(format: "%.0f", $0) } ?? "nil", o.pendingLiftAt != nil ? "yes" : "no", o.pendingFollow != nil ? "yes" : "no", o.lineHeld ? "yes" : "no"))
                }
                if o.pendingLiftAt != nil { tick(1.1 * wait); continue }
                let lim = WSpec.limit(o.runStart, o.width), zone = WSpec.zone(lim, o.width), vv = o.cam.visible
                if let r = wPlace(.zone, o), zone + (lim - zone) * 0.5 <= vv.maxX + vv.width * 0.05 - 1, (o.lineInk?.maxX ?? 0) < zone { _ = apply(.write(.zone), place: r) }
                else if let r = wPlace(.next, o), r.maxX <= vv.maxX - 1 { _ = apply(.write(.next), place: r) }
                else { _ = apply(.pan(0.5), place: nil) }
            }
            if canvas.newLineCount > n0 { return true }
        }
        return false
    }

    /// A two-finger pan in draw mode by (fx, fy) of the active pad (+x: the fingers move left, the view right; +y: the
    /// fingers move down, the view up).
    func panBy(_ fx: Double, _ fy: Double) {
        nextId += 2
        let a = nextId - 1, b = nextId, dx = fx * (1 - 2 * Camera.margin), dy = fy * (1 - 2 * Camera.margin)
        var seq: [[Contact]] = []
        for k in 0...24 { let u = Double(k) / 24
            seq.append([contact(a, norm: CGPoint(x: 0.42 - dx * u, y: 0.5 - dy * u)), contact(b, norm: CGPoint(x: 0.58 - dx * u, y: 0.5 - dy * u))]) }
        gesture(seq, dur: 0.2)
        canvas.flushInputForTest()
    }

    /// Apply one event; returns (applied, committed stroke bounds).
    func apply(_ e: WEv, place: CGRect?) -> (Bool, CGRect?) {
        let n0 = canvas.doc.strokes.count, page0 = canvas.pageIndex
        func committed() -> CGRect? { canvas.pageIndex == page0 && canvas.doc.strokes.count == n0 + 1 ? canvas.doc.strokes.last!.bounds : nil }
        switch e {
        case .write:
            guard held == nil, let r = place else { return (false, nil) }
            nextId += 1
            gesture(strokeFrames(r, id: nextId), dur: 0.2)
            return (true, committed())
        case .down:
            guard held == nil, let r = place else { return (false, nil) }
            nextId += 1
            let c = contact(nextId, page: CGPoint(x: r.minX, y: r.midY))
            frame([c], at: vclock)
            held = c
            tick(0.05)
            return (true, nil)
        case .up:
            guard held != nil else { return (false, nil) }
            held = nil
            frame([], at: vclock); canvas.flushInputForTest()
            return (true, committed())
        case .tick(let dt): tick(dt)
        case .edgeDown:
            guard edge == nil else { return (false, nil) }
            nextId += 1
            edge = contact(nextId, norm: CGPoint(x: 0.02, y: 0.45))
            frame([], at: vclock)
        case .edgeUp:
            guard edge != nil else { return (false, nil) }
            edge = nil
            frame([], at: vclock)
        case .pan(let f):
            guard held == nil else { return (false, nil) }
            nextId += 2
            let a = nextId - 1, b = nextId, d = f * (1 - 2 * Camera.margin)
            var seq: [[Contact]] = []
            for k in 0...24 { let o = -d * Double(k) / 24
                seq.append([contact(a, norm: CGPoint(x: 0.42 + o, y: 0.5)), contact(b, norm: CGPoint(x: 0.58 + o, y: 0.5))]) }
            gesture(seq, dur: 0.2)
        case .pinch(let ratio):
            guard held == nil else { return (false, nil) }
            nextId += 2
            let a = nextId - 1, b = nextId, d0 = 0.12
            var seq: [[Contact]] = []
            for k in 0...24 { let d = d0 * pow(ratio, Double(k) / 24)
                seq.append([contact(a, norm: CGPoint(x: 0.5 - d / 2, y: 0.5)), contact(b, norm: CGPoint(x: 0.5 + d / 2, y: 0.5))]) }
            gesture(seq, dur: 0.2)
        case .arrow(let d):
            guard held == nil else { return (false, nil) }
            canvas.panByArrow(dx: d, dy: 0, screen: false)
        case .scroll(let f):
            guard held == nil else { return (false, nil) }
            // Outside draw mode, a two-finger scroll (NSEvent scrollWheel); then back into draw mode.
            canvas.drawMode = false
            let k = 1 / (canvas.ptPerUnit * canvas.camera.zoom)
            let dx = -f * canvas.camera.visible.width / k
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx.rounded()), wheel3: 0),
               let ev = NSEvent(cgEvent: cg) { canvas.scrollWheel(with: ev) }
            canvas.drawMode = true
            tick(0.1)
        case .undo: guard held == nil else { return (false, nil) }; canvas.undo()
        case .redo: guard held == nil else { return (false, nil) }; canvas.redo()
        case .scratch:
            guard held == nil, let last = canvas.doc.strokes.last else { return (false, nil) }
            // A fast zig-zag over the last stroke: six legs across it.
            nextId += 1
            let v = canvas.camera.visible, mm = v.width / (pad.width * (1 - 2 * Camera.margin))
            let b = last.bounds, r = CGRect(x: b.midX - max(b.width / 2 + 2, 4 * mm), y: b.midY - max(b.height / 2, 3 * mm), width: max(b.width + 4, 8 * mm), height: max(b.height, 6 * mm))
            var seq: [[Contact]] = []
            for k in 0...24 {
                let leg = Double(k) / 4, u = leg - floor(leg), dir = Int(leg) % 2 == 0
                let x = dir ? r.minX + u * r.width : r.maxX - u * r.width
                seq.append([contact(nextId, page: CGPoint(x: x, y: r.minY + r.height * (0.3 + 0.4 * Double(k) / 24)))])
            }
            gesture(seq, dur: 0.2)
            return (true, committed())   // not a scratch-out after all (too small or too slow): it's ink
        case .ret: guard held == nil else { return (false, nil) }; canvas.newLineByHand()
        case .page:
            guard held == nil else { return (false, nil) }
            if canvas.pages.count < 2 { canvas.newPage() } else { canvas.goToPage(1 - canvas.pageIndex) }
        case .toggle: guard held == nil else { return (false, nil) }; canvas.writingMode.toggle()
        case .width(let i):
            guard held == nil, i != canvas.tools.lineWidthIndex else { return (false, nil) }
            var t = canvas.tools; t.lineWidthIndex = i; canvas.tools = t
        }
        canvas.flushInputForTest()
        return (true, nil)
    }
}

// MARK: - Property-based fuzzing on the real code path

struct WFuzz {
    var rng: TestRNG
    let waitMs: Double

    func alphabet() -> [WEv] { WExplore.fullAlphabet(waitMs / 1000) }

    mutating func randomEvent() -> WEv {
        while true {
            let e = randomEvent1()
            let name: String = { switch e { case .width: return "width"; case .scratch: return "scratch"; case .scroll: return "scroll"; default: return "" } }()
            if !skip.contains(name) { return e }
        }
    }
    mutating func randomEvent1() -> WEv {
        let W = waitMs / 1000
        let r = rng.next()
        switch r {
        case ..<0.45:
            let places: [WPlace] = [.next, .next, .next, .zone, .short, .cross, .edge, .idot, .nextLine, .nextLine, .indent, .prevEnd, .farRight, .below, .above, .at(rng.next())]
            return .write(places[Int(rng.next() * Double(places.count))])
        case ..<0.62: return .tick([0.1 * W, 0.5 * W, 0.99 * W, 1.0 * W, 1.5 * W, 3 * W][Int(rng.next() * 6)])
        case ..<0.66: return rng.next() < 0.5 ? .edgeDown : .edgeUp
        case ..<0.69: return rng.next() < 0.5 ? .down(.next) : .up
        case ..<0.74: return .pan((rng.next() - 0.45) * 0.7)
        case ..<0.77: return .pinch([1.5, 1 / 1.5, 1.2, 2][Int(rng.next() * 4)])
        case ..<0.80: return .arrow(rng.next() < 0.7 ? 1 : -1)
        case ..<0.82: return .scroll((rng.next() - 0.4) * 0.6)
        case ..<0.86: return .undo
        case ..<0.87: return .redo
        case ..<0.89: return .scratch
        case ..<0.92: return .ret
        case ..<0.94: return .page
        case ..<0.96: return .toggle
        default: return .width(Int(rng.next() * 3))
        }
    }

    struct Start { var widthIdx: Int; var zoom: Double; var viewX: Double }
    /// Leave out events (for runs that look past known failures).
    var skip: Set<String> = []

    /// What the runs reached (to see the fuzzer exercises the paths that matter).
    nonisolated(unsafe) static var stats: [String: Int] = [:]

    /// Run `events` on a fresh canvas from `start` with the oracle and the model alongside, then check a writer who
    /// carries on still gets a move (P8c). Returns the first failure: (index, property, message).
    static func run(_ start: Start, _ events: [WEv], waitMs: Double, differential: Bool = true, recovery: Bool = true, log: ((String) -> Void)? = nil) -> (Int, String, String)? {
        let real = WReal(waitMs: waitMs, widthIdx: start.widthIdx, zoom: start.zoom, viewX: start.viewX)
        var model = WModel(); model.waitMs = waitMs; model.widthIdx = start.widthIdx; model.cam = real.canvas.camera; model.clock = real.vclock
        var spec = WSpec(waitMs: waitMs)
        for (i, e) in events.enumerated() {
            let pre = real.obs
            let place: CGRect? = {
                switch e { case .write(let p), .down(let p): return wPlace(p, pre); default: return nil }
            }()
            if case .write = e, place == nil { continue }
            if case .down = e, place == nil { continue }
            let (ok, committed) = real.apply(e, place: place)
            if !ok { continue }
            let post = real.obs
            let bad = spec.check(e, pre: pre, post: post, committed: committed)
            stats["steps", default: 0] += 1
            if committed != nil { stats["commits", default: 0] += 1; if post.pendingLiftAt != nil { stats["commits that scheduled a move", default: 0] += 1 } }
            if post.newLines > pre.newLines { stats[e == .ret ? "Return moves" : "automatic moves", default: 0] += 1 }
            if post.follows > pre.follows { stats["follows (view went along a long line)", default: 0] += 1 }
            if pre.cam.zoom != post.cam.zoom && post.runStart != nil && post.runStart == pre.runStart { stats["zoom changes mid-block", default: 0] += 1 }
            if pre.pendingLiftAt != nil && post.pendingLiftAt == nil && post.newLines == pre.newLines { stats["pending moves dropped", default: 0] += 1 }
            if pre.runStart != nil && post.runStart != nil && pre.runStart != post.runStart { stats["block start moved", default: 0] += 1 }
            if post.lineHeld && !pre.lineHeld { stats["lines continued (held)", default: 0] += 1 }
            if post.pendingLiftAt != nil && post.edge > 0 { stats["pending with an edge contact down", default: 0] += 1 }
            log?("\(i) \(e) committed \(committed.map { String(format: "%.0f-%.0f", $0.minX, $0.maxX) } ?? "-") runStart \(post.runStart.map { String(format: "%.0f", $0) } ?? "nil") pending \(post.pendingLiftAt != nil) lines \(post.newLines)")
            if let b = bad.first, !CommandLine.arguments.contains("--diff-only") { return (i, b.0, b.1) }
            if differential {
                // The model, on the same event with the real stroke and the real hand-moved camera.
                switch e {
                case .write:
                    if let c = committed { model.apply(e, stroke: c) } else { model.counted = 1; model.cancelPendingMove(); model.clock += 0.2; model.counted = 0; model.advanceClock() }
                case .down: model.apply(e, stroke: CGRect(x: 0, y: 0, width: 1, height: 1))
                case .up:
                    if let c = committed { model.apply(e, stroke: c) } else { model.counted = 0; model.held = nil; model.advanceClock() }
                case .scratch:
                    if post.strokes.count < pre.strokes.count {
                        var gone = pre.strokes
                        for r in post.strokes { if let i = gone.firstIndex(of: r) { gone.remove(at: i) } }
                        model.erase(gone)
                    } else if let c = committed { model.apply(.write(.next), stroke: c) } else { model.counted = 1; model.cancelPendingMove(); model.clock += 0.2; model.counted = 0; model.advanceClock() }
                case .pan, .pinch, .scroll: model.apply(e, camAfter: post.cam)
                default: model.apply(e)
                }
                if let d = wDiff(model, post) { return (i, "model", "model and app differ after \(e): \(d)") }
            }
        }
        if recovery && !real.recovers() { return (events.count, "P8c", "a writer carrying on gets no move (writing mode wedged)") }
        return nil
    }

    static func shrink(_ start: Start, _ events: [WEv], waitMs: Double, prop: String) -> [WEv] {
        let diff = !CommandLine.arguments.contains("--no-diff")
        func run(_ s: Start, _ e: [WEv], waitMs: Double) -> (Int, String, String)? { WFuzz.run(s, e, waitMs: waitMs, differential: diff) }
        var p = events
        if let (k, _, _) = run(start, p, waitMs: waitMs) { p = Array(p.prefix(k + 1)) }
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < p.count {
                var q = p; q.remove(at: i)
                if let (k, pr, _) = run(start, q, waitMs: waitMs), pr == prop { p = Array(q.prefix(k + 1)); changed = true } else { i += 1 }
            }
        }
        return p
    }
}

/// How the model's state differs from the app's (nil: the same).
func wDiff(_ m: WModel, _ o: WObs) -> String? {
    func eq(_ a: CGFloat?, _ b: CGFloat?) -> Bool { eq(a.map(Double.init), b.map(Double.init)) }
    func eq(_ a: Double?, _ b: Double?) -> Bool { switch (a, b) { case (nil, nil): return true; case let (x?, y?): return abs(x - y) < 1e-6 * max(1, abs(x)); default: return false } }
    func req(_ a: CGRect?, _ b: CGRect?) -> Bool { eq(a?.minX, b?.minX) && eq(a?.maxX, b?.maxX) && eq(a?.minY, b?.minY) && eq(a?.maxY, b?.maxY) }
    let mo = m.obs
    if mo.writing != o.writing { return "writing \(mo.writing) vs \(o.writing)" }
    if !eq(mo.runStart, o.runStart) { return "runStart \(String(describing: mo.runStart)) vs \(String(describing: o.runStart))" }
    if !req(mo.lineInk, o.lineInk) { return "line \(String(describing: mo.lineInk)) vs \(String(describing: o.lineInk))" }
    if mo.lineStrokes.count != o.lineStrokes.count { return "line strokes \(mo.lineStrokes.count) vs \(o.lineStrokes.count)" }
    if !req(mo.prevLine, o.prevLine) { return "previous line differs" }
    if mo.lineHeld != o.lineHeld { return "held \(mo.lineHeld) vs \(o.lineHeld)" }
    if (mo.pendingLiftAt == nil) != (o.pendingLiftAt == nil) { return "pending \(mo.pendingLiftAt != nil) vs \(o.pendingLiftAt != nil)" }
    if !eq(mo.pendingTarget?.x, o.pendingTarget?.x) || !eq(mo.pendingTarget?.y, o.pendingTarget?.y) { return "pending target differs" }
    if !eq(mo.handRef?.x, o.handRef?.x) { return "handRef \(String(describing: mo.handRef)) vs \(String(describing: o.handRef))" }
    if !eq(mo.cam.center.x, o.cam.center.x) || !eq(mo.cam.center.y, o.cam.center.y) || !eq(mo.cam.zoom, o.cam.zoom) {
        return String(format: "camera (%.2f, %.2f, %.2f) vs (%.2f, %.2f, %.2f)", mo.cam.center.x, mo.cam.center.y, mo.cam.zoom, o.cam.center.x, o.cam.center.y, o.cam.zoom)
    }
    if mo.newLines != o.newLines { return "moves \(mo.newLines) vs \(o.newLines)" }
    if !eq(mo.limit, o.limit) { return "limit \(String(describing: mo.limit)) vs \(String(describing: o.limit))" }
    if mo.strokes.count != o.strokes.count { return "strokes \(mo.strokes.count) vs \(o.strokes.count)" }
    return nil
}

// MARK: - Recorded sessions

struct WReplayResult { var events = 0, commits = 0, moves = 0, pendings = 0; var violations: [(String, String, Double)] = []; var notes: [String] = [] }

/// Replay a recorded session through a real CanvasView (as TestSession does) and check the properties on every record.
func wReplaySession(_ path: String, waitMs: Double) -> WReplayResult {
    var res = WReplayResult()
    Settings.pauseChosenMs = waitMs   // the Settings slider (tests ignore the stored choice)
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    let pad = Multitouch.padMM
    let rows = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
    var vclock = rows.first?["m"] as? Double ?? 0
    canvas.now = { vclock }
    if let t0 = rows.first(where: { $0["a"] as? String == "tools" }) { TestSession.apply(tools: t0, canvas) }
    var drawing = false
    var spec = WSpec(waitMs: waitMs)
    func obs() -> WObs {
        let s = canvas.writingStateForTest
        return WObs(writing: canvas.writingMode, width: ToolState.lineWidths[canvas.tools.lineWidthIndex], cam: canvas.camera, runStart: s.runStart, lineInk: s.lineInk,
                    lineStrokes: s.lineStrokes, prevLine: s.prevLine, lineHeld: s.lineHeld, handRef: s.handRef, pendingTarget: s.pending?.target,
                    pendingLiftAt: s.pending?.liftAt, counted: s.countedContacts, edge: 0, clock: vclock,
                    strokes: canvas.doc.strokes.map(\.bounds), limit: canvas.lineLimitX, newLines: canvas.newLineCount, page: canvas.pageIndex,
                    follows: s.follows, pendingFollow: s.pendingFollow, blockView: s.blockViewWidth, guide: canvas.limitTargetAlphaForTest, inkRight: canvas.lineRightForTest)
    }
    var afterWidth: (old: Double, at: Double)?
    var heldFrom: Double?
    func check(_ e: WEv, _ pre: WObs, _ committed: CGRect?) {
        let post = obs()
        if case .width = e, let rs = pre.runStart { afterWidth = (rs, vclock) }
        if committed != nil, post.lineHeld, let ink = post.lineInk, let p0 = heldFrom, ink.height > p0 * 1.8 {
            res.notes.append(String(format: "held line at %.1f s grew from %.0f to %.0f units tall (absorbed a line below it): %d strokes, no automatic move for them", vclock - (rows.first?["m"] as? Double ?? 0), p0, ink.height, post.lineStrokes.count))
            heldFrom = .infinity
        }
        if post.lineHeld && !pre.lineHeld { heldFrom = post.lineInk.map { Double($0.height) } }
        if !post.lineHeld { heldFrom = nil }
        if let a = afterWidth, let s = committed {
            res.notes.append(String(format: "width change at %.1f s: block start was %.1f; the next stroke came %.1f s later at x %.1f (%+.1f%% of the page), %@ the old line",
                                    a.at - (rows.first?["m"] as? Double ?? 0), a.old, vclock - a.at, s.minX, (s.minX - a.old) / wPage.width * 100,
                                    abs(s.midY - (pre.lineInk?.midY ?? .infinity)) < 30 ? "on" : "not on"))
            afterWidth = nil
        }
        res.events += 1
        if post.newLines > pre.newLines { res.moves += 1 }
        if committed != nil { res.commits += 1; if post.pendingLiftAt != nil { res.pendings += 1 } }
        for (p, m) in spec.check(e, pre: pre, post: post, committed: committed) { res.violations.append((p, m, vclock - (rows.first?["m"] as? Double ?? 0))) }
    }
    var lastIds = Set<Int32>()
    var commits = 0
    let actLog = ProcessInfo.processInfo.environment["CUTOFF_ACTS"] != nil
    // A two- or three-finger double tap replayed from the touch frames undoes or redoes by itself; the recorded "undo" /
    // "redo" act that follows it is the same command (it was applied twice: every gesture undo undid two strokes).
    var gestureDone = (undo: 0, redo: 0)
    canvas.onAct = { a, x in if a == "commit" { commits += 1 }; if a == "gestureUndo" { gestureDone.undo += 1 }; if a == "gestureRedo" { gestureDone.redo += 1 }; if actLog, a != "strokeBegin", a != "strokeEnd", a != "click" { print(String(format: "ACT %.3f %@ %@", vclock - (rows.first?["m"] as? Double ?? 0), a, x.isEmpty ? "" : "\(x)")) } }
    for r in rows {
        vclock = r["m"] as? Double ?? vclock
        do { let pre = obs(); canvas.advanceClock(); canvas.flushInputForTest(); check(.tick(0), pre, nil) }
        let pre = obs(), n0 = canvas.doc.strokes.count, page0 = canvas.pageIndex, c0 = commits
        var e: WEv = .tick(0)
        switch r["k"] as? String {
        case "touch":
            guard drawing, let cs = r["c"] as? [[Double]] else { continue }
            let contacts = cs.map { c in Contact(id: Int32(c[0]), state: Int32(c[1]), norm: CGPoint(x: c[2], y: c[3]),
                                                 mm: CGPoint(x: c[2] * pad.width, y: c[3] * pad.height), pressure: c[4], size: 0.5, major: 7.5) }
            let ids = Set(contacts.filter(\.isDown).map(\.id))
            let z0 = canvas.camera.zoom, x0 = canvas.camera.center.x
            canvas.handle(contacts, arrival: vclock, sensorT: r["t"] as? Double ?? 0)
            let post = canvas.writingStateForTest
            // The eraser (it erases while the finger moves, and puts strokes back if its touch becomes a pinch), or a scratch-out.
            if (canvas.doc.strokes.count < n0 || canvas.tools.tool == .eraser) && canvas.pageIndex == page0 { e = .scratch }
            else if canvas.camera.zoom != z0 { e = .pinch(canvas.camera.zoom / z0) }
            else if canvas.camera.center.x != x0 { e = .pan(0) }
            else if !ids.subtracting(lastIds).isEmpty { e = post.countedContacts > pre.counted ? .down(.next) : .edgeDown }
            else if canvas.doc.strokes.count != n0 { e = .up }
            lastIds = ids
        case "view":
            let src = r["src"] as? String ?? ""
            if ["scroll", "magnify", "test", "zoomToPage", "replay", "unknown"].contains(src) {
                canvas.setVisibleForReplay(x: r["x"] as! Double, y: r["y"] as! Double, w: r["w"] as! Double, z: r["z"] as! Double)
                e = .scroll(0)
            }
        case "act":
            switch r["a"] as? String {
            case "tools":
                let w0 = canvas.tools.lineWidthIndex
                TestSession.apply(tools: r, canvas)
                if canvas.tools.lineWidthIndex != w0 { e = .width(canvas.tools.lineWidthIndex) }
            case "writingMode": let was = canvas.writingMode; canvas.writingMode = r["on"] as? Bool ?? false; if was != canvas.writingMode { e = .toggle }
            case "drawMode": drawing = r["on"] as? Bool ?? false; canvas.drawMode = drawing
            case "undo": if gestureDone.undo > 0 { gestureDone.undo -= 1; e = .undo } else { canvas.undo(); e = .undo }
            case "redo": if gestureDone.redo > 0 { gestureDone.redo -= 1; e = .redo } else { canvas.redo(); e = .redo }
            case "clear": canvas.clearPage(); e = .page
            case "newPage": canvas.newPage(); e = .page
            case "goToPage": let p0 = canvas.pageIndex; canvas.goToPage(r["page"] as? Int ?? 0); if canvas.pageIndex != p0 { e = .page }
            case "click": canvas.replayClick()
            case "clickDrawOff": canvas.replayClickDrawOff()
            default: break
            }
        default: break
        }
        canvas.flushInputForTest()
        let committed = canvas.pageIndex == page0 && commits == c0 + 1 ? canvas.doc.strokes.last!.bounds : nil   // a new stroke (not a redo)
        if committed != nil, case .tick = e { e = .up }
        if case .scratch = e {} else if canvas.doc.strokes.count < n0, canvas.pageIndex == page0, case .up = e { e = .scratch }
        if canvas.doc.strokes.count < n0, canvas.pageIndex == page0 { if case .undo = e {} else if case .page = e {} else { e = .scratch } }
        check(e, pre, committed)
    }
    vclock += 5; let pre = obs(); canvas.advanceClock(); canvas.flushInputForTest(); check(.tick(5), pre, nil)
    return res
}

/// The moves the recorded sessions themselves made (the app as it was then): each `movePending` that logged its
/// reason (right, limit, width) is checked against P4, and each `newLine` against P1 (the wait after the last lift,
/// no touch since). Returns one line per violation.
func wCheckRecordedMoves(_ path: String) -> (checked: Int, moves: Int, bad: [String]) {
    let rows = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
    var bad: [String] = [], checked = 0, moves = 0
    var lastLift: Double?, touchedSince = false, down = false, pendingAt: Double?
    let t0 = rows.first?["m"] as? Double ?? 0
    for r in rows {
        let m = r["m"] as? Double ?? 0
        if r["k"] as? String == "touch", let cs = r["c"] as? [[Double]] {
            let g = 0.05
            let isDown = cs.contains { c in c[1] >= 3 && c[1] <= 5 && !(c[2] < g || c[2] > 1 - g || c[3] < g || c[3] > 1 - g) }
            if isDown && !down { touchedSince = true }
            if !isDown && down { lastLift = m }
            down = isDown
        }
        guard r["k"] as? String == "act" else { continue }
        switch r["a"] as? String {
        case "movePending":
            pendingAt = m; touchedSince = false
            if r["kind"] as? String == "follow" { break }   // 0.1.6: the view following a long line (P9), not a next line
            if let right = r["right"] as? Double, let limit = r["limit"] as? Double, let width = r["width"] as? Double {
                checked += 1
                let bw = (r["blockWidth"] as? Double).flatMap { $0 > 0 ? $0 : nil }   // 0.1.6 recordings: the block's line length (no 95% cap, no 93% zone)
                let zone = bw.map { limit - WSpec.nearMarker * $0 } ?? WSpec.zone(limit, width)
                if right < zone - 1e-6 { bad.append(String(format: "t=%.1fs: move scheduled with the line's ink at %.1f, short of the zone (from %.1f, limit %.1f, width %.0f%%)", m - t0, right, zone, limit, width * 100)) }
                if bw == nil, limit > WSpec.rightCap * wPage.width + 1e-6 { bad.append(String(format: "t=%.1fs: limit %.1f past 95%% of the page", m - t0, limit)) }
            }
        case "newLine":
            moves += 1
            if let p = pendingAt {
                if m - p < 0.4 - 0.02 { bad.append(String(format: "t=%.1fs: move %.0f ms after it was scheduled", m - t0, (m - p) * 1000)) }
                if touchedSince { bad.append(String(format: "t=%.1fs: move after a touch-down that should have cancelled it", m - t0)) }
            }
            pendingAt = nil
        case "moveCancelled": pendingAt = nil
        default: break
        }
        _ = lastLift
    }
    return (checked, moves, bad)
}

// MARK: - Targeted checks on the real canvas (things the model doesn't have: the 0.18 s slide)

/// A page switch while the new-line slide is still running: the page you open must show its own view, not the
/// end of the other page's slide. Returns failures.
func wSlideChecks(waitMs: Double) -> [String] {
    var bad: [String] = []
    for (name, act) in [("new page", { (c: CanvasView) in c.newPage() }), ("go to page", { (c: CanvasView) in c.goToPage(1 - c.pageIndex) })] {
        let r = WReal(waitMs: waitMs, widthIdx: 0, zoom: 3, viewX: 0)
        if name == "go to page" { r.canvas.newPage(); r.canvas.goToPage(0) }   // two pages, on the first
        let otherView = r.canvas.cameraForPage(1).center
        // A line that reaches the limit, then the pause: the move starts sliding.
        var o = r.obs
        for _ in 0..<40 {
            guard let p = wPlace(o.lineInk == nil ? .at(0.05) : .next, o) else { break }
            _ = r.apply(.write(.next), place: p); o = r.obs
            if o.pendingLiftAt != nil { break }
            if let l = o.lineInk, l.maxX > o.cam.visible.maxX - o.cam.visible.width * 0.15 { _ = r.apply(.pan(0.5), place: nil); o = r.obs }
        }
        guard o.pendingLiftAt != nil else { bad.append("\(name): setup never scheduled a move"); continue }
        r.vclock += waitMs / 1000 + 0.01
        r.canvas.advanceClock()   // the move starts its slide (no flush: the slide is still running)
        guard r.canvas.writingStateForTest.sliding else { bad.append("\(name): no slide started"); continue }
        act(r.canvas)
        let want: CGPoint = name == "new page" ? { var c = Camera(page: wPage); c.zoom = r.canvas.camera.zoom; c.home(); return c.center }() : otherView
        r.canvas.flushInputForTest()   // the next display ticks: the slide runs to its end
        let got = r.canvas.camera.center
        if abs(got.x - want.x) > 1e-6 || abs(got.y - want.y) > 1e-6 {
            bad.append(String(format: "%@ during the new-line slide: the page opened at (%.0f, %.0f), want its own view (%.0f, %.0f)", name, got.x, got.y, want.x, want.y))
        }
    }
    return bad
}

/// One arrow press (10% of the view) then writing well away from the line: a deliberate move, so a new block starts
/// there (P6: "arrows count"). Over a grid of zooms and view positions. Returns failures.
func wArrowChecks(waitMs: Double) -> [String] {
    var missed = 0, total = 0, example = ""
    for wi in 0..<3 { for z in stride(from: 1.5, through: 5.0, by: 0.25) { for vx in stride(from: 0.0, through: 0.6, by: 0.05) {
        let r = WReal(waitMs: waitMs, widthIdx: wi, zoom: z, viewX: vx)
        guard let p = wPlace(.at(0.1), r.obs) else { continue }
        _ = r.apply(.write(.at(0.1)), place: p)
        let before = r.canvas.camera.center.x
        _ = r.apply(.arrow(1), place: nil)
        guard abs(r.canvas.camera.center.x - before - 0.1 * r.canvas.camera.visible.width) < 1e-6 else { continue }   // a full press (not clamped)
        let o = r.obs
        guard let line = o.lineInk else { continue }
        let x = line.maxX + 0.12 * wPage.width
        let v = o.cam.visible, h = min(max(v.height * 0.06, 6), 60)
        guard x + 3 * h < v.maxX else { continue }
        let (_, c) = r.apply(.write(.next), place: CGRect(x: x, y: line.midY - h / 2, width: 3 * h, height: h))
        guard let s = c else { continue }
        total += 1
        if r.obs.runStart.map({ abs($0 - s.minX) > 1e-6 }) ?? true {
            missed += 1
            if example.isEmpty { example = String(format: "width %.0f%%, zoom %.2f, view x %.0f: block start stayed at %.1f, want %.1f", ToolState.lineWidths[wi] * 100, z, before - v.width / 2, r.obs.runStart ?? -1, s.minX) }
        }
    } } }
    return missed == 0 ? [] : ["one arrow press didn't count as a deliberate move in \(missed) of \(total) cases, e.g. \(example)"]
}

/// Draw mode left in the ~8 ms between a stroke's commit and the next sensor frame, with a second finger resting
/// (TLC's counterexample to EventuallyDone): that finger lifts outside draw mode, draw mode comes back, nothing touches.
/// The waiting move must still be done with (fire), not wait for the next touch. Returns failures.
func wStaleCountChecks(waitMs: Double) -> [String] {
    let r = WReal(waitMs: waitMs, widthIdx: 0, zoom: 1, viewX: 0)
    let c = r.canvas, pad = Multitouch.padMM
    func contact(_ id: Int32, _ x: Double, _ y: Double) -> Contact {
        Contact(id: id, state: 4, norm: CGPoint(x: x, y: y), mm: CGPoint(x: x * pad.width, y: y * pad.height), pressure: 25, size: 0.5, major: 7.5)
    }
    // A long stroke across the limit (½-page lines end at 53% of the page); a second finger lands late in it (after
    // 0.25 s and 6 mm, so it stays a stroke).
    var t = r.vclock
    for k in 0...60 { t += 0.008; c.handle([contact(1, 0.10 + 0.60 * Double(k) / 60, 0.5)], arrival: t, sensorT: t); c.advanceClock() }
    let late = contact(2, 0.75, 0.25)
    for k in 0...5 { t += 0.008; c.handle([contact(1, 0.70 + 0.002 * Double(k), 0.5), late], arrival: t, sensorT: t); c.advanceClock() }
    t += 0.008; r.vclock = t
    c.handle([late], arrival: t, sensorT: t)   // the drawing finger lifts: commit, move scheduled
    guard c.writingStateForTest.pending != nil else { return ["setup: the stroke didn't schedule a move"] }
    c.drawMode = false                          // Esc before the next frame
    t += 0.1; r.vclock = t
    c.handle([], arrival: t, sensorT: t)        // the resting finger lifts (ignored outside draw mode)
    c.drawMode = true
    r.tick(3 * waitMs / 1000)
    let s = c.writingStateForTest
    return s.pending == nil ? [] : [String(format: "a move still waiting %.1f s after its lift with nothing touching (the canvas still counts %d finger(s) down)", r.vclock - (s.pending?.liftAt ?? 0), s.countedContacts)]
}
