// --test-selectbar: how long after a Select drag ends the Copy / Export… bar is on screen. A pointer drag through the
// canvas's handlers; the time just before mouseUp; then the run loop runs with no other input (no layout forced) while a
// 1 ms timer notes when the bar is shown in the view tree and when Core Animation has committed it (its layer's
// presentation copy: what the window server draws). Writes bar-expected.json (the bar's rect on screen, for an outside
// recorder) and test-selectbar.json. checks/selectbar.sh reads it. Background only; it refuses otherwise.
import AppKit

enum TestSelectBar {
    static func run(app: AppDelegate) {
        let dir = AppPaths.dataDir, c = app.canvas, bar = app.container.selectionBar
        var r: [String: Any] = [:]
        func finish() {
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-selectbar.json"))
            try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
        }
        guard Launch.background else { r["refused"] = "background only"; finish(); return }
        TestCrash.noReports(crashOnly: true)
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func mouse(_ type: NSEvent.EventType, _ viewPt: CGPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: c.convert(viewPt, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type { case .leftMouseDown: c.mouseDown(with: e); case .leftMouseDragged: c.mouseDragged(with: e); default: c.mouseUp(with: e) }
        }
        if c.drawMode { app.exitDrawMode("test") }
        var t = c.tools; t.tool = .select; t.background = 1; c.tools = t; app.container.toolbar.state = t
        c.setVisibleForReplay(x: 150, y: 420, w: 0, z: 2.5)
        app.window.orderFrontRegardless()   // on screen (behind other apps' windows is fine) for an outside recorder
        spin(0.5)
        var runs: [[String: Any]] = []
        for k in 0..<3 {
            c.setSelectionForTest(nil); spin(0.3)
            let W = Double(c.bounds.width), H = Double(c.bounds.height), j = Double(k) * 0.04
            let p0 = CGPoint(x: W * (0.28 + j), y: H * 0.68), p1 = CGPoint(x: W * (0.6 + j), y: H * 0.4)
            mouse(.leftMouseDown, p0)
            for i in 1...10 { let f = Double(i) / 10; mouse(.leftMouseDragged, CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f)) }
            spin(0.1)
            // Where the bar will be (under the box's bottom-right corner), in screen coordinates with a top-left origin.
            let vr = { () -> CGRect in
                let s = c.selection ?? .zero
                let lo = c.viewPoint(fromCanvas: CGPoint(x: s.minX, y: s.minY)), hi = c.viewPoint(fromCanvas: CGPoint(x: s.maxX, y: s.maxY))
                return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
            }()
            let barInView = CGRect(x: vr.maxX - bar.fittingWidth, y: vr.minY - 8 - SelectionBar.height, width: bar.fittingWidth, height: SelectionBar.height)
            let onScreen = app.window.convertToScreen(app.container.convert(barInView, to: nil))
            let top = NSScreen.screens.first?.frame.height ?? onScreen.maxY
            let expected: [String: Any] = ["run": k, "x": onScreen.minX, "y": top - onScreen.maxY, "w": onScreen.width, "h": onScreen.height, "pid": ProcessInfo.processInfo.processIdentifier]
            try? JSONSerialization.data(withJSONObject: expected).write(to: URL(fileURLWithPath: dir + "/bar-expected.json"))
            // An outside recorder (if one runs) says when it has its baseline frames.
            let d = Date().addingTimeInterval(ProcessInfo.processInfo.environment["SELECTBAR_RECORDER"] != nil ? 8 : 0)
            while !FileManager.default.fileExists(atPath: dir + "/recorder-ready-\(k)") && Date() < d { spin(0.02) }
            spin(0.2)
            let hiddenDuringDrag = bar.isHidden
            // Release, then watch: nothing else happens (no layout forced, no other input).
            var shownAt: Double?, committedAt: Double?
            let tUp = CACurrentMediaTime()
            mouse(.leftMouseUp, p1)
            try? JSONSerialization.data(withJSONObject: ["run": k, "tUp": tUp]).write(to: URL(fileURLWithPath: dir + "/released-\(k).json"))   // for a recorder
            let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
                let now = CACurrentMediaTime()
                if shownAt == nil, !bar.isHidden, bar.window != nil { shownAt = now }
                if committedAt == nil, let p = bar.layer?.presentation(), !p.isHidden, p.opacity > 0.9, !bar.isHidden { committedAt = now }
            }
            RunLoop.current.add(timer, forMode: .common)
            spin(1.5)
            timer.invalidate()
            runs.append(["run": k, "tUp": tUp, "hiddenDuringDrag": hiddenDuringDrag,
                         "shownMs": shownAt.map { ($0 - tUp) * 1000 } ?? NSNull(), "committedMs": committedAt.map { ($0 - tUp) * 1000 } ?? NSNull(),
                         "barFrame": [bar.capsuleFrame.minX, bar.capsuleFrame.minY, bar.capsuleFrame.width, bar.capsuleFrame.height], "expected": [barInView.minX, barInView.minY, barInView.width, barInView.height]])
            try? "1".write(toFile: dir + "/watched-\(k)", atomically: true, encoding: .utf8)
            spin(0.3)
        }
        r["runs"] = runs
        r["refreshHz"] = app.window.screen?.maximumFramesPerSecond ?? 60

        // Placement: never over the box while there's room outside it; inside the usable area; 8 pt away, aligned.
        let b = app.container.bounds, w = bar.fittingWidth
        var placement: [[String: Any]] = []
        for (name, box) in [("room below", CGRect(x: 300, y: 300, width: 300, height: 200)),
                            ("near the bottom", CGRect(x: 300, y: 70, width: 300, height: 200)),
                            ("tall", CGRect(x: 300, y: 40, width: 300, height: b.height - 60)),
                            ("tall at the right edge", CGRect(x: b.width - 320, y: 40, width: 310, height: b.height - 60)),
                            ("near the left edge", CGRect(x: 2, y: 300, width: 60, height: 200)),
                            ("the whole view", CGRect(x: -10, y: -10, width: b.width + 20, height: b.height + 20))] {
            guard let f = AppDelegate.barFrame(box: box, in: b, width: w) else { placement.append(["case": name, "frame": []]); continue }
            let gapUnder = box.minY - f.maxY, gapOver = f.minY - box.maxY, gapRight = f.minX - box.maxX, gapLeft = box.minX - f.maxX
            placement.append(["case": name, "frame": [f.minX, f.minY, f.width, f.height], "overBox": f.intersects(box),
                              "inside": f.minX >= 8 && f.maxX <= b.width - 8 && f.minY >= ToolbarView.height + 10 && f.maxY <= b.height - 34,
                              "gap": [gapUnder, gapOver, gapRight, gapLeft].filter { abs($0 - 8) < 0.01 }.count == 1,
                              "aligned": abs(f.maxX - box.maxX) < 0.01 || abs(f.minY - max(box.minY, ToolbarView.height + 10)) < 0.01 || f.minX == 8 || f.maxX == b.width - 8])
        }
        r["placement"] = placement
        r["barHeight"] = SelectionBar.height
        r["segments"] = [bar.copy.frame.height, bar.export.frame.height]

        // The look, with screenshots: ink nearby on grid, dots and ruled paper; after Copy; flipped above near the bottom;
        // with the system in dark mode (the app draws its page and chrome light either way).
        func photo(_ name: String) {
            c.setNeedsRender(); spin(0.3)
            FileManager.default.createFile(atPath: dir + "/shot-\(name).req", contents: nil)
            let d = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(name).done") && Date() < d { spin(0.1) }
        }
        func wave(_ x: Double, _ y: Double) -> [StrokePoint] {
            (0..<110).map { StrokePoint(p: CGPoint(x: x + Double($0) * 8, y: y + sin(Double($0) / 5) * 26), pressure: 0.3 + 0.4 * abs(sin(Double($0) / 7))) }
        }
        for k in 0..<6 { c.testAddStroke(wave(120, 900 - Double(k) * 95)) }
        c.testAddStroke(wave(220, 620), tool: .highlighter, color: SIMD4(0xFD / 255, 0xD6 / 255, 0x63 / 255, 0.35), sizePt: 24)
        let W = Double(c.bounds.width), H = Double(c.bounds.height)
        func drag(_ a: CGPoint, _ z: CGPoint) {
            mouse(.leftMouseDown, a); for i in 1...6 { let f = Double(i) / 6; mouse(.leftMouseDragged, CGPoint(x: a.x + (z.x - a.x) * f, y: a.y + (z.y - a.y) * f)) }; mouse(.leftMouseUp, z); spin(0.15)
        }
        var looks: [[String: Any]] = []
        for (paper, name) in [(1, "grid"), (2, "dots"), (3, "ruled")] {
            var tt = c.tools; tt.background = paper; c.tools = tt; app.container.toolbar.state = tt
            drag(CGPoint(x: W * 0.3, y: H * 0.72), CGPoint(x: W * 0.62, y: H * 0.42))
            looks.append(["paper": name, "shown": !bar.isHidden, "copy": bar.copy.title])
            photo("bar-\(name)")
        }
        app.copySelectionAction(); spin(0.05)
        r["afterCopy"] = ["copy": bar.copy.title, "toast": app.container.toast.isHidden ? "" : app.container.toast.stringValue]
        photo("bar-copied")
        spin(1.4)
        r["afterCopyLater"] = bar.copy.title
        drag(CGPoint(x: W * 0.3, y: H * 0.35), CGPoint(x: W * 0.6, y: H * 0.1))   // near the bottom: the bar goes over the box
        let s = c.selection ?? .zero
        let lo = c.viewPoint(fromCanvas: CGPoint(x: s.minX, y: s.minY)), hi = c.viewPoint(fromCanvas: CGPoint(x: s.maxX, y: s.maxY))
        let vbox = CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        r["flipped"] = ["over": bar.capsuleFrame.minY >= vbox.maxY + 7.9, "overBox": bar.capsuleFrame.intersects(vbox), "shown": !bar.isHidden]
        photo("bar-flipped-above")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        drag(CGPoint(x: W * 0.3, y: H * 0.72), CGPoint(x: W * 0.62, y: H * 0.42))
        r["dark"] = ["barAppearance": bar.effectiveAppearance.name.rawValue, "shown": !bar.isHidden]
        photo("bar-dark-mode")
        NSApp.appearance = nil
        r["looks"] = looks
        finish()
    }
}
