// Writing mode as a pure state machine, for the model checker and the fuzzer (writingVerify.swift; the properties
// P1-P8 are listed at its top).
//
// - `WModel` is CanvasView's writing-mode logic (the block after "Writing mode, now that the finger is up",
//   applyMove, advanceClock, endWritingLine, undo, newLineByHand, the hand-move bookkeeping), statement for
//   statement, written against the real `WritingLayout` and `Camera`. The fuzzer runs it next to the real
//   CanvasView on the same events and compares them after every step, so it can't drift from the app unnoticed.
// - `WSpec` is the oracle: the properties of the spec, with its own constants (95%, 93%, 3%, the wait W, 10%),
//   so a change to WritingLayout's constants or to Canvas's rules shows up as a violation.
import CoreGraphics
import Foundation

let wPage = CanvasView.pageUnits   // 1600 x 985

// MARK: - Events and what a check sees

/// Where a stroke goes, relative to what's on screen (writingVerify's grid of positions).
enum WPlace: Hashable {
    case next        // the next word: a word space after the line's end
    case zone        // ends inside the "full line" zone (3% of the line width before the limit, or 93-95% of the page)
    case short       // ends just before that zone
    case cross       // runs across the limit
    case edge        // ends at 94% of the page
    case idot        // a dot back inside the line, above it
    case nextLine    // one line below, at the block's start
    case indent      // one line below, 15% of the page right of the block's start
    case prevEnd     // back on the line a move just left, after its end
    case farRight    // on the line, 20% of the page right of its end
    case below       // five lines below, near the view's left
    case above       // three lines above, at the block's start
    case at(Double)  // on the line, this far across the view
}

enum WEv: Hashable {
    case write(WPlace)            // touch down, write a word, lift
    case down(WPlace), up         // a finger pressed and held across other events, then lifted (a dot)
    case tick(Double)             // time passes (seconds) with no new touch
    case edgeDown, edgeUp         // a palm / thumb on the pad's edge band
    case pan(Double)              // two-finger pan: the view moves this fraction of its width (+ = right)
    case pinch(Double)            // two-finger pinch about the view's middle, zoom ratio
    case arrow(Int)               // → / ← key
    case scroll(Double)           // two-finger scroll outside draw mode (no touch in draw mode), fraction of the view
    case undo, redo, scratch, ret, page, toggle, width(Int)
}

/// What every check sees, from the model or from the real CanvasView.
struct WObs {
    var writing: Bool
    var width: Double
    var cam: Camera
    var runStart: Double?
    var lineInk: CGRect?
    var lineStrokes: [CGRect]
    var prevLine: CGRect?
    var lineHeld: Bool
    var handRef: CGPoint?
    var pendingTarget: CGPoint?
    var pendingLiftAt: Double?
    var counted: Int
    var edge: Int
    var clock: Double
    var strokes: [CGRect]
    var limit: Double?
    var newLines: Int
    var page: Int
    var handPanX: Double? = nil   // the app's own measure (diagnostics only)
    var follows = 0               // follow moves made (0.1.6)
    var pendingFollow: CGPoint? = nil
    var blockView: Double? = nil  // the implementation's own block view width: only seeds the oracle for a run that starts mid-block
    var guide: Double? = nil      // the guide line's target strength (0: hidden); nil if not observed
}

// MARK: - The model (CanvasView's writing logic)

struct WModel {
    var waitMs = 400.0
    var writing = true
    var widthIdx = 2
    var cam = Camera(page: wPage)
    var lineInk: CGRect?
    var lineStrokes: [CGRect] = []
    var runStart: Double? { didSet { if runStart != oldValue { blockView = runStart == nil ? nil : WritingLayout.blockMeasure(visibleWidth: cam.visible.width, pageWidth: cam.page.width) } } }
    /// 0.1.6: the view's width when the block started (CanvasView.blockViewWidth).
    var blockView: Double?
    var blockWidth: Double? { Camera.columnBound ? nil : blockView.map { $0 * width } }
    var follows = 0
    var segmentStart: Double?
    var prevLine: (ink: CGRect, strokes: [CGRect])?
    var lineHeld = false
    var handPanX = 0.0
    var handRef: CGPoint?
    var pending: (target: CGPoint, liftAt: Double, waitMs: Double, follow: Bool)?
    var counted = 0
    var edge = 0
    var clock = 0.0
    struct Page { var strokes: [CGRect] = []; var undo: [[CGRect]] = []; var redo: [[CGRect]] = []; var cam: Camera? }
    var pages = [Page(), Page()]
    var pageIdx = 0
    var newLines = 0
    var held: CGRect?   // the dot a held finger is drawing

    var width: Double { ToolState.lineWidths[widthIdx] }
    var strokes: [CGRect] { pages[pageIdx].strokes }

    var obs: WObs {
        var l = WritingLayout(); l.lineWidth = width; l.segmentStart = segmentStart; l.blockWidth = blockWidth
        let lim: Double? = !writing || (!Camera.columnBound && blockWidth == nil) ? nil : l.lineEnd(lineLeft: l.lineStart(pageWidth: wPage.width), pageWidth: wPage.width)
        let nl = pending.flatMap { $0.follow ? nil : $0 }, fl = pending.flatMap { $0.follow ? $0.target : nil }
        return WObs(writing: writing, width: width, cam: cam, runStart: runStart, lineInk: lineInk, lineStrokes: lineStrokes, prevLine: prevLine?.ink,
                    lineHeld: lineHeld, handRef: handRef, pendingTarget: nl?.target, pendingLiftAt: nl?.liftAt, counted: counted, edge: edge,
                    clock: clock, strokes: strokes, limit: lim, newLines: newLines, page: pageIdx, follows: follows, pendingFollow: fl, blockView: blockView,
                    guide: { guard let l = lim, let r = lineInk?.maxX, let bw = blockWidth else { return 0 }; return 0.22 * min(max(1 - (l - r) / (CanvasView.limitShowWithin * bw), 0), 1) }())
    }

    private mutating func addStroke(_ s: CGRect) {
        pages[pageIdx].undo.append(pages[pageIdx].strokes); pages[pageIdx].redo = []; pages[pageIdx].strokes.append(s)
    }

    /// CanvasView.endStroke, from "Writing mode, now that the finger is up".
    mutating func commit(_ s: CGRect) {
        addStroke(s)
        guard writing else { return }
        let vh = cam.visible.height
        var continued = false
        if lineInk == nil, let p = prevLine, abs(s.midY - p.ink.midY) < max(p.ink.height * 0.6, vh * 0.05),
           s.minX >= p.ink.maxX - max(p.ink.height, cam.visible.width * 0.03) {
            lineInk = p.ink; lineStrokes = p.strokes; lineHeld = true; continued = true
        }
        if lineInk == nil { prevLine = nil }
        if let line = lineInk, abs(s.midY - line.midY) > max(line.height, vh * 0.12) * 1.2 || (lineHeld && s.midY < line.minY) {
            let nextOfBlock = s.midY < line.midY && line.midY - s.midY < max(line.height, vh * 0.12) * 3.5 &&
                runStart.map { abs(s.minX - $0) < cam.page.width * WritingLayout.newRunAway } == true
            lineInk = nil; lineStrokes = []; lineHeld = false; prevLine = nil
            if !nextOfBlock { segmentStart = nil; runStart = nil }
        }
        let vw = cam.visible.width
        let movedByHand = continued ? 0 : max(handPanX, handRef.map { abs(cam.center.x - $0.x) } ?? 0)
        if movedByHand >= vw * WritingLayout.deliberatePan * (1 - 1e-9) {
            if let line = lineInk {
                let gap = max(line.height * 1.5, vw * 0.08)
                if s.minX > line.maxX + max(gap, cam.page.width * WritingLayout.newRunAway) || s.maxX < line.minX - gap {
                    runStart = s.minX; lineInk = nil; lineStrokes = []
                }
            } else if runStart.map({ abs(s.minX - $0) > cam.page.width * WritingLayout.newRunAway }) ?? true {
                runStart = s.minX
            }
        }
        handPanX = 0; handRef = cam.center
        if runStart == nil { runStart = s.minX }
        segmentStart = runStart
        let line = lineInk.map { $0.union(s) } ?? s
        lineInk = line
        lineStrokes.append(s)
        decideMove(after: s, line: line)
    }

    /// CanvasView.decideMove: the move the line calls for (after a commit, or a redo bringing ink back).
    mutating func decideMove(after s: CGRect, line: CGRect) {
        if !Camera.columnBound, runStart == nil { runStart = line.minX; segmentStart = runStart }   // no block (a redo after it ended): the ink starts one
        var layout = WritingLayout()
        layout.lineWidth = width
        layout.segmentStart = segmentStart
        layout.blockWidth = blockWidth
        let start = runStart ?? layout.lineStart(pageWidth: cam.page.width)
        let move = layout.after(stroke: s, line: line, lineStrokes: lineStrokes, lineLeft: start, visible: cam.visible, pageWidth: cam.page.width)
        if move == .none || lineHeld { pending = nil }
        else if waitMs <= 0 { switch move { case .newLine(let c): applyMove(c); case .follow(let c): applyFollow(c); case .none: break } }
        else { switch move { case .newLine(let c): pending = (c, clock, waitMs, false); case .follow(let c): pending = (c, clock, waitMs, true); case .none: break } }
    }

    mutating func cancelPendingMove() { pending = nil }

    mutating func advanceClock() {
        guard let p = pending, counted == 0, clock - p.liftAt >= p.waitMs / 1000 else { return }
        pending = nil
        if p.follow { applyFollow(p.target) } else { applyMove(p.target) }
    }

    /// applyMove(.follow): the view slides right with the line (the line stays open).
    mutating func applyFollow(_ c: CGPoint) {
        follows += 1
        handPanX = 0   // the app's own move, like a next line (CanvasView)
        var target = cam; target.center = c; target.clamp(); handRef = target.center
        cam = target
    }

    /// applyMove(.newLine); the slide is finished at once (a touch finishes it in the app).
    mutating func applyMove(_ c: CGPoint) {
        newLines += 1
        if let l = lineInk { prevLine = (l, lineStrokes) }
        lineHeld = false; lineInk = nil; lineStrokes = []; segmentStart = runStart; handPanX = 0
        var target = cam; target.center = c; target.clamp(); handRef = target.center
        cam = target
    }

    mutating func endWritingLine(keepRun: Bool = false) {
        lineInk = nil; lineStrokes = []; pending = nil; handPanX = 0
        if !keepRun { runStart = nil }
        segmentStart = runStart; prevLine = nil; lineHeld = false
    }

    mutating func newLineByHand() {
        guard writing else { return }
        cancelPendingMove()
        let v = cam.visible, layout = WritingLayout()
        let midY = lineInk?.midY ?? v.midY
        let pitch = max((lineInk?.height ?? 0) * 1.35, v.height * 0.12)
        applyMove(WritingLayout.newLineCenter(lineLeft: runStart ?? layout.lineStart(pageWidth: cam.page.width), lineMidY: midY, pitch: pitch, visible: v, bounded: Camera.columnBound))
    }

    mutating func undo() {
        let line = lineStrokes
        if let s = pages[pageIdx].undo.popLast() { pages[pageIdx].redo.append(pages[pageIdx].strokes); pages[pageIdx].strokes = s }
        endWritingLine(keepRun: true)
        let left = line.filter { r in strokes.contains(r) }
        if writing, let first = left.first { lineStrokes = left; lineInk = left.dropFirst().reduce(first) { $0.union($1) } }
    }

    /// 0.1.6.1: the ink a redo brings back is on the line again (if it's on it, or no line is open), and the move is decided again.
    mutating func redo() {
        let before = strokes
        if let s = pages[pageIdx].redo.popLast() { pages[pageIdx].undo.append(pages[pageIdx].strokes); pages[pageIdx].strokes = s }
        guard writing else { return }
        let vh = cam.visible.height
        var pool = before   // what came back: the strokes not in `before`, counted (two strokes can have the same bounds)
        let back = strokes.filter { r in if let i = pool.firstIndex(of: r) { pool.remove(at: i); return false }; return true }
        for s in back where lineInk.map({ abs(s.midY - $0.midY) <= max($0.height, vh * 0.12) * 1.2 }) ?? true {
            lineInk = lineInk.map { $0.union(s) } ?? s; lineStrokes.append(s)
        }
        if let line = lineInk, let last = lineStrokes.last { decideMove(after: last, line: line) }
    }

    /// A camera move by hand: two fingers (counted: a pending move is dropped), with `pan` the sideways part
    /// that counts as a pan (zoom unchanged).
    mutating func handMove(to c: Camera, touch: Bool) {
        if touch { cancelPendingMove() }
        let x0 = cam.center.x, z0 = cam.zoom
        cam = c
        if touch && writing && abs(cam.zoom - z0) < 1e-9 { handPanX += abs(cam.center.x - x0) }
    }

    /// The event, as the app would see it. `stroke`: the committed stroke's bounds for writes and lifts (the fuzzer
    /// passes the real one; the explorer the placement). Returns false if the event can't happen in this state.
    @discardableResult
    mutating func apply(_ e: WEv, stroke: CGRect? = nil, camAfter: Camera? = nil) -> Bool {
        switch e {
        case .write:
            guard counted == 0, let s = stroke else { return false }
            counted = 1; cancelPendingMove(); advanceClock()
            clock += 0.2
            counted = 0; commit(s); advanceClock()
        case .down:
            guard counted == 0, let s = stroke else { return false }
            counted = 1; cancelPendingMove(); held = s
            clock += 0.05; advanceClock()
        case .up:
            guard counted == 1, let s = held else { return false }
            counted = 0; held = nil; commit(stroke ?? s); advanceClock()
        case .tick(let dt):
            clock += dt; advanceClock()
        case .edgeDown:
            guard edge == 0 else { return false }
            edge = 1; advanceClock()
        case .edgeUp:
            guard edge == 1 else { return false }
            edge = 0; advanceClock()
        case .pan(let f):
            guard counted == 0 else { return false }
            var c = cam; c.center.x += f * cam.visible.width; c.clamp()
            counted = 2; handMove(to: camAfter ?? c, touch: true); clock += 0.2; counted = 0; advanceClock()
        case .pinch(let r):
            guard counted == 0 else { return false }
            var c = cam; c.zoom = min(max(c.zoom * r, 1), Camera.maxZoom); c.clamp()
            if let p = CanvasView.zoomPresets.first(where: { abs(c.zoom - $0) / $0 < 0.04 }) { c.zoom = p; c.clamp() }   // snapZoomAfterPinch
            counted = 2; handMove(to: camAfter ?? c, touch: true); clock += 0.2; counted = 0; advanceClock()
        case .arrow(let d):
            guard counted == 0 else { return false }
            cancelPendingMove()
            let v = cam.visible
            cam.center.x += Double(d) * 0.1 * v.width; cam.clamp()
            if writing { handPanX += abs(cam.center.x - v.midX) }
        case .scroll(let f):
            guard counted == 0 else { return false }
            var c = cam; c.center.x += f * cam.visible.width; c.clamp()
            cancelPendingMove()
            handMove(to: camAfter ?? c, touch: false)
            clock += 0.1; advanceClock()
        case .undo:
            guard counted == 0 else { return false }
            undo()
        case .redo:
            guard counted == 0 else { return false }
            redo()
        case .scratch:
            // A scratch-out over the page's last stroke: erased, and (like the app) not a writing-mode stroke.
            guard counted == 0, let last = strokes.last else { return false }
            counted = 1; cancelPendingMove(); clock += 0.2; counted = 0
            pages[pageIdx].undo.append(pages[pageIdx].strokes); pages[pageIdx].redo = []
            pages[pageIdx].strokes.removeAll { $0 == last }
            _ = scratchedLine(last)
            advanceClock()
        case .ret:
            guard counted == 0 else { return false }
            newLineByHand()
        case .page:
            guard counted == 0 else { return false }
            endWritingLine()
            pages[pageIdx].cam = cam
            pageIdx = 1 - pageIdx
            if let c = pages[pageIdx].cam { cam = c } else { cam.home() }
        case .toggle:
            guard counted == 0 else { return false }
            writing.toggle(); endWritingLine()
        case .width(let i):
            guard counted == 0, i != widthIdx else { return false }
            widthIdx = i; cancelPendingMove()
        }
        return true
    }

    /// A scratch-out or eraser stroke that erased `gone` (the fuzzer passes what the app erased).
    mutating func erase(_ gone: [CGRect]) {
        counted = 1; cancelPendingMove(); clock += 0.2; counted = 0
        pages[pageIdx].undo.append(pages[pageIdx].strokes); pages[pageIdx].redo = []
        var pool = gone
        pages[pageIdx].strokes.removeAll { r in if let i = pool.firstIndex(of: r) { pool.remove(at: i); return true }; return false }
        scratchedLine(gone.first ?? .null)
        advanceClock()
    }

    /// pruneWritingLine: after a scratch-out or the eraser, the line is what's left of it.
    @discardableResult
    mutating func scratchedLine(_ gone: CGRect) -> Bool {
        func alive(_ rs: [CGRect]) -> [CGRect] { rs.filter { r in strokes.contains(r) } }
        let left = alive(lineStrokes)
        if left.count != lineStrokes.count { lineStrokes = left; lineInk = left.first.map { f in left.dropFirst().reduce(f) { $0.union($1) } } }
        if lineInk == nil { lineHeld = false }
        if let p = prevLine {
            let pl = alive(p.strokes)
            if pl.count != p.strokes.count { prevLine = pl.first.map { f in (pl.dropFirst().reduce(f) { $0.union($1) }, pl) } }
        }
        return true
    }
}

// MARK: - The oracle (the spec's properties, its own constants)

struct WSpec {
    var waitMs = 400.0
    static let rightCap = 0.95, nearEdge = 0.93, nearMarker = 0.03, deliberate = 0.10, newRun = 0.10, fromTop = 0.575, inset = 0.05, margin = 0.03

    /// What the oracle remembers between events.
    struct Mon: Hashable {
        var schedAt: Double?          // lift time of the commit that scheduled the pending move
        var downSinceSched = false    // a counted touch-down since then
        var refX: Double?             // view centre x after the last stroke or app move
        var panSum = 0.0              // sideways two-finger pans and arrows since then
        var blockRun: Double?         // 0.1.6: the block whose view width is remembered (its start)
        var blockView: Double?        //        the view's width when that block started
        var seeded = false
    }
    var mon = Mon()
    /// The cutoff spec's oracle (bench/cutoffSpec.swift, docs/writing-cutoff-spec.md): with --cutoff, the only properties checked.
    var cut = CutoffSpec()

    /// Before 0.1.6 (`--column-bound`): the line ends at the block's start + the width of the page, at most 95% of it; ink from
    /// 93% of the page is a full line. 0.1.6 (`blockView`, the view's width when the block started): the block's start + the
    /// width of that, no cap; only ink within 3% of the line before its end is a full line.
    static func limit(_ runStart: Double?, _ w: Double, _ blockView: Double? = nil) -> Double {
        if let bv = blockView, !Camera.columnBound { return (runStart ?? 0) + w * bv }
        return min((runStart ?? 0) + w * wPage.width, rightCap * wPage.width)
    }
    static func zone(_ limit: Double, _ w: Double, _ blockView: Double? = nil) -> Double {
        if let bv = blockView, !Camera.columnBound { return limit - nearMarker * w * bv }
        return limit > nearEdge * wPage.width ? nearEdge * wPage.width : limit - nearMarker * w * wPage.width
    }
    static let followWithin = 0.12, followTo = 0.5

    static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol * max(1, abs(a), abs(b)) }

    /// The runStart the block rules (P6) give for stroke `s` committed in state `o`, with `hand` = how far the view
    /// moved by hand since the last stroke.
    static func expectedRunStart(_ o: WObs, _ s: CGRect, hand: Double) -> Double { expectedBlock(o, s, hand: hand).start }
    /// The block start after stroke `s`, and whether the stroke started a new block (0.1.6: it takes the zoom then).
    static func expectedBlock(_ o: WObs, _ s: CGRect, hand: Double) -> (start: Double, fresh: Bool) {
        let v = o.cam.visible, W = wPage.width
        var line = o.lineInk, rs = o.runStart, continued = false
        if line == nil, let p = o.prevLine, abs(s.midY - p.midY) < max(p.height * 0.6, v.height * 0.05), s.minX >= p.maxX - max(p.height, v.width * 0.03) {
            line = p; continued = true
        }
        if let l = line, abs(s.midY - l.midY) > max(l.height, v.height * 0.12) * 1.2 || ((continued || o.lineHeld) && s.midY < l.minY) {   // well above or below; under a held line
            let nextOfBlock = s.midY < l.midY && l.midY - s.midY < max(l.height, v.height * 0.12) * 3.5 && rs.map { abs(s.minX - $0) < newRun * W } == true
            line = nil
            if !nextOfBlock { rs = nil }
        }
        var fresh = rs == nil
        if !continued && hand >= deliberate * v.width * (1 - 1e-9) {   // "10% or more": exactly 10% (one arrow press) counts
            if let l = line {
                let gap = max(l.height * 1.5, v.width * 0.08)
                if s.minX > l.maxX + max(gap, newRun * W) || s.maxX < l.minX - gap { rs = s.minX; fresh = true }
            } else if rs.map({ abs(s.minX - $0) > newRun * W }) ?? true { rs = s.minX; fresh = true }
        }
        return (rs ?? s.minX, fresh)
    }

    /// The view after a next-line move from state `o` (P5).
    static func expectedMoveCenter(_ o: WObs, line: CGRect?) -> CGPoint {
        let v = o.cam.visible
        let rs = o.runStart ?? margin * wPage.width
        let midY = line?.midY ?? v.midY, pitch = max((line?.height ?? 0) * 1.35, v.height * 0.12)
        var c = o.cam
        let left = rs - inset * v.width
        c.center = CGPoint(x: (Camera.columnBound ? max(left, 0) : left) + v.width / 2, y: midY - pitch + (fromTop - 0.5) * v.height)
        c.clamp()
        return c.center
    }

    static func liveMaxX(_ o: WObs) -> Double? {
        var pool = o.strokes
        var best: Double?
        for r in o.lineStrokes { if let i = pool.firstIndex(of: r) { pool.remove(at: i); best = max(best ?? -.infinity, r.maxX) } }
        return best
    }

    /// Check one transition. `committed`: the stroke committed by this event (nil if none). Returns violations as
    /// (property, message).
    mutating func check(_ e: WEv, pre: WObs, post: WObs, committed: CGRect?) -> [(String, String)] {
        if CutoffSpec.enabled { cut.waitMs = waitMs; return cut.check(e, pre: pre, post: post, committed: committed) }
        var bad: [(String, String)] = []
        func fail(_ p: String, _ m: String) { bad.append((p, m)) }
        let W = wPage.width, wait = waitMs / 1000
        let moved = post.newLines - pre.newLines, followed = post.follows - pre.follows
        // The block's view width, the oracle's own: taken when the block starts (its start changes), before the event's moves.
        // A run that starts mid-block (the explorer's and fuzzer's start states): the block began before the oracle watched.
        if !mon.seeded { mon.seeded = true; if pre.runStart != nil { mon.blockRun = pre.runStart; mon.blockView = pre.blockView } }
        // A stroke that starts a block (by the block rules, P6: a new start, or the same x anew), or the block's end.
        let handNow = max(mon.panSum, mon.refX.map { abs(pre.cam.center.x - $0) } ?? 0)
        let freshBlock = committed.map { c in post.writing && Self.expectedBlock(pre.writing ? pre : post, c, hand: handNow).fresh } ?? false
        if freshBlock || post.runStart != mon.blockRun { mon.blockRun = post.runStart; mon.blockView = post.runStart == nil ? nil : (WritingLayout.measureFromView ? pre.cam.visible.width : pre.cam.page.width) }
        let bv = Camera.columnBound ? nil : mon.blockView
        let touch: Bool = { switch e { case .write, .down, .pan, .pinch, .scratch: return true; default: return false } }()
        let handView: Bool = { switch e { case .pan, .pinch, .arrow, .scroll: return true; default: return false } }()

        // P1: automatic moves only after the wait, with no counted touch since the lift.
        if moved + followed > 0, e != .ret {
            switch e { case .tick, .edgeDown, .edgeUp, .scroll: break; default: fail("P1", "a move during \(e)") }
            if let t = mon.schedAt {
                if post.clock - t < wait - 1e-9 { fail("P1", String(format: "move %.0f ms after the lift (wait %.0f ms)", (post.clock - t) * 1000, waitMs)) }
                if mon.downSinceSched { fail("P1", "move after a counted touch-down that should have cancelled it") }
            } else { fail("P1", "move with nothing scheduled") }
            if post.counted > 0 { fail("P1", "move with a counted finger down") }
        }
        if moved + followed > 1 { fail("P1", "\(moved + followed) moves in one event") }
        // P2: written ink never moves.
        switch e {
        case .undo, .redo, .scratch, .page: break
        default:
            if post.page == pre.page && (post.strokes.count < pre.strokes.count || Array(post.strokes.prefix(pre.strokes.count)) != pre.strokes) { fail("P2", "strokes changed during \(e)") }
        }
        // P3: the guide line.
        if Camera.columnBound, post.writing, let lim = post.limit {
            if lim > Self.rightCap * W + 1e-6 { fail("P3", String(format: "limit at %.1f%% of the page", lim / W * 100)) }
            if !Self.near(lim, Self.limit(post.runStart, post.width)) { fail("P3", String(format: "limit %.1f, want min(runStart + %.0f%%, 95%%) = %.1f", lim, post.width * 100, Self.limit(post.runStart, post.width))) }
        } else if post.writing {
            // 0.1.6: at the block's start + the width x the view's width when the block started, whatever the zoom now; none
            // before a block.
            switch (post.limit, post.runStart, bv) {
            case let (lim?, rs?, b?):
                let want = Self.limit(rs, post.width, b)
                if !Self.near(lim, want) { fail("P3", String(format: "limit %.1f, want block start %.1f + %.0f%% x the block's view width %.1f = %.1f (zoom now %.2f)", lim, rs, post.width * 100, b, want, post.cam.zoom)) }
            case (nil, nil, _): break
            default: fail("P3", "limit \(post.limit.map { String(format: "%.1f", $0) } ?? "none") with block start \(post.runStart.map { String(format: "%.1f", $0) } ?? "none")")
            }
        }
        // P4: a move is pending exactly when the line's live ink reaches the zone (after a commit), and only then.
        if post.pendingLiftAt != nil {
            if post.counted > 0 { fail("P1", "a move pending with a counted finger down") }
            if !post.writing || post.lineHeld || post.lineInk == nil { fail("P4", "a move pending with no open line (writing \(post.writing), held \(post.lineHeld))") }
        }
        if let s = committed, post.writing {
            let lim = Self.limit(post.runStart, post.width, bv), zone = Self.zone(lim, post.width, bv)
            let right = Self.liveMaxX(post) ?? s.maxX
            let want = !post.lineHeld && right >= zone - 1e-6
            let has = post.pendingLiftAt != nil || moved > 0
            if want != has {
                fail("P4", String(format: "line's ink ends at %.1f (zone from %.1f, limit %.1f, held %@): move %@, want %@", right, zone, lim, post.lineHeld ? "yes" : "no",
                                  has ? "pending" : "none", want ? "pending" : "none") + String(format: " [counted %d, line ink to %.1f, %d line strokes, stroke %.1f-%.1f, event %@]", post.counted, post.lineInk?.maxX ?? -1, post.lineStrokes.count, s.minX, s.maxX, "\(e)"))
            }
            if let ink = post.lineInk, let first = post.lineStrokes.first {
                let u = post.lineStrokes.dropFirst().reduce(first) { $0.union($1) }
                if !Self.near(u.minX, ink.minX) || !Self.near(u.maxX, ink.maxX) { fail("P4", "the line's ink isn't its strokes") }
            }
            // P9 (0.1.6): a line running on past the view's right side: the view follows it, when no next line is due. The
            // follow is decided at this lift (the view it starts from is the view at the lift).
            if !Camera.columnBound {
                let v = pre.cam.visible
                let target = min(right - Self.followTo * v.width + v.width / 2, lim + v.width * 0.05 - v.width / 2)
                let wantFollow = !post.lineHeld && !want && right > v.maxX - Self.followWithin * v.width && target > v.midX + 1e-9
                let hasFollow = post.pendingFollow != nil || followed > 0
                if wantFollow != hasFollow {
                    fail("P9", String(format: "line's ink ends at %.1f, view %.1f-%.1f (follow from %.1f), limit %.1f: follow %@, want %@", right, v.minX, v.maxX,
                                      v.maxX - Self.followWithin * v.width, lim, hasFollow ? "yes" : "no", wantFollow ? "yes" : "no"))
                }
                if let f = post.pendingFollow, !Self.near(f.x, target, 1e-6) || !Self.near(f.y, v.midY, 1e-6) {
                    fail("P9", String(format: "follow target (%.1f, %.1f), want (%.1f, %.1f): the ink's end at the view's middle, never past the line's end", f.x, f.y, target, v.midY))
                }
            }
        }
        // P9: a follow moves the view right only, at the same height, and keeps the line open.
        if followed > 0 {
            if post.cam.center.x < pre.cam.center.x - 1e-9 || !Self.near(post.cam.center.y, pre.cam.center.y, 1e-6) || post.cam.zoom != pre.cam.zoom {
                fail("P9", String(format: "a follow moved the view from (%.1f, %.1f) to (%.1f, %.1f)", pre.cam.center.x, pre.cam.center.y, post.cam.center.x, post.cam.center.y))
            }
            if pre.lineInk != nil && post.lineInk == nil && moved == 0 { fail("P9", "a follow closed the line") }
        }
        // P5: where a move goes.
        if moved == 1 {
            let lineLeft = pre.lineInk
            let want = Self.expectedMoveCenter(WObs(writing: pre.writing, width: pre.width, cam: postMoveBase(pre: pre, post: post, e: e), runStart: pre.runStart,
                                                    lineInk: nil, lineStrokes: [], prevLine: nil, lineHeld: false, handRef: nil, pendingTarget: nil, pendingLiftAt: nil,
                                                    counted: 0, edge: 0, clock: 0, strokes: [], limit: nil, newLines: 0, page: 0), line: lineLeft)
            if !Self.near(post.cam.center.x, want.x, 1e-6) || !Self.near(post.cam.center.y, want.y, 1e-6) {
                fail("P5", String(format: "view centre after the move (%.1f, %.1f), want (%.1f, %.1f)", post.cam.center.x, post.cam.center.y, want.x, want.y))
            }
            if let r = post.handRef, !Self.near(r.x, post.cam.center.x) { fail("P5", String(format: "remembered centre %.1f, but the view went to %.1f", r.x, post.cam.center.x)) }
            // In view, unless it's off the page (a block whose first stroke started past the page's side) and the view is
            // against that side.
            let vis = post.cam.visible
            if let rs = post.runStart, (rs < vis.minX - 1e-6 && !(rs < 0 && vis.minX < 1e-6)) || (rs > vis.maxX + 1e-6 && !(rs > W && vis.maxX > W - 1e-6)) {
                fail("P5", String(format: "block start %.1f out of view after the move (view x %.1f-%.1f, zoom %.2f; pending target (%.1f, %.1f))", rs, post.cam.visible.minX, post.cam.visible.maxX, post.cam.zoom, pre.pendingTarget?.x ?? -1, pre.pendingTarget?.y ?? -1))
            }
        }
        // P6: blocks change only by the rules.
        let hand = max(mon.panSum, mon.refX.map { abs(pre.cam.center.x - $0) } ?? 0)
        if let s = committed, post.writing {
            let want = Self.expectedRunStart(pre.writing ? pre : post, s, hand: hand)
            if post.runStart == nil || !Self.near(post.runStart!, want) {
                fail("P6", String(format: "block start %@ after the stroke at x %.1f, want %.1f (hand move %.0f%% of the view)", post.runStart.map { String(format: "%.1f", $0) } ?? "nil", s.minX, want, hand / pre.cam.visible.width * 100) + String(format: " [oracle: pans %.6f, net %.6f; app: pans %.6f, net %.6f; 10%% = %.6f]", mon.panSum, mon.refX.map { abs(pre.cam.center.x - $0) } ?? -1, pre.handPanX ?? -1, pre.handRef.map { abs(pre.cam.center.x - $0.x) } ?? -1, 0.1 * pre.cam.visible.width))
            }
        } else if committed == nil {
            switch e {
            case .toggle, .page: if post.runStart != nil { fail("P6", "block kept after \(e)") }
            case .redo where pre.runStart == nil && !Camera.columnBound:
                // 0.1.7: with no block, the ink a redo brings back onto the line starts one at its left (it fell back to the
                // rules before 0.1.6); with no line ink back, still no block.
                let want: Double? = post.lineInk.map { Double($0.minX) }
                if post.runStart != want && !(post.runStart != nil && want != nil && Self.near(post.runStart!, want!)) {
                    fail("P6", "redo with no block: block start \(post.runStart.map { String(format: "%.1f", $0) } ?? "nil"), want the line's left \(want.map { String(format: "%.1f", $0) } ?? "nil")")
                }
            default:
                if pre.runStart != post.runStart { fail("P6", "block start changed by \(e): \(pre.runStart.map { String(format: "%.1f", $0) } ?? "nil") -> \(post.runStart.map { String(format: "%.1f", $0) } ?? "nil")") }
            }
        }
        // P7: the edge guard.
        if e == .edgeDown || e == .edgeUp {
            if (pre.pendingLiftAt != nil) && post.pendingLiftAt == nil && moved == 0 { fail("P7", "an edge contact cancelled the pending move") }
        }
        // P8: no stuck states; stale moves are dropped.
        if let t = post.pendingLiftAt, post.counted == 0, post.clock - t >= wait + 1e-9 { fail("P8a", String(format: "a move still pending %.0f ms after its lift", (post.clock - t) * 1000)) }
        if pre.pendingLiftAt != nil && moved > 0 && handView { fail("P8b", "a move fired after the view was moved by hand (\(e))") }
        if pre.pendingLiftAt != nil, committed == nil, post.pendingLiftAt != nil {
            switch e {
            case .scroll: fail("P8b", "a hand move of the view (scroll) left the pending move in place")
            case .width: fail("P8b", "a width change left the pending move in place")
            case .undo, .ret, .page, .toggle, .pan, .pinch, .arrow, .scratch, .down: fail("P8b", "\(e) left the pending move in place")
            default: break
            }
        }

        // The monitor.
        if touch { mon.downSinceSched = true }
        if case .pan = e, abs(post.cam.zoom - pre.cam.zoom) < 1e-9 { mon.panSum += abs(post.cam.center.x - pre.cam.center.x) }
        if case .arrow = e, pre.writing { mon.panSum += abs(post.cam.center.x - pre.cam.center.x) }
        if committed != nil, post.writing { mon.refX = post.cam.center.x; mon.panSum = 0 }
        if moved > 0 || followed > 0 { mon.refX = post.cam.center.x; mon.panSum = 0 }   // the app's own moves aren't hand moves
        switch e { case .toggle, .page, .undo: mon.panSum = 0; default: break }
        if committed != nil || e == .redo, let t = post.pendingLiftAt { mon.schedAt = t; mon.downSinceSched = false }   // a redo decides the move too (0.1.6.1)
        else if committed != nil || e == .redo, post.pendingFollow != nil { mon.schedAt = post.clock; mon.downSinceSched = false }   // a follow, from this lift (0.1.6)
        else if post.pendingLiftAt == nil && post.pendingFollow == nil { mon.schedAt = nil }
        return bad
    }

    /// The camera a move started from (for P5): the post-event camera (moves don't zoom) with the pre-event centre.
    private func postMoveBase(pre: WObs, post: WObs, e: WEv) -> Camera { var c = post.cam; c.center = pre.cam.center; return c }
}
