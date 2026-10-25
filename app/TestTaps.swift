// --test-taps: two-finger double tap = undo, three-finger double tap = redo (draw mode, incl. writing mode),
// through the real input path on a virtual clock. checks/taps.sh reads test-taps.json.
import AppKit

enum TestTaps {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, tb = app.container.toolbar, dir = AppPaths.dataDir, pad = Multitouch.padMM
        var t = 0.0
        func frame(_ cs: [(Int32, Double, Double)]) {
            t += 0.008
            canvas.handle(cs.map { Contact(id: $0.0, state: 4, norm: CGPoint(x: $0.1 / pad.width, y: $0.2 / pad.height), mm: CGPoint(x: $0.1, y: $0.2),
                                           pressure: 30, size: 0.5, major: 7.5) }, arrival: t + 1000, sensorT: t)
        }
        func idle(_ s: Double) { var l = s; while l > 0 { frame([]); l -= 0.008 } }
        var nextId: Int32 = 100
        /// n fingers down together for `dur` seconds (moving `move` mm), then up.
        func tap(_ n: Int, dur: Double = 0.1, move: Double = 0) {
            let ids = (0..<n).map { _ -> Int32 in nextId += 1; return nextId }
            let steps = max(Int(dur / 0.008), 1)
            for k in 0...steps {
                let d = move * Double(k) / Double(steps)
                frame(ids.enumerated().map { (i, id) in (id, 45 + Double(i) * 14 + d, 38) })
            }
            idle(0.016)
        }
        func stroke(y: Double) { nextId += 1; let id = nextId; for k in 0...30 { frame([(id, 30 + Double(k), y)]) }; idle(0.05) }
        func state(_ at: String) -> [String: Any] {
            let v = canvas.camera.visible
            let toast = app.container.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "toast" }
            return ["at": at, "strokes": canvas.doc.strokes.count, "viewX": v.minX, "viewY": v.minY, "zoom": canvas.camera.zoom,
                    "undoEnabled": tb.isEnabled(.undo), "redoEnabled": tb.isEnabled(.redo),
                    "toast": (toast?.isHidden == false) ? (toast?.stringValue ?? "") : ""]
        }
        var steps: [[String: Any]] = []
        app.enterDrawMode(lock: false)
        var tl = canvas.tools; tl.zoomLocked = false; tl.tool = .pen; canvas.tools = tl
        canvas.clearPage()
        canvas.setVisibleForReplay(x: 300, y: canvas.camera.page.height - canvas.camera.page.height / 2 - 150, w: canvas.camera.page.width / 2, z: 2)
        stroke(y: 30); stroke(y: 40); stroke(y: 50)
        steps.append(state("three strokes"))
        tap(2); idle(0.12); tap(2); idle(0.4); steps.append(state("two-finger double tap"))
        tap(3); idle(0.12); tap(3); idle(0.4); steps.append(state("three-finger double tap"))
        tap(2); idle(0.6); steps.append(state("single two-finger tap"))
        tap(3); idle(0.6); steps.append(state("single three-finger tap"))
        tap(2); idle(0.6); tap(2); idle(0.6); steps.append(state("slow double tap (0.6 s apart)"))
        tap(2, dur: 0.1, move: 6); idle(0.12); tap(2, dur: 0.1, move: 6); idle(0.4); steps.append(state("two quick short two-finger pans"))
        tap(2, dur: 0.5, move: 25); idle(0.4); steps.append(state("two-finger pan"))
        // Pinch: fingers spread apart.
        do { nextId += 2; let a = nextId - 1, b = nextId
             for k in 0...30 { let d = 10 + Double(k) * 0.6; frame([(a, 60 - d, 38), (b, 60 + d, 38)]) }; idle(0.4) }
        steps.append(state("pinch"))
        // Writing mode: the gesture still undoes.
        app.toggleWriting(); stroke(y: 25); steps.append(state("writing mode, one more stroke"))
        tap(2); idle(0.1); tap(2); idle(0.4); steps.append(state("writing mode: two-finger double tap"))
        app.toggleWriting()
        // Eraser selected: undo undoes the last real change (the tap starts no eraser stroke).
        var tp = canvas.tools; tp.tool = .pen; canvas.tools = tp
        stroke(y: 45)                                                    // a line to erase, in this view
        var te = canvas.tools; te.tool = .eraser; canvas.tools = te
        steps.append(state("a new line, eraser selected"))
        stroke(y: 45); steps.append(state("eraser stroke over a line"))
        tap(2); idle(0.1); tap(2); idle(0.4); steps.append(state("eraser selected: two-finger double tap"))
        // Eraser: one finger lands on a line and moves along it, a second joins 40 ms later (a pan): nothing erased.
        var tp2 = canvas.tools; tp2.tool = .pen; canvas.tools = tp2
        stroke(y: 55)
        var te2 = canvas.tools; te2.tool = .eraser; canvas.tools = te2
        steps.append(state("a line to pan over, eraser selected"))
        do { nextId += 2; let a = nextId - 1, b = nextId
             for k in 0..<5 { frame([(a, 30 + Double(k), 55)]) }
             for k in 5..<30 { frame([(a, 30 + Double(k), 55), (b, 50 + Double(k), 45)]) }
             idle(0.4) }
        steps.append(state("eraser: one finger on the line, a second joins (pan)"))
        try? JSONSerialization.data(withJSONObject: ["steps": steps], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-taps.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
