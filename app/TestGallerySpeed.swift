// --test-gallery-speed: click (or G) to the first frame of the transition, with the 41-page notebook.
// Pages 3 and 5 are full (400 handwriting-sized strokes each). Five tile clicks (a real mouse-down) and
// five G presses back; records input -> transition start and input -> first animation frame.
import AppKit

enum TestGallerySpeed {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        if canvas.drawMode { app.exitDrawMode("test") }
        canvas.clearPage()
        for k in 0..<41 {
            if k > 0 { canvas.newPage() }
            let n = (k == 2 || k == 4) ? 400 : 20
            for j in 0..<n {
                let x0 = 60 + Double(j % 20) * 75, y0 = 940 - Double(j / 20) * 45
                canvas.testAddStroke((0..<40).map { StrokePoint(p: CGPoint(x: x0 + Double($0) * 1.6, y: y0 + sin(Double($0) / 3) * 10), pressure: 0.6) })
            }
        }
        canvas.goToPage(2)
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func click(cell i: Int) {
            guard let g = app.gallery else { return }
            let rc = g.cellRect(i, in: app.container)
            let p = app.container.convert(CGPoint(x: rc.midX, y: rc.midY), to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }
            }
        }
        var opens: [[String: Any]] = [], closes: [[String: Any]] = []
        for k in 0..<5 {
            key("g", 5); let c = app.lastTransition; waitTransition()
            closes.append(["stepsMs": c["stepsMs"] ?? [:], "inputToStartMs": c["inputToStartMs"] ?? -1, "inputToFirstFrameMs": app.lastTransition["inputToFirstFrameMs"] ?? -1,
                           "durationS": app.lastTransition["durationS"] ?? -1, "firstFrameProgress": app.lastTransition["firstFrameProgress"] ?? -1,
                           "totalMs": app.lastTransition["totalMs"] ?? -1, "maxFrameGapMs": app.lastTransition["maxFrameGapMs"] ?? -1, "gaps": app.lastTransition["gapsMs"] ?? []])
            spin(0.1)
            click(cell: k % 2 == 0 ? 4 : 2); let o = app.lastTransition; waitTransition()
            opens.append(["inputToStartMs": o["inputToStartMs"] ?? -1, "inputToFirstFrameMs": app.lastTransition["inputToFirstFrameMs"] ?? -1,
                          "durationS": app.lastTransition["durationS"] ?? -1, "firstFrameProgress": app.lastTransition["firstFrameProgress"] ?? -1,
                          "totalMs": app.lastTransition["totalMs"] ?? -1, "maxFrameGapMs": app.lastTransition["maxFrameGapMs"] ?? -1, "page": canvas.pageIndex, "endFrame": app.lastTransition["endFrame"] ?? [], "canvas": [canvas.frame.minX, canvas.frame.minY, canvas.frame.width, canvas.frame.height]])
            spin(0.1)
        }
        // How long the full-size render of a full page takes (what the old code did before animating).
        let t0 = CACurrentMediaTime(); _ = app.viewImage(of: 2); let renderMs = (CACurrentMediaTime() - t0) * 1000
        try? JSONSerialization.data(withJSONObject: ["opens": opens, "closes": closes, "fullPageRenderMs": renderMs], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: dir + "/test-gallery-speed.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
