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
                         "barFrame": [bar.frame.minX, bar.frame.minY, bar.frame.width, bar.frame.height], "expected": [barInView.minX, barInView.minY, barInView.width, barInView.height]])
            try? "1".write(toFile: dir + "/watched-\(k)", atomically: true, encoding: .utf8)
            spin(0.3)
        }
        r["runs"] = runs
        r["refreshHz"] = app.window.screen?.maximumFramesPerSecond ?? 60
        finish()
    }
}
