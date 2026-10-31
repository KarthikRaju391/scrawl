// --test-toast: every pill label (the Undo / Redo toast, the draw-mode and page-full banners, the page
// label) with short and long text, one screenshot each (shot-N.req / shot-N.done, from checks/toast.sh).
// Records each pill's frame in window points; the script finds the text's pixels inside it.
import AppKit

enum TestToast {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, c = app.container!, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func shot(_ n: Int) {
            try? "\(n)".write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
            let d = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") && Date() < d { spin(0.03) }
        }
        var t = canvas.tools; t.background = 0; canvas.tools = t
        var cases: [[String: Any]] = []
        var n = 0
        func record(_ name: String, _ v: NSView) {
            c.layoutSubtreeIfNeeded(); c.display(); spin(0.15)
            let f = v.convert(v.bounds, to: nil)   // window coordinates (origin bottom-left)
            shot(n)
            cases.append(["n": n, "name": name, "pill": [f.minX, f.minY, f.width, f.height], "window": [app.window.frame.width, app.window.frame.height],
                          "content": [c.bounds.width, c.bounds.height]])
            n += 1
        }
        for text in ["Undo", "Redo", "Nothing to undo"] {
            app.showToast(text); record("toast \"\(text)\"", c.toast)
            c.toast.isHidden = true
        }
        app.enterDrawMode(lock: false); app.updateBanner(); c.banner.alphaValue = 1
        record("draw-mode banner", c.banner)
        app.exitDrawMode("test"); app.updateBanner()
        record("page label (outside draw mode)", c.hint)
        // The page-full banner (orange): ink below the first screen of the page.
        canvas.testAddStroke((0..<20).map { StrokePoint(p: CGPoint(x: 200 + Double($0) * 10, y: canvas.camera.page.height - canvas.screenUnits - 80), pressure: 0.6) })
        app.updateBanner(); c.banner.alphaValue = 1
        record("page-full banner", c.banner)
        // Dark appearance for the whole app: the pills look and sit the same.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        app.showToast("Undo"); record("toast \"Undo\", app in dark appearance", c.toast)
        NSApp.appearance = nil
        // A note shown while the previous one fades out stays up (the old fade's end used to hide it).
        app.showToast("first", seconds: 0.2); spin(0.3)          // its fade-out is running now
        app.showToast("second", seconds: 2.5); spin(0.6)
        let overlap: [String: Any] = ["text": c.toast.stringValue, "hidden": c.toast.isHidden, "alpha": c.toast.alphaValue]
        try? JSONSerialization.data(withJSONObject: ["cases": cases, "overlap": overlap], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-toast.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
