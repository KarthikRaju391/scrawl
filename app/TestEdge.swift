// --test-edge: the edge guard, through the real input path (synthetic contacts, background).
// Each case starts from a clean page and view. checks/edge.sh reads test-edge.json.
import AppKit

enum TestEdge {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, container = app.container!, dir = AppPaths.dataDir
        let pad = Multitouch.padMM
        var t = 0.0
        var r: [String: Any] = ["guard": Camera.margin, "padMM": [pad.width, pad.height]]
        app.enterDrawMode(lock: false)
        var tools = canvas.tools; tools.zoomLocked = false; tools.aimFirst = false; canvas.tools = tools
        /// One frame: contacts as (id, x mm, y mm).
        func frame(_ cs: [(Int32, Double, Double)], p: Double = 30) {
            t += 0.008
            canvas.handle(cs.map { Contact(id: $0.0, state: 4, norm: CGPoint(x: $0.1 / pad.width, y: $0.2 / pad.height), mm: CGPoint(x: $0.1, y: $0.2),
                                           pressure: p, size: 0.5, major: 7.5) }, arrival: t + 1000, sensorT: t)
        }
        func liftAll() { for _ in 0..<6 { frame([]) } }
        func reset() {
            liftAll(); canvas.clearPage(); canvas.setVisibleForReplay(x: 0, y: canvas.camera.page.height - canvas.camera.page.height / 3, w: canvas.camera.page.width / 3, z: 3)
            canvas.flushInputForTest()
        }
        func state() -> [String: Any] {
            canvas.flushInputForTest()
            let v = canvas.camera.visible
            return ["strokes": canvas.doc.strokes.count, "zoom": canvas.camera.zoom, "viewX": v.minX, "viewY": v.minY,
                    "points": canvas.doc.strokes.map(\.points.count)]
        }
        func viewFrac(_ p: CGPoint) -> [Double] { let v = canvas.camera.visible; return [(p.x - v.minX) / v.width, (p.y - v.minY) / v.height] }
        let gx = Camera.margin * pad.width, gy = Camera.margin * pad.height   // band width in mm (sides, top/bottom)

        func cases(_ prefix: String) {
            // 1. A stroke that starts in the side band, and one in the bottom band: no ink.
            reset()
            for k in 0...40 { frame([(1, gx * 0.4, 30 + Double(k) * 0.5)]) }; liftAll()
            for k in 0...40 { frame([(2, 40 + Double(k) * 0.5, gy * 0.4)]) }; liftAll()
            r[prefix + "strokeStartingInBand"] = state()
            // 2. Palm resting on the right side first, then a real stroke in the middle: one full stroke, no pan.
            reset()
            for _ in 0..<10 { frame([(9, pad.width - gx * 0.5, 40)]) }
            for k in 0...60 { frame([(9, pad.width - gx * 0.5, 40 + Double(k) * 0.02), (1, 40 + Double(k) * 0.6, 35 + sin(Double(k) / 6) * 4)]) }
            liftAll()
            r[prefix + "palmOnSideThenStroke"] = state()
            // 3. Palm lands on the left side during a stroke (after 0.1 s): the stroke continues, no pan.
            reset()
            for k in 0...60 {
                var cs: [(Int32, Double, Double)] = [(1, 40 + Double(k) * 0.6, 35)]
                if k > 12 { cs.append((9, gx * 0.5, 30 + Double(k) * 0.03)) }
                frame(cs)
            }
            liftAll()
            r[prefix + "palmLandsMidStroke"] = state()
            // 4. Thumb resting on the bottom edge, then a real pinch (two fingers inside spreading apart): zooms.
            reset()
            // The thumb gets the lowest id: the pinch uses the two lowest ids it counts, so a thumb that
            // slipped past the guard would be one of them.
            for _ in 0..<10 { frame([(0, 60, gy * 0.4)]) }
            for k in 0...40 { let d = 10 + Double(k) * 0.5; frame([(0, 60, gy * 0.4), (1, 60 - d, 40), (2, 60 + d, 40)]) }
            liftAll()
            r[prefix + "pinchWithThumbOnBottom"] = state()
            // 5. Two-finger pan with one finger in the band: only one finger counts, so no pan or zoom.
            reset()
            for k in 0...40 { frame([(1, 50, 40 + Double(k) * 0.4), (2, pad.width - gx * 0.4, 40 + Double(k) * 0.4)]) }
            liftAll()
            r[prefix + "panWithOneFingerInBand"] = state()
            // 6. A stroke that starts inside and runs out into the band (to x = 1 mm from the edge): kept, ink goes to the edge.
            reset()
            for k in 0...60 { frame([(1, 40 - Double(k) * (39.0 / 60), 35)]) }
            liftAll()
            var s6 = state()
            if let st = canvas.doc.strokes.first { s6["firstInk"] = viewFrac(st.points.first!.p); s6["lastInk"] = viewFrac(st.points.last!.p) }
            r[prefix + "strokeIntoBand"] = s6
        }
        cases("")
        // 7. The active area's corners land on the writing area's corners: windowed and full-screen sizes.
        var corners: [[String: Any]] = []
        for size in [nil, CGSize(width: 1512, height: 950), CGSize(width: 1920, height: 1080)] as [CGSize?] {
            if let size { container.setFrameSize(size) }
            container.needsLayout = true; container.layoutSubtreeIfNeeded()
            reset()
            var got: [[Double]] = []
            for (cx, cy) in [(gx + 0.01, gy + 0.01), (pad.width - gx - 0.01, pad.height - gy - 0.01)] {
                for k in 0...20 { frame([(1, cx + (cx < 50 ? 1 : -1) * Double(k) * 0.3, cy)]) }; liftAll()
                canvas.flushInputForTest()
                if let st = canvas.doc.strokes.last { got.append(viewFrac(st.points.first!.p)) }
            }
            corners.append(["view": [canvas.bounds.width, canvas.bounds.height], "firstInk": got])
        }
        r["cornerStrokes"] = corners
        // 8. Control: the same cases with the guard off.
        Camera.margin = 0
        cases("off.")
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-edge.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
