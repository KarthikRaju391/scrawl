// --test-tooldraw: picking a tool outside draw mode (key or toolbar) also turns draw mode on, ready to use.
// checks/tooldraw.sh reads test-tooldraw.json.
import AppKit

enum TestToolDraw {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, tb = app.container.toolbar, dir = AppPaths.dataDir, pad = Multitouch.padMM
        var t0 = 0.0
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func click(_ item: ToolbarView.Item) {
            guard let p = tb.center(of: item) else { return }
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }
            }
        }
        func state(_ at: String) -> [String: Any] {
            ["at": at, "draw": canvas.drawMode, "tool": canvas.tools.tool.rawValue, "toolbarTool": tb.state.tool.rawValue, "toolbarDraw": tb.drawMode, "strokes": canvas.doc.strokes.count]
        }
        /// A finger stroke through the input path, across the middle of the pad.
        func swipe() {
            for k in 0...40 {
                t0 += 0.008
                let x = 30 + Double(k) * 1.6, y = 38.0
                canvas.handle([Contact(id: 3, state: 4, norm: CGPoint(x: x / pad.width, y: y / pad.height), mm: CGPoint(x: x, y: y), pressure: 30, size: 0.5, major: 7.5)],
                              arrival: t0 + 1000, sensorT: t0)
            }
            for _ in 0..<5 { t0 += 0.008; canvas.handle([], arrival: t0 + 1000, sensorT: t0) }
            canvas.flushInputForTest()
        }
        var steps: [[String: Any]] = []
        if canvas.drawMode { app.exitDrawMode("test") }
        var t = canvas.tools; t.tool = .pen; canvas.tools = t; tb.state = t
        // Ink under the swipe: a line across the middle of the view, outside draw mode.
        let v = canvas.camera.visible
        canvas.testAddStroke((0...60).map { StrokePoint(p: CGPoint(x: v.minX + v.width * (0.15 + Double($0) * 0.01), y: canvas.camera.canvas(fromPad: CGPoint(x: 0.5, y: 38 / pad.height)).y), pressure: 0.6) })
        steps.append(state("start: pen, outside draw mode, one stroke"))
        key("e", 14); steps.append(state("E outside draw mode"))
        swipe(); steps.append(state("a stroke with the eraser"))
        key("e", 14); steps.append(state("E again (in draw mode)"))
        key("d", 2); steps.append(state("D"))
        for (ch, code, name) in [("m", UInt16(46), "M"), ("h", 4, "H")] {
            key(ch, code); steps.append(state("\(name) outside draw mode"))
            key("\u{1b}", 53); steps.append(state("Esc"))
        }
        // P outside draw mode (the pen is not the current tool after Esc from H? make it marker first).
        var t2 = canvas.tools; t2.tool = .marker; canvas.tools = t2; tb.state = t2
        key("p", 35); steps.append(state("P outside draw mode"))
        key("\u{1b}", 53)
        // Toolbar: clicking a tool that isn't selected, outside draw mode.
        var t3 = canvas.tools; t3.tool = .pen; canvas.tools = t3; tb.state = t3
        click(.tool(.eraser)); steps.append(state("toolbar: eraser clicked outside draw mode"))
        key("\u{1b}", 53); steps.append(state("Esc after the toolbar click"))
        try? JSONSerialization.data(withJSONObject: ["steps": steps], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-tooldraw.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
