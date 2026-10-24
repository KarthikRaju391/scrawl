// --test-input fallback|stall|welcome (background). checks/input.sh drives it.
//   fallback: launched with --input-nstouch: MultitouchSupport is never loaded; strokes go through the
//             public-touch path (NSTouch samples -> Contact) and come out with speed-based width.
//   stall   : MT "running" but sending nothing while NSTouch sees a finger: the app switches to NSTouch
//             mid-stroke and keeps drawing, and the help window explains it.
//   welcome : the first-run window's text, plus a snapshot of it.
import AppKit

enum TestInput {
    static func run(_ mode: String, app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        var r: [String: Any] = ["mode": mode, "usingMTAtStart": canvas.usingMT, "multitouchStarted": !Multitouch.pads.isEmpty]
        var tAbs = CACurrentMediaTime()
        /// A finger moving across the pad as NSTouch samples, 8 ms apart on a virtual clock.
        func stroke(y: Double, x0: Double, speedUp: Bool) {
            let n = 70
            var x = x0
            for k in 0...n {
                x += speedUp ? 0.002 + 0.0003 * Double(k) : 0.004
                let s = CanvasView.NSTouchSample(key: 99, norm: CGPoint(x: x, y: y), deviceSize: CGSize(width: 453.5, height: 283.5), resting: false)
                tAbs += 0.008
                canvas.touchSamples([s], timestamp: tAbs, now: tAbs)
            }
            tAbs += 0.008; canvas.touchSamples([], timestamp: tAbs, now: tAbs)
        }
        func save() {
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-input.json"))
            try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
        }
        switch mode {
        case "fallback", "stall":
            app.enterDrawMode(lock: false)
            var t = canvas.tools; t.aimFirst = true; canvas.tools = t   // aim-first needs pressure: must be off here
            canvas.lastMTFrameAt = 0
            stroke(y: 0.7, x0: 0.1, speedUp: true)
            stroke(y: 0.5, x0: 0.1, speedUp: false)
            stroke(y: 0.3, x0: 0.1, speedUp: true)
            canvas.flushInputForTest()
            let strokes = canvas.doc.strokes
            r["strokes"] = strokes.count
            r["usingMTAfter"] = canvas.usingMT
            r["inputStalled"] = canvas.inputStalled
            r["aimActive"] = canvas.aimActive
            r["inkStartsAtTouchMM"] = strokes.first.map { s -> [Double] in let p = canvas.padPoint(s.points.first!.p); return [p.x * Multitouch.padMM.width, p.y * Multitouch.padMM.height] } ?? []
            r["pressures"] = strokes.map { s in s.points.map(\.pressure) }.map { [$0.min() ?? 0, $0.max() ?? 0] }
            r["banner"] = app.container.hint.stringValue
            r["infoWindowWhileDrawing"] = app.infoWindow != nil
            app.exitDrawMode("test")
            if let w = app.infoWindow { r["infoWindow"] = w.texts }
            try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/page.png"), pxPerUnit: 1)
            save()
        default:   // welcome
            for (name, status) in [("full", InputStatus.full("built-in trackpad 160 × 115 mm")), ("stalled", .stalled), ("basic", .basic("turned off (basic touch input chosen)")), ("none", .noTrackpad)] {
                let w = InfoWindow(status: status, firstRun: name == "full")
                r[name] = w.texts
                w.window?.appearance = NSAppearance(named: .aqua)
                if let v = w.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.wantsLayer = true; v.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor   // the window's background
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/welcome-\(name).png"))
                }
            }
            r["shownOnFirstRun"] = UserDefaults.standard.bool(forKey: "welcomed")
            save()
        }
    }
}
