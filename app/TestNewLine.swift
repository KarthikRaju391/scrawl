// --test-newline: after an automatic new line, the view is back at the start of the line (the page's
// left margin, 5% in from the writing area's left edge) and one line down. Every auto-pan mode, every
// line width, zoom 2/3/5, zoom lock off/on, and two starts: from the page's left, and after a manual pan
// to the right (as in Karthik's recordings). Strokes go through the real input path; the 400 ms hold
// runs on a virtual clock. checks/newline.sh reads test-newline.json.
import AppKit

enum TestNewLine {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir, pad = Multitouch.padMM
        var vt = 1000.0, sensorT = 0.0
        canvas.now = { vt }
        app.enterDrawMode(lock: false)
        if !canvas.writingMode { app.toggleWriting() }
        func frame(_ mm: CGPoint?) {
            sensorT += 0.008; vt += 0.008
            let cs = mm.map { [Contact(id: 7, state: 4, norm: CGPoint(x: $0.x / pad.width, y: $0.y / pad.height), mm: $0, pressure: 30, size: 0.5, major: 7.5)] } ?? []
            canvas.handle(cs, arrival: vt, sensorT: sensorT)
        }
        /// Page point -> pad mm under the current view (the writer aims at the page).
        func padMM(_ p: CGPoint) -> CGPoint { let n = canvas.padPoint(p); return CGPoint(x: n.x * pad.width, y: n.y * pad.height) }
        /// One letter (a small zigzag, `w` page units wide) with its left edge at page x, baseline y.
        func letter(x: Double, y: Double, w: Double) {
            for k in 0...12 {
                let t = Double(k) / 12
                frame(padMM(CGPoint(x: x + w * t, y: y + w * (k % 2 == 0 ? 0 : 0.9))))
            }
            for _ in 0..<3 { frame(nil) }
        }
        func wait(_ s: Double) {   // finger up for s seconds: the clock runs, pending moves fire
            var left = s
            while left > 0 { vt += 0.008; left -= 0.008; canvas.advanceClock() }
            canvas.flushInputForTest()
        }
        var results: [[String: Any]] = []
        for autoPan in [AutoPan.off, .centre, .left] {
            for lw in 0..<3 {
                for zoom in [2.0, 3.0, 5.0] {
                    for locked in [false, true] {
                        for start in ["page left", "after a manual pan right"] {
                            canvas.clearPage()
                            var t = canvas.tools; t.autoPan = autoPan; t.lineWidthIndex = lw; t.zoomLocked = locked; canvas.tools = t
                            let w = canvas.camera.page.width / zoom
                            let x0 = start == "page left" ? 0 : canvas.camera.page.width * 0.4
                            canvas.setVisibleForReplay(x: x0, y: canvas.camera.page.height - canvas.camera.page.height / zoom, w: w, z: zoom)
                            canvas.flushInputForTest()
                            let lines0 = canvas.newLineCount
                            let v0 = canvas.camera.visible
                            // Write words left to right from the writing area's left until a new line happens.
                            let lw_ = w * 0.035, y = v0.midY
                            var x = v0.minX + v0.width * 0.08, n = 0
                            while canvas.newLineCount == lines0 && n < 400 {
                                // Near the right of the writing area with no auto-pan: pan by hand (two fingers), like a person.
                                let v = canvas.camera.visible
                                if x + lw_ * 3 > v.maxX - v.width * 0.05 {
                                    canvas.setVisibleForReplay(x: min(v.minX + v.width * 0.5, canvas.camera.page.width - v.width), y: v.minY, w: v.width, z: canvas.camera.zoom)
                                }
                                letter(x: x, y: y, w: lw_); n += 1
                                x += lw_ * 1.25
                                if n % 4 == 0 { x += lw_ * 1.5; wait(0.7) } else { wait(0.12) }
                            }
                            wait(0.7)
                            let v = canvas.camera.visible
                            let margin = WritingLayout().margin * canvas.camera.page.width
                            let want = max(margin - v.width * 0.05, 0)
                            results.append(["autoPan": ["off", "centre", "left"][autoPan.rawValue], "lineWidth": ["½", "¾", "full"][lw], "zoom": zoom,
                                            "locked": locked, "start": start, "letters": n, "strokes": canvas.doc.strokes.count, "newLines": canvas.newLineCount - lines0,
                                            "viewMinX": v.minX, "wantMinX": want, "zoomAfter": canvas.camera.zoom,
                                            "movedDown": v0.midY - v.midY, "lineHeightApprox": lw_ * 0.9])
                        }
                    }
                }
            }
        }
        // A palm resting on the pad's edge through the pause must neither cancel nor hold back the new line.
        var palmCase: [String: Any] = [:]
        do {
            canvas.clearPage()
            var t = canvas.tools; t.autoPan = .off; t.lineWidthIndex = 0; t.zoomLocked = false; canvas.tools = t
            // At the page's right end: a stroke past 70% of the view calls for a new line.
            canvas.setVisibleForReplay(x: canvas.camera.page.width * 2 / 3, y: canvas.camera.page.height - canvas.camera.page.height / 3, w: canvas.camera.page.width / 3, z: 3)
            let v0 = canvas.camera.visible, lines0 = canvas.newLineCount
            let lw_ = v0.width * 0.035
            var x = v0.minX + v0.width * 0.55
            while x < v0.minX + v0.width * 0.8 && canvas.newLineCount == lines0 {   // write to the ½-page line end, one quick word after another
                letter(x: x, y: v0.midY, w: lw_); x += lw_ * 1.25; wait(0.12)
            }
            // The line end was reached; now the palm lands on the right edge band and rests there for a second.
            let palm = CGPoint(x: pad.width - 1.5, y: 30)
            for _ in 0..<125 {
                sensorT += 0.008; vt += 0.008
                canvas.handle([Contact(id: 50, state: 4, norm: CGPoint(x: palm.x / pad.width, y: palm.y / pad.height), mm: palm, pressure: 40, size: 1.2, major: 12)], arrival: vt, sensorT: sensorT)
                canvas.advanceClock()
            }
            canvas.flushInputForTest()
            let v = canvas.camera.visible
            palmCase = ["newLines": canvas.newLineCount - lines0, "viewMinX": v.minX,
                        "wantMinX": max(WritingLayout().margin * canvas.camera.page.width - v.width * 0.05, 0), "movedDown": v0.midY - v.midY]
            for _ in 0..<3 { frame(nil) }
        }
        // Return: a new line by hand, same rule.
        canvas.clearPage()
        var t = canvas.tools; t.autoPan = .centre; t.lineWidthIndex = 1; t.zoomLocked = false; canvas.tools = t
        canvas.setVisibleForReplay(x: canvas.camera.page.width * 0.3, y: canvas.camera.page.height - canvas.camera.page.height / 3, w: canvas.camera.page.width / 3, z: 3)
        let v0 = canvas.camera.visible
        for k in 0..<3 { letter(x: v0.minX + v0.width * (0.3 + Double(k) * 0.05), y: v0.midY, w: v0.width * 0.035); wait(0.12) }
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { _ = app.key(e) }
        wait(0.7)
        let vr = canvas.camera.visible
        let r: [String: Any] = ["cases": results, "palmOnEdgeDuringPause": palmCase,
                                "returnKey": ["viewMinX": vr.minX, "wantMinX": max(WritingLayout().margin * canvas.camera.page.width - vr.width * 0.05, 0),
                                              "movedDown": v0.midY - vr.midY]]
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-newline.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
