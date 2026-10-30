// --test-page: the page's bounds are obvious. Narrow, wide and screen-sized windows at zoom 1 and zoom 3
// (home), plus zoom 3 at the page's right edge; ruled paper with some ink. For each: a screenshot (requested
// from checks/page.sh via shot-N.req / shot-N.done) and where the page edges are in view points.
import AppKit

enum TestPage {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, container = app.container!, dir = AppPaths.dataDir
        var t = canvas.tools; t.background = 3; t.zoomLocked = false; canvas.tools = t
        canvas.clearPage()
        // Some writing near the top-left and a circle further right, like Karthik's page.
        for row in 0..<4 {
            let y0 = canvas.camera.page.height - 70 - Double(row) * 55
            canvas.testAddStroke((0..<80).map { StrokePoint(p: CGPoint(x: 60 + Double($0) * 7, y: y0 + sin(Double($0) / 2) * 12), pressure: 0.5) })
        }
        canvas.testAddStroke((0...90).map { k in let a = Double(k) / 90 * 2 * .pi; return StrokePoint(p: CGPoint(x: 1250 + cos(a) * 120, y: canvas.camera.page.height - 200 + sin(a) * 120), pressure: 0.5) })
        func waitForShot(_ n: Int) -> Bool {
            try? "\(n)".write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return false
        }
        var shots: [[String: Any]] = []
        var n = 0
        for (name, size) in [("narrow", CGSize(width: 560, height: 900)), ("wide", CGSize(width: 1480, height: 640)), ("screen-sized", CGSize(width: 1512, height: 900))] {
            app.window.setContentSize(size)
            container.needsLayout = true; container.layoutSubtreeIfNeeded()
            for (zname, zoom, atRight) in [("zoom 1", 1.0, false), ("zoom 3", 3.0, false), ("zoom 3, page's right edge", 3.0, true)] {
                let pw = canvas.camera.page.width, w = pw / zoom
                canvas.setVisibleForReplay(x: atRight ? pw - w : 0, y: canvas.camera.page.height - canvas.camera.page.height / zoom, w: w, z: zoom)
                var c = canvas.camera; c.clamp(); canvas.setVisibleForReplay(x: c.visible.minX, y: c.visible.minY, w: c.visible.width, z: c.zoom)
                canvas.draw()
                // Page edges in view points (origin bottom-left).
                let left = canvas.viewPoint(fromCanvas: CGPoint(x: 0, y: 0)).x
                let right = canvas.viewPoint(fromCanvas: CGPoint(x: pw, y: 0)).x
                let top = canvas.viewPoint(fromCanvas: CGPoint(x: 0, y: canvas.camera.page.height)).y
                let ok = waitForShot(n)
                shots.append(["n": n, "name": "\(name), \(zname)", "view": [canvas.bounds.width, canvas.bounds.height],
                              "window": [app.window.frame.width, app.window.frame.height], "pageLeft": left, "pageRight": right, "pageTop": top,
                              "padRect": [canvas.padRect.minX, canvas.padRect.minY, canvas.padRect.width, canvas.padRect.height], "shot": ok])
                n += 1
            }
        }
        // The smallest window allowed: the whole toolbar is inside it.
        app.window.setFrame(CGRect(origin: app.window.frame.origin, size: app.window.minSize), display: true)
        container.needsLayout = true; container.layoutSubtreeIfNeeded()
        let tb = container.toolbar, pill = tb.convert(tb.pillRectForTest, to: container)
        let smallest: [String: Any] = ["window": [app.window.frame.width, app.window.frame.height], "view": [container.bounds.width, container.bounds.height],
                                       "pill": [pill.minX, pill.maxX]]
        try? JSONSerialization.data(withJSONObject: ["shots": shots, "smallest": smallest], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-page.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
