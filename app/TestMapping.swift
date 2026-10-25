// --test-mapping: any window shape, and full screen. The paper fills the whole view (no grey chrome);
// the trackpad's active area maps without distortion to the largest pad-shaped rectangle in the view,
// centred, outlined in draw mode; pan, zoom, zoom lock and the edge guard still work.
// Window shapes are real window sizes (screenshots requested from checks/mapping.sh: the test writes
// shot-N.req and waits for shot-N.done); full-screen sizes resize the content view only (taking a Space
// would take the screen from the user). checks/mapping.sh reads test-mapping.json.
import AppKit

enum TestMapping {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, container = app.container!, dir = AppPaths.dataDir, pad = Multitouch.padMM
        var r: [String: Any] = ["padAspect": AppDelegate.padAspect, "fullScreenPrimary": app.window.collectionBehavior.contains(.fullScreenPrimary),
                                "aspectLocked": app.window.contentAspectRatio != .zero && app.window.contentAspectRatio.width > 0,
                                "edgeGuard": Camera.margin]
        var t = canvas.tools; t.background = 0; t.zoomLocked = false; canvas.tools = t
        var vt = 0.0
        func frame(_ cs: [(Int32, Double, Double)]) {
            vt += 0.008
            canvas.handle(cs.map { Contact(id: $0.0, state: 4, norm: CGPoint(x: $0.1 / pad.width, y: $0.2 / pad.height), mm: CGPoint(x: $0.1, y: $0.2),
                                           pressure: 30, size: 0.5, major: 7.5) }, arrival: vt + 1000, sensorT: vt)
        }
        func lift() { for _ in 0..<5 { frame([]) } }
        func waitForShot(_ n: Int, _ name: String) -> Bool {
            try? name.write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return false
        }
        let g = Camera.margin
        let gx = g * pad.width, gy = g * pad.height
        var scenarios: [[String: Any]] = []
        let shapes: [(String, CGSize, Bool)] = [   // name, size, real window (screenshot) or content view only
            ("window, pad-shaped", CGSize(width: 1286, height: 791), true),
            ("window, wide", CGSize(width: 1400, height: 640), true),
            ("window, tall (half screen beside another app)", CGSize(width: 756, height: 940), true),
            ("full screen 1512x950 (built-in, below the notch)", CGSize(width: 1512, height: 950), false),
            ("full screen 1920x1080", CGSize(width: 1920, height: 1080), false),
        ]
        for (i, (name, size, real)) in shapes.enumerated() {
            if real { app.window.setContentSize(size) } else { container.setFrameSize(size) }
            container.needsLayout = true; container.layoutSubtreeIfNeeded()
            if app.canvas.drawMode { app.exitDrawMode("test") }
            canvas.clearPage()
            canvas.setVisibleForReplay(x: 0, y: canvas.camera.page.height - canvas.camera.page.height / 2, w: canvas.camera.page.width / 2, z: 2)
            canvas.flushInputForTest()
            var s: [String: Any] = ["name": name, "view": [canvas.bounds.width, canvas.bounds.height]]
            let b = container.bounds, f = canvas.frame
            s["gapPt"] = max(abs(f.minX), abs(f.minY), abs(b.width - f.maxX), abs(b.height - f.maxY))
            let pr = canvas.padRect
            s["padRect"] = [pr.minX, pr.minY, pr.width, pr.height]
            s["padRectAspect"] = pr.width / pr.height
            s["padRectCentredErr"] = max(abs(pr.midX - b.width / 2), abs(pr.maxY - b.height))   // centred left-right, at the top
            s["padRectFills"] = abs(pr.width - b.width) < 0.5 || abs(pr.height - b.height) < 0.5
            // Same scale on both axes everywhere in the view (no stretch).
            let rr = canvas.renderRect
            s["unitsPerPtXY"] = [rr.width / canvas.bounds.width, rr.height / canvas.bounds.height]
            // The active area's corners, through the camera and the rectangle the renderer actually drew, vs padRect's corners.
            canvas.draw()
            let drawn = canvas.renderedRect ?? .zero
            func viewOf(_ c: CGPoint) -> CGPoint { CGPoint(x: (c.x - drawn.minX) / drawn.width * canvas.bounds.width, y: (c.y - drawn.minY) / drawn.height * canvas.bounds.height) }
            s["unitsPerPtXY"] = [drawn.width / canvas.bounds.width, drawn.height / canvas.bounds.height]
            var err = 0.0
            for (a, want) in [(CGPoint(x: 0, y: 0), CGPoint(x: pr.minX, y: pr.minY)), (CGPoint(x: 1, y: 1), CGPoint(x: pr.maxX, y: pr.maxY)),
                              (CGPoint(x: 0, y: 1), CGPoint(x: pr.minX, y: pr.maxY)), (CGPoint(x: 1, y: 0), CGPoint(x: pr.maxX, y: pr.minY))] {
                let v = viewOf(canvas.camera.canvas(fromPad: Camera.pad(fromActive: a)))
                err = max(err, hypot(v.x - want.x, v.y - want.y))
            }
            s["cornerErrPt"] = err
            // Draw mode: outline at padRect; real strokes from the active area's corners start at padRect's corners.
            app.enterDrawMode(lock: false)
            canvas.draw()
            s["outlineInDrawMode"] = canvas.outlineDrawn.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []
            var ink: [[Double]] = []
            for (cx, cy, dx) in [(gx + 0.01, gy + 0.01, 1.0), (pad.width - gx - 0.01, pad.height - gy - 0.01, -1.0)] {
                for k in 0...15 { frame([(1, cx + dx * Double(k) * 0.3, cy)]) }; lift()
                canvas.flushInputForTest()
                canvas.draw()
                if let st = canvas.doc.strokes.last, let dr = canvas.renderedRect {
                    let p = st.points.first!.p
                    ink.append([(p.x - dr.minX) / dr.width * canvas.bounds.width, (p.y - dr.minY) / dr.height * canvas.bounds.height])
                }
            }
            s["inkStarts"] = ink
            // Edge guard: a stroke starting in the band draws nothing.
            let n0 = canvas.doc.strokes.count
            for k in 0...15 { frame([(2, gx * 0.4, 30 + Double(k) * 0.3)]) }; lift(); canvas.flushInputForTest()
            s["bandStrokeInk"] = canvas.doc.strokes.count - n0
            // Two-finger pan by 8 mm right and 5 mm up: the page follows the fingers by the same amount on both axes.
            canvas.setVisibleForReplay(x: canvas.camera.page.width * 0.25, y: canvas.camera.page.height - canvas.camera.page.height / 2 - 200, w: canvas.camera.page.width / 2, z: 2)
            let c0 = canvas.camera.center
            for k in 0...20 { let d = Double(k) / 20; frame([(3, 50 + 8 * d, 30 + 5 * d), (4, 70 + 8 * d, 30 + 5 * d)]) }; lift(); canvas.flushInputForTest()
            let c1 = canvas.camera.center, v = canvas.camera.visible
            let perMMx = v.width / (pad.width * (1 - 2 * g)), perMMy = v.height / (pad.height * (1 - 2 * g))
            s["pan"] = ["dx": c0.x - c1.x, "wantDx": 8 * perMMx, "dy": c0.y - c1.y, "wantDy": 5 * perMMy]
            // Pinch: zooms when unlocked, not when locked.
            func pinch() { for k in 0...20 { let d = 10 + Double(k); frame([(5, 60 - d, 35), (6, 60 + d, 35)]) }; lift(); canvas.flushInputForTest() }
            var tl = canvas.tools; tl.zoomLocked = true; canvas.tools = tl
            let z0 = canvas.camera.zoom; pinch(); let zl = canvas.camera.zoom
            tl.zoomLocked = false; canvas.tools = tl
            pinch(); let zu = canvas.camera.zoom
            s["zoom"] = ["before": z0, "locked": zl, "unlocked": zu]
            app.exitDrawMode("test"); canvas.draw()
            s["outlineOutsideDrawMode"] = canvas.outlineDrawn != nil
            if real {
                canvas.clearPage(); canvas.draw()
                s["screenshot"] = waitForShot(i, name) ? "shot-\(i).png" : "timeout"
            }
            scenarios.append(s)
        }
        r["scenarios"] = scenarios
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-mapping.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
