// --test-pan: horizontal page moves in every shape (wide and tall windows, full-screen sizes):
//  - two-finger pan right then left in draw mode (zoom lock off and on): the view follows the fingers;
//  - scroll right then left outside draw mode;
//  - after panning right by hand, writing there keeps the view where the user put it (no new line
//    pulling it back to the left margin at the first pause);
//  - writing-mode auto-pan along the line still moves right, and a full line still returns to the margin.
// Real input path; the 400 ms hold runs on a virtual clock. checks/pan.sh reads test-pan.json.
import AppKit

enum TestPan {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, container = app.container!, dir = AppPaths.dataDir, pad = Multitouch.padMM
        var vt = 5000.0, sensorT = 0.0
        canvas.now = { vt }
        func frame(_ cs: [(Int32, Double, Double)]) {
            sensorT += 0.008; vt += 0.008
            canvas.handle(cs.map { Contact(id: $0.0, state: 4, norm: CGPoint(x: $0.1 / pad.width, y: $0.2 / pad.height), mm: CGPoint(x: $0.1, y: $0.2),
                                           pressure: 30, size: 0.5, major: 7.5) }, arrival: vt, sensorT: sensorT)
        }
        func lift() { for _ in 0..<4 { frame([]) } }
        func wait(_ s: Double) { var l = s; while l > 0 { vt += 0.008; l -= 0.008; canvas.advanceClock() }; canvas.flushInputForTest() }
        func padMM(_ p: CGPoint) -> CGPoint { let n = canvas.padPoint(p); return CGPoint(x: n.x * pad.width, y: n.y * pad.height) }
        func letter(x: Double, y: Double, w: Double) {
            for k in 0...12 { let t = Double(k) / 12; let m = padMM(CGPoint(x: x + w * t, y: y + w * (k % 2 == 0 ? 0 : 0.9))); frame([(9, m.x, m.y)]) }
            lift()
        }
        /// Two fingers moving `dx` mm (positive = right) across the pad.
        func twoFingerPan(_ dx: Double) {
            let x0 = dx > 0 ? 40.0 : 70.0
            for k in 0...24 { let d = dx * Double(k) / 24; frame([(1, x0 + d, 35), (2, x0 + 15 + d, 35)]) }
            lift(); canvas.flushInputForTest()
        }
        func scroll(_ dx: Int32) {
            for _ in 0..<10 {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0), let e = NSEvent(cgEvent: cg) { canvas.scrollWheel(with: e) }
            }
        }
        var out: [[String: Any]] = []
        let shapes: [(String, CGSize, Bool)] = [("window, wide", CGSize(width: 1400, height: 640), true),
                                                ("window, tall (half screen)", CGSize(width: 756, height: 940), true),
                                                ("full screen 1512x950", CGSize(width: 1512, height: 950), false),
                                                ("full screen 1920x1080", CGSize(width: 1920, height: 1080), false)]
        for (name, size, real) in shapes {
            if real { app.window.setContentSize(size) } else { container.setFrameSize(size) }
            container.needsLayout = true; container.layoutSubtreeIfNeeded()
            for locked in [false, true] {
                var s: [String: Any] = ["shape": name, "locked": locked]
                if canvas.drawMode { app.exitDrawMode("test") }
                canvas.clearPage()
                var t = canvas.tools; t.zoomLocked = locked; t.lineWidthIndex = 0; canvas.tools = t
                if !canvas.writingMode { app.toggleWriting() }
                let pw = canvas.camera.page.width
                canvas.setVisibleForReplay(x: pw * 0.25, y: canvas.camera.page.height - canvas.camera.page.height / 2, w: pw / 2, z: 2)
                canvas.flushInputForTest()
                // Outside draw mode: scroll right then left (content moves with the fingers: view x goes down, then up).
                let sx0 = canvas.camera.visible.minX
                scroll(30); let sx1 = canvas.camera.visible.minX
                scroll(-30); let sx2 = canvas.camera.visible.minX
                s["scroll"] = ["start": sx0, "afterRight": sx1, "afterLeft": sx2]
                // Draw mode: two-finger pan, both directions.
                app.enterDrawMode(lock: false)
                canvas.setVisibleForReplay(x: pw * 0.25, y: canvas.camera.page.height - canvas.camera.page.height / 2, w: pw / 2, z: 2)
                canvas.flushInputForTest()
                let v = canvas.camera.visible
                let perMM = v.width / (pad.width * (1 - 2 * Camera.margin))
                let p0 = v.minX
                twoFingerPan(-20); let p1 = canvas.camera.visible.minX     // fingers left: view moves right
                twoFingerPan(20); let p2 = canvas.camera.visible.minX      // fingers right: view moves left
                s["twoFinger"] = ["start": p0, "afterFingersLeft": p1, "afterFingersRight": p2,
                                   // 1:1 from the frame that leaves the dead zone (24 steps of 20/24 mm)
                                   "want": (20 - (floor(GestureEngine.deadZoneMM / (20.0 / 24)) + 1) * 20.0 / 24) * perMM, "zoom": canvas.camera.zoom]
                // Karthik's case: start a line at the left, pan right by hand, keep writing there, pause.
                canvas.clearPage()
                canvas.setVisibleForReplay(x: 0, y: canvas.camera.page.height - canvas.camera.page.height / 2, w: pw / 2, z: 2)
                canvas.flushInputForTest()
                let lw = canvas.camera.visible.width * 0.035, y = canvas.camera.visible.midY
                for k in 0..<4 { letter(x: canvas.camera.visible.minX + canvas.camera.visible.width * (0.1 + Double(k) * 0.05), y: y, w: lw); wait(0.12) }
                wait(0.7)
                twoFingerPan(-40); twoFingerPan(-30)   // pan right by hand, well past the ½-page line (as in Karthik's session)
                let afterPan = canvas.camera.visible.minX, lines0 = canvas.newLineCount
                let vv = canvas.camera.visible
                for k in 0..<6 { letter(x: vv.minX + vv.width * (0.3 + Double(k) * 0.05), y: y, w: lw); wait(0.12) }
                wait(0.7)
                s["writeAfterPanRight"] = ["afterPan": afterPan, "afterWritingAndPause": canvas.camera.visible.minX, "newLines": canvas.newLineCount - lines0]
                // Writing along the line never pans sideways (Karthik, 28 Oct). Zoomed in, the line goes on by panning
                // right by hand (the ½-page guide line is past the view's right edge here); once the ink crosses it,
                // the next line comes and the view goes back to the block's start (30 Oct rules: no look-ahead).
                canvas.clearPage()
                canvas.setVisibleForReplay(x: 0, y: canvas.camera.page.height - canvas.camera.page.height / 2, w: pw / 2, z: 2)
                canvas.flushInputForTest()
                let nl0 = canvas.newLineCount, x0 = canvas.camera.visible.minX
                var x = canvas.camera.visible.minX + canvas.camera.visible.width * 0.1, n = 0, handPans = 0, autoMoves: [Double] = []
                while canvas.newLineCount == nl0 && n < 200 {
                    let v0 = canvas.camera.visible.minX
                    letter(x: x, y: y, w: lw); n += 1; x += lw * 1.25
                    if n % 4 == 0 { x += lw * 1.5; wait(0.7) } else { wait(0.12) }
                    let moved = canvas.camera.visible.minX - v0
                    if canvas.newLineCount == nl0 && abs(moved) > 0.5 { autoMoves.append(moved) }   // a move nobody asked for
                    if canvas.newLineCount == nl0 && x + lw * 3 > canvas.camera.visible.maxX - canvas.camera.visible.width * 0.08 {
                        twoFingerPan(-30); handPans += 1   // near the view's edge: pan right by hand
                    }
                }
                wait(0.7)
                s["alongLine"] = ["startX": x0, "handPans": handPans, "autoMoves": autoMoves, "newLines": canvas.newLineCount - nl0,
                                "viewXAfterNewLine": canvas.camera.visible.minX, "wantAfterNewLine": max((canvas.doc.strokes.first.map { Double($0.bounds.minX) } ?? 0) - canvas.camera.visible.width * 0.05, 0)]   // back to the block's start
                out.append(s)
            }
        }
        try? JSONSerialization.data(withJSONObject: ["cases": out], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-pan.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
