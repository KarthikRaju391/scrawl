// 0.1.6.1 stability checks (BENCH_ONLY=stability): the implicit states from the 6 Nov audit, at the canvas level. Each one
// fails on 0.1.6 (7955f70) and passes after the fix; the file only uses API that both have, so the same checks run on both.
//   #1 fingers already down when draw mode starts never ink or erase (whatever the palm-rejection setting)
//   #2 a two-finger gesture is a pan or a pinch, decided once: pans never zoom (synthetic, and Karthik's sessions)
//   #4 leaving draw mode (Esc, G) drops a waiting next-line move: no move, no haptic
//   #5 undo then redo of the word that crossed the limit still brings the next line
//   #6 the overview's thumbnail cache never takes a new page for a deleted one (same address, same version)
import AppKit
import CoreGraphics
import Foundation
import QuartzCore

func stabilityChecks(_ check: (Bool, String) -> Void) {
    let pad = Multitouch.padMM
    func contact(_ id: Int32, _ x: Double, _ y: Double, pressure: Double = 25) -> Contact {
        Contact(id: id, state: 4, norm: CGPoint(x: x, y: y), mm: CGPoint(x: x * pad.width, y: y * pad.height), pressure: pressure, size: 0.5, major: 7.5)
    }
    func newCanvas() -> CanvasView {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
        c.resumeOnDrawStart = false
        c.tools = ToolState()   // the pen (the bench's own defaults may hold another tool from an earlier run)
        return c
    }
    var t = 1000.0
    func frame(_ c: CanvasView, _ cs: [Contact]) { t += 0.008; c.handle(cs, arrival: t, sensorT: t) }

    // MARK: #1 fingers already down when draw mode starts
    do {
        // The finger that clicked the toolbar's Draw button: down (and pressing) before draw mode, then it moves and lifts.
        let c = newCanvas()
        var begins = 0, acts: [String] = []
        c.onAct = { a, _ in acts.append(a); if a == "strokeBegin" { begins += 1 } }
        for _ in 0..<5 { frame(c, [contact(7, 0.40, 0.40, pressure: 140)]) }   // outside draw mode: only tracked
        c.drawMode = true                                                       // the click's mouseDown
        for k in 0..<40 { frame(c, [contact(7, 0.40 + 0.004 * Double(k), 0.40)]) }
        frame(c, [])
        check(c.doc.strokes.isEmpty && begins == 0,
              "#1 the finger that clicked Draw (down before draw mode) draws nothing as it moves and lifts (strokes \(c.doc.strokes.count), stroke begins \(begins))")
        // A new touch after it lifted draws as usual (the control).
        let n0 = c.doc.strokes.count
        for k in 0..<40 { frame(c, [contact(8, 0.30 + 0.004 * Double(k), 0.60)]) }
        frame(c, [])
        check(c.doc.strokes.count == n0 + 1, "#1 the next touch draws one stroke (new strokes \(c.doc.strokes.count - n0))")
        if c.doc.strokes.count != n0 + 1 { print("  acts: \(acts.suffix(12))") }
    }
    do {
        // The Eraser button clicked with ink under the finger: nothing is erased, no undo step.
        let c = newCanvas()
        let p0 = c.camera.canvas(fromPad: CGPoint(x: 0.35, y: 0.5)), p1 = c.camera.canvas(fromPad: CGPoint(x: 0.65, y: 0.5))
        c.testAddStroke((0...40).map { k in StrokePoint(p: CGPoint(x: p0.x + (p1.x - p0.x) * Double(k) / 40, y: p0.y), pressure: 0.5) })
        var tl = c.tools; tl.tool = .eraser; c.tools = tl
        for _ in 0..<5 { frame(c, [contact(9, 0.40, 0.50, pressure: 140)]) }
        c.drawMode = true
        for k in 0..<40 { frame(c, [contact(9, 0.40 + 0.006 * Double(k), 0.50)]) }
        frame(c, [])
        check(c.doc.strokes.count == 1,
              "#1 Eraser clicked with ink under the finger: the ink stays (strokes \(c.doc.strokes.count) of 1)")
        // Control: a fresh eraser touch over it erases.
        for k in 0..<40 { frame(c, [contact(10, 0.40 + 0.006 * Double(k), 0.50)]) }
        frame(c, [])
        check(c.doc.strokes.isEmpty, "#1 a fresh eraser touch over the ink erases it (strokes \(c.doc.strokes.count))")
    }

    do {
        // Click to draw: a finger resting on the pad when draw mode starts aims, and a click then starts the stroke there.
        let was = CanvasView.clickToDraw
        CanvasView.clickToDraw = true
        t = CACurrentMediaTime()   // clickDown stamps real time; a stroke that ends within 50 ms of it is a tap
        let c = newCanvas()
        for _ in 0..<5 { frame(c, [contact(11, 0.45, 0.50)]) }
        c.drawMode = true
        for _ in 0..<5 { frame(c, [contact(11, 0.45, 0.50)]) }
        let aimedNoInk = c.doc.strokes.isEmpty
        c.clickDown()
        for k in 0..<30 { frame(c, [contact(11, 0.45 + 0.006 * Double(k), 0.50)]) }
        frame(c, [])
        c.drawMode = false
        CanvasView.clickToDraw = was
        check(aimedNoInk && c.doc.strokes.count == 1, "#1 click to draw: a finger already down aims (no ink), and a click draws with it (strokes \(c.doc.strokes.count))")
    }

    // MARK: #2 pan or pinch, decided once
    func runNav(_ frames: [[Contact]]) -> (ratios: [Double], moves: Int) {
        let g = GestureEngine()
        var ratios: [Double] = []
        g.onNavigate = { _, _, r in ratios.append(r) }
        for (i, f) in frames.enumerated() { g.frame(f, t: Double(i) * 0.008) }
        return (ratios, ratios.count)
    }
    do {
        // Four pans (right, left, up, diagonal), fingers 25 mm apart, the spread wobbling +-1.5 mm as real fingers do.
        var zoomed = 0, moves = 0
        for (dx, dy) in [(0.30, 0.0), (-0.30, 0.0), (0.0, 0.35), (0.25, -0.25)] {
            var f: [[Contact]] = []
            for k in 0...80 {
                let u = Double(k) / 80, wob = 1.5 * sin(Double(k) / 5) / pad.width
                let cx = 0.5 + dx * (u - 0.5), cy = 0.5 + dy * (u - 0.5), half = 12.5 / pad.width + wob / 2
                f.append([contact(1, cx - half, cy), contact(2, cx + half, cy)])
            }
            f.append([])
            let r = runNav(f)
            moves += r.moves; zoomed += r.ratios.filter { abs($0 - 1) > 1e-12 }.count
        }
        check(moves > 200 && zoomed == 0, "#2 4 synthetic pans with the spread wobbling +-1.5 mm: \(moves) moves, \(zoomed) with any zoom (want 0)")
        // A pinch: 20 -> 50 mm about a still centroid. It zooms by the spread after the dead zone.
        var f: [[Contact]] = []
        for k in 0...60 { let d = (20 + 30 * Double(k) / 60) / pad.width; f.append([contact(1, 0.5 - d / 2, 0.5), contact(2, 0.5 + d / 2, 0.5)]) }
        f.append([])
        let z = runNav(f).ratios.reduce(1, *)
        check(z > 2.0 && z < 2.5, String(format: "#2 a synthetic pinch 20 -> 50 mm zooms x%.2f (want 2.0-2.5)", z))
        // A pinch with one finger still: the centroid moves half the spread, still a pinch.
        f = []
        for k in 0...60 { let x2 = 0.5 + (20 + 30 * Double(k) / 60) / pad.width; f.append([contact(1, 0.5, 0.5), contact(2, x2, 0.5)]) }
        f.append([])
        let z1 = runNav(f).ratios.reduce(1, *)
        check(z1 > 2.0 && z1 < 2.5, String(format: "#2 a one-sided pinch (one finger still) zooms x%.2f (want 2.0-2.5)", z1))
    }
    sessionNavReplay(check)

    // MARK: #4 leaving draw mode drops a waiting move
    do {
        let c = newCanvas()
        var acts: [String] = []
        c.onAct = { a, _ in acts.append(a) }
        var now = 50.0
        c.now = { now }
        c.drawMode = true; c.writingMode = true
        c.setPendingMoveForTest()
        let cam0 = c.camera.center
        c.drawMode = false             // Esc (G leaves draw mode the same way)
        now += 2; c.advanceClock(); c.flushInputForTest()
        check(!acts.contains("newLine") && c.camera.center == cam0 && !c.hasPendingMoveForTest,
              "#4 Esc / G with a next-line move waiting: no move after the pause (newLine \(acts.contains("newLine")), view moved \(c.camera.center != cam0), still waiting \(c.hasPendingMoveForTest))")
    }

    // MARK: #5 undo, then redo, of the word that crossed the limit
    do {
        let r = WReal(waitMs: 400, widthIdx: 0, zoom: 1.5, viewX: 0)
        var pen = r.canvas.tools; pen.tool = .pen; r.canvas.tools = pen
        let v = r.canvas.camera.visible, h = v.height * 0.06
        // Words left to right on one line until one crosses the ½-page limit and a move is scheduled.
        var x = v.minX + 0.05 * v.width, scheduled = false
        for _ in 0..<30 {
            _ = r.apply(.write(.at(0)), place: CGRect(x: x, y: v.midY - h / 2, width: h * 2.5, height: h))
            r.tick(0.1)   // within the pause
            if r.obs.pendingLiftAt != nil { scheduled = true; break }
            x += h * 3.2
            if x > v.maxX - h * 3 { break }
        }
        if !scheduled { check(false, "#5 setup: no word crossed the limit") } else {
            let lines0 = r.canvas.newLineCount
            r.canvas.undo()                  // ⌘Z before the pause: the word goes, the move with it
            let afterUndo = r.obs.pendingLiftAt != nil
            r.canvas.redo()                  // ⇧⌘Z: the word is back
            r.tick(1.0)
            check(!afterUndo && r.canvas.newLineCount == lines0 + 1,
                  "#5 undo then redo of the word that crossed the limit: the next line comes after the pause (moves \(r.canvas.newLineCount - lines0), want 1)")
            // The scrub path: undo, undo, redo, redo.
            let r2 = WReal(waitMs: 400, widthIdx: 0, zoom: 1.5, viewX: 0)
            r2.canvas.tools = r.canvas.tools
            var x2 = v.minX + 0.05 * v.width, ok = false
            for _ in 0..<30 {
                _ = r2.apply(.write(.at(0)), place: CGRect(x: x2, y: v.midY - h / 2, width: h * 2.5, height: h))
                r2.tick(0.1)
                if r2.obs.pendingLiftAt != nil { ok = true; break }
                x2 += h * 3.2
            }
            let l2 = r2.canvas.newLineCount
            r2.canvas.undo(); r2.canvas.undo(); r2.canvas.redo(); r2.canvas.redo()
            r2.tick(1.0)
            check(ok && r2.canvas.newLineCount == l2 + 1, "#5 a scrub back two words and forward again: the next line still comes (moves \(r2.canvas.newLineCount - l2), want 1)")
        }
    }

    // MARK: #6 thumbnails of a deleted page and a new one at its address
    do {
        let page = CanvasView.pageUnits
        func stroke(_ y: Double, _ n: Int) -> Stroke {
            Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 4, points: (0...n).map { StrokePoint(p: CGPoint(x: 100 + Double($0) * 20, y: y), pressure: 0.5) }, maxStep: 2)
        }
        var reused = false, stale = false
        for _ in 0..<300 {
            var x: Document? = Document.new()
            for k in 0..<3 { x!.add(stroke(900 - Double(k) * 40, 30)) }      // the deleted page: 3 long lines
            _ = ThumbnailCache.shared.image(for: x!, page: page)
            let key = ObjectIdentifier(x!), v = x!.version
            x = nil                                                          // gone (⌘Z can't bring it back any more)
            let n = Document.new()                                           // N
            guard ObjectIdentifier(n) == key else { continue }
            reused = true
            while n.version < v { n.add(stroke(300, 2)) }                    // a few dots, same version count
            let (img, fresh) = ThumbnailCache.shared.cached(n)
            stale = fresh && img != nil
            break
        }
        check(!reused || !stale, "#6 a new page at a deleted page's address, at the same version: its thumbnail isn't the deleted page's (address reused \(reused), cached tile taken as fresh \(stale))")
        if !reused { print("NOTE #6: no address reuse in 300 tries; inconclusive") }
    }
}

/// #2 on Karthik's recorded sessions: every two-finger episode replayed through the GestureEngine and a camera (fresh at 300%
/// mid-page for each episode, so the zoom limits never clip). Ground truth from the raw contacts, independent of the engine:
/// a "pan" moved its centroid > 4 mm with the spread never changing > 8%; a "pinch" changed its spread > 15% and more than
/// 1.5x its centroid's travel. Writes one JSON line per episode to STABILITY_NAV_OUT (if set) for the old/new comparison.
func sessionNavReplay(_ check: (Bool, String) -> Void) {
    let dir = ProcessInfo.processInfo.environment["STABILITY_SESSIONS"] ?? (NSHomeDirectory() + "/code/trackpad-draw/data")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("session-2026") && $0.hasSuffix(".jsonl") }.sorted()
    guard !files.isEmpty else { check(false, "#2 sessions: none in \(dir)"); return }
    let out = ProcessInfo.processInfo.environment["STABILITY_NAV_OUT"].flatMap { p -> FileHandle? in
        FileManager.default.createFile(atPath: p, contents: nil); return FileHandle(forWritingAtPath: p) }
    Camera.margin = Settings.defaultEdgeGuard
    let pad = CGSize(width: 124.8, height: 76.8)
    var pans = 0, pansZoomed = 0, pinches = 0, pinchesZoomed = 0, mixed = 0, episodes = 0
    for name in files {
        guard let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { continue }
        let g = GestureEngine()
        var cam = Camera(page: CanvasView.pageUnits)
        var zoomChanges = 0, navs = 0
        var raw: (ids: [Int32], d0: Double, c0: CGPoint, maxSpread: Double, travel: Double, dEnd: Double)?
        var ep = 0, active = false
        func startEpisode() { cam = Camera(page: CanvasView.pageUnits); cam.zoom = 3; cam.center = CGPoint(x: 800, y: cam.page.height - 600); cam.clamp(); zoomChanges = 0; navs = 0; raw = nil }
        func endEpisode() {
            defer { active = false }
            guard navs > 0, let r = raw else { return }
            episodes += 1
            let spreadChange = r.maxSpread, travel = r.travel
            let kind: String
            if travel > 4 && spreadChange < 0.08 { kind = "pan"; pans += 1; if zoomChanges > 0 { pansZoomed += 1 } }
            else if spreadChange > 0.15 && abs(r.dEnd - r.d0) > 1.5 * travel { kind = "pinch"; pinches += 1; if abs(cam.zoom - 3) > 1e-6 { pinchesZoomed += 1 } }
            else { kind = "mixed"; mixed += 1 }
            let line: [String: Any] = ["file": name, "ep": ep, "kind": kind, "zoom": cam.zoom, "cx": cam.center.x, "cy": cam.center.y, "zoomChanges": zoomChanges,
                                       "navs": navs, "spread": spreadChange, "travel": travel, "dRatio": r.dEnd / r.d0]
            if let out, let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) { out.write(d); out.write(Data("\n".utf8)) }
        }
        g.onNavigate = { prev, now, ratio in
            let z = cam.zoom
            cam.navigate(from: prev, to: now, ratio: ratio, zoomLocked: false)
            navs += 1; if abs(cam.zoom - z) > 1e-12 { zoomChanges += 1 }
        }
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let k = o["k"] as? String else { continue }
            if k == "act", o["a"] as? String == "drawMode" { if active { endEpisode() }; g.reset(); continue }
            guard k == "touch", let cs = o["c"] as? [[Double]], let m = o["m"] as? Double else { continue }
            let contacts = cs.compactMap { a -> Contact? in
                guard a.count >= 5 else { return nil }
                return Contact(id: Int32(a[0]), state: Int32(a[1]), norm: CGPoint(x: a[2], y: a[3]), mm: CGPoint(x: a[2] * pad.width, y: a[3] * pad.height),
                               pressure: a[4], size: 0.5, major: 7.5)
            }
            let down = contacts.filter(\.isDown).filter { !g.ignoresAtEdge($0) }.sorted { $0.id < $1.id }
            if !active && !down.isEmpty { active = true; ep += 1; startEpisode() }
            if down.count >= 2 {
                let a = down[0], b = down[1], d = Double(hypot(a.mm.x - b.mm.x, a.mm.y - b.mm.y)), c = CGPoint(x: (a.mm.x + b.mm.x) / 2, y: (a.mm.y + b.mm.y) / 2)
                if let r = raw, r.ids == [a.id, b.id] {
                    raw = (r.ids, r.d0, r.c0, max(r.maxSpread, abs(log(max(d, 1) / max(r.d0, 1)))), max(r.travel, Double(hypot(c.x - r.c0.x, c.y - r.c0.y))), d)
                } else if raw == nil { raw = ([a.id, b.id], d, c, 0, 0, d) }
            }
            g.frame(contacts, t: m)
            if active && down.isEmpty { endEpisode() }
        }
        if active { endEpisode() }
    }
    try? out?.close()
    print("NAV sessions \(files.count), episodes with navigation \(episodes): pans \(pans) (zoomed \(pansZoomed)), pinches \(pinches) (zoomed \(pinchesZoomed)), mixed \(mixed)")
    check(pans > 50 && pansZoomed == 0, "#2 \(files.count) recorded sessions: \(pans) pans, \(pansZoomed) of them change the zoom (want 0)")
    check(pinches > 0 && pinchesZoomed == pinches, "#2 recorded sessions: \(pinches) pinches, \(pinchesZoomed) of them zoom (want all)")
}
