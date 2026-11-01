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
            let toast = app.container.subviews.compactMap { $0 as? PillLabel }.first { $0.identifier?.rawValue == "toast" }
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
        // Recorded double taps, replayed at their own times: the view must not move on any frame, not just end where it
        // was (Karthik, 1 Nov: the taps nudged it, then it snapped back).
        var jittered: [[String: Any]] = []
        for (name, frames) in recordedDoubleTaps {
            idle(0.5)
            let v0 = canvas.camera.visible, z0 = canvas.camera.zoom, s0 = canvas.doc.strokes.count, base = t
            var moved = 0, worst = 0.0
            for (dt, cs) in frames {
                t = base + dt
                canvas.handle(cs.map { Contact(id: $0.0 + nextId, state: 4, norm: CGPoint(x: $0.1 / pad.width, y: $0.2 / pad.height), mm: CGPoint(x: $0.1, y: $0.2),
                                               pressure: 30, size: 0.5, major: 7.5) }, arrival: t + 1000, sensorT: t)
                let v = canvas.camera.visible
                if v != v0 || canvas.camera.zoom != z0 { moved += 1; worst = max(worst, abs(v.minX - v0.minX), abs(v.minY - v0.minY), abs(v.width - v0.width)) }
            }
            nextId += 100
            idle(0.4)
            jittered.append(["name": name, "frames": frames.count, "framesMoved": moved, "worstMove": worst, "strokesBefore": s0, "strokesAfter": canvas.doc.strokes.count,
                             "viewSameAfter": canvas.camera.visible == v0 && canvas.camera.zoom == z0])
        }
        try? JSONSerialization.data(withJSONObject: ["steps": steps, "jittered": jittered], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-taps.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }

    /// The two two-finger and two three-finger double taps from Karthik's sessions (29-30 Oct) whose fingers moved
    /// most (the pair's centroid and distance, as the gesture engine measures them), extracted by finger from the
    /// recorded touch frames: (seconds from the first touch, [(finger, pad x mm, pad y mm)]), each tap ending in a
    /// frame with no fingers.
    static let recordedDoubleTaps: [(String, [(Double, [(Int32, Double, Double)])])] = [
        ("2-finger, 20261030-202807 (centroid 1.41 mm, distance 0.39 mm)", [
            (0.0000, [(1, 44.83, 32.84), (2, 56.06, 49.99)]),
            (0.0019, [(1, 44.68, 33.03), (2, 55.87, 50.14)]),
            (0.0081, [(1, 44.54, 33.13), (2, 55.62, 50.29)]),
            (0.0163, [(1, 44.50, 33.12), (2, 55.54, 50.30)]),
            (0.0247, [(1, 44.52, 33.12), (2, 55.52, 50.30)]),
            (0.0340, [(1, 44.52, 33.12), (2, 55.51, 50.28)]),
            (0.0412, [(1, 44.50, 33.06), (2, 55.51, 50.27)]),
            (0.0497, [(1, 44.50, 33.01), (2, 55.52, 50.25)]),
            (0.0580, [(1, 44.52, 33.01), (2, 55.65, 50.30)]),
            (0.0663, [(1, 44.52, 33.01), (2, 55.65, 50.30)]),
            (0.0746, []),
            (0.1331, [(11, 44.82, 33.53), (12, 55.82, 50.17)]),
            (0.1415, [(11, 43.85, 32.49), (12, 54.87, 49.14)]),
            (0.1497, [(11, 44.72, 33.58), (12, 55.46, 50.53)]),
            (0.1580, [(11, 44.60, 33.62), (12, 55.32, 50.54)]),
            (0.1664, [(11, 44.54, 33.50), (12, 55.34, 50.57)]),
            (0.1748, [(11, 44.45, 33.41), (12, 55.34, 50.59)]),
            (0.1830, [(11, 44.45, 33.41), (12, 55.34, 50.59)]),
            (0.1912, [])]),
        ("2-finger, 20261030-202807 (centroid 0.78 mm, distance 1.23 mm)", [
            (0.0000, [(1, 62.54, 61.18), (2, 54.49, 36.73)]),
            (0.0083, [(1, 62.01, 61.30), (2, 54.39, 37.04)]),
            (0.0166, [(1, 61.79, 61.49), (2, 54.20, 37.37)]),
            (0.0250, [(1, 61.74, 61.59), (2, 54.23, 37.46)]),
            (0.0333, [(1, 61.71, 61.56), (2, 54.28, 37.41)]),
            (0.0417, [(1, 61.65, 61.50), (2, 54.33, 37.36)]),
            (0.0500, [(1, 61.61, 61.37), (2, 54.46, 37.25)]),
            (0.0585, [(1, 61.51, 61.18), (2, 54.66, 37.24)]),
            (0.0669, [(1, 61.45, 60.86), (2, 54.80, 37.27)]),
            (0.0752, [(1, 61.45, 60.86), (2, 54.80, 37.27)]),
            (0.0833, []),
            (0.1753, [(11, 61.55, 60.50), (12, 54.44, 36.92)]),
            (0.1836, [(11, 61.09, 60.63), (12, 54.31, 37.24)]),
            (0.1919, [(11, 60.63, 60.96), (12, 54.18, 37.42)]),
            (0.2000, [(11, 60.64, 60.98), (12, 54.16, 37.42)]),
            (0.2083, [(11, 60.60, 60.97), (12, 54.23, 37.40)]),
            (0.2166, [(11, 60.67, 60.93), (12, 54.33, 37.36)]),
            (0.2249, [(11, 60.73, 60.82), (12, 54.50, 37.29)]),
            (0.2250, [(11, 60.83, 60.70), (12, 54.70, 37.27)]),
            (0.2333, [(11, 60.85, 60.53), (12, 54.86, 37.18)]),
            (0.2416, [(11, 60.88, 60.37), (12, 55.01, 37.19)]),
            (0.2500, [(11, 60.88, 60.37), (12, 55.01, 37.19)]),
            (0.2582, [])]),
        ("3-finger, 20261030-001007 (centroid 0.59 mm, distance 1.67 mm)", [
            (0.0000, [(2, 37.29, 52.83), (3, 22.06, 38.16)]),
            (0.0085, [(1, 54.44, 65.21), (2, 37.19, 53.05), (3, 22.06, 38.10)]),
            (0.0167, [(1, 53.59, 65.63), (2, 37.27, 53.35), (3, 22.06, 38.04)]),
            (0.0250, [(1, 53.41, 65.69), (2, 37.34, 53.36), (3, 22.16, 38.10)]),
            (0.0333, [(1, 53.41, 65.68), (2, 37.37, 53.35), (3, 22.16, 38.00)]),
            (0.0429, [(1, 53.50, 65.66), (2, 37.42, 53.33), (3, 22.21, 37.91)]),
            (0.0583, [(1, 53.51, 65.54), (2, 37.54, 53.34), (3, 22.31, 37.86)]),
            (0.0584, [(1, 53.46, 65.37), (2, 37.70, 53.32), (3, 22.44, 37.85)]),
            (0.0667, [(1, 53.40, 65.22), (2, 37.80, 53.25), (3, 22.44, 37.85)]),
            (0.0750, [(1, 53.25, 65.03), (2, 37.80, 53.25)]),
            (0.0833, [(1, 53.19, 64.89)]),
            (0.0917, [(1, 53.19, 64.89)]),
            (0.1000, []),
            (0.1500, [(11, 52.92, 64.64), (12, 37.64, 53.87), (13, 22.15, 38.48)]),
            (0.1584, [(11, 52.83, 64.78), (12, 37.46, 53.85), (13, 21.88, 38.56)]),
            (0.1667, [(11, 52.83, 64.95), (12, 37.44, 53.99), (13, 21.96, 38.52)]),
            (0.1750, [(11, 52.90, 64.97), (12, 37.50, 54.07), (13, 21.99, 38.59)]),
            (0.1833, [(11, 52.93, 65.00), (12, 37.53, 54.07), (13, 22.00, 38.59)]),
            (0.1917, [(11, 52.94, 65.00), (12, 37.51, 54.02), (13, 22.00, 38.55)]),
            (0.2000, [(11, 52.93, 65.00), (12, 37.60, 54.01), (13, 22.00, 38.49)]),
            (0.2083, [(11, 52.97, 65.01), (12, 37.74, 54.07), (13, 22.05, 38.43)]),
            (0.2167, [(11, 53.02, 65.01), (12, 37.80, 54.01), (13, 22.10, 38.31)]),
            (0.2250, [(11, 53.08, 65.01), (12, 37.80, 54.01), (13, 22.19, 38.24)]),
            (0.2333, [(11, 53.06, 64.94), (13, 22.19, 38.24)]),
            (0.2417, [(11, 53.06, 64.94)]),
            (0.2417, [])]),
        ("3-finger, 20261029-223601 (centroid 0.41 mm, distance 0.90 mm)", [
            (0.0000, [(1, 59.77, 39.06), (2, 71.93, 53.11), (3, 84.90, 62.15)]),
            (0.0083, [(1, 59.53, 39.00), (2, 72.01, 53.18), (3, 84.91, 62.31)]),
            (0.0166, [(1, 59.45, 39.11), (2, 72.02, 53.23), (3, 84.94, 62.33)]),
            (0.0250, [(1, 59.50, 38.96), (2, 71.98, 53.20), (3, 84.96, 62.33)]),
            (0.0333, [(1, 59.43, 38.91), (2, 72.00, 53.17), (3, 84.98, 62.30)]),
            (0.0416, [(1, 59.40, 38.85), (2, 71.76, 52.88), (3, 84.70, 62.02)]),
            (0.0500, [(1, 59.35, 38.73), (2, 71.76, 52.88), (3, 84.65, 61.87)]),
            (0.0583, [(1, 59.29, 38.62), (3, 84.68, 61.75)]),
            (0.0666, [(1, 59.29, 38.62), (3, 84.68, 61.75)]),
            (0.0749, []),
            (0.1333, [(11, 58.78, 38.52), (12, 71.36, 52.56), (13, 85.61, 62.71)]),
            (0.1416, [(11, 58.53, 38.45), (12, 71.25, 52.86), (13, 85.46, 62.81)]),
            (0.1499, [(11, 58.54, 38.48), (12, 71.24, 52.89), (13, 85.43, 62.98)]),
            (0.1583, [(11, 58.64, 38.43), (12, 71.31, 52.87), (13, 85.49, 62.93)]),
            (0.1666, [(11, 58.72, 38.40), (12, 71.44, 52.91), (13, 85.51, 62.95)]),
            (0.1749, [(11, 58.74, 38.35), (12, 71.65, 52.98), (13, 85.69, 63.02)]),
            (0.1833, [(11, 58.83, 38.32), (12, 71.93, 53.11), (13, 85.87, 63.08)]),
            (0.1916, [(11, 58.97, 38.28), (12, 71.93, 53.11), (13, 86.02, 63.21)]),
            (0.1999, [(11, 58.98, 38.21), (13, 86.02, 63.21)]),
            (0.2083, [(11, 58.98, 38.21)]),
            (0.2083, [])]),
    ]
}
