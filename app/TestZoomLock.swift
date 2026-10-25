// --test-zoomlock: drives the real app through every path that could change the zoom or the lock,
// with the lock on, and records the lock state and zoom after each step. Clicks go through
// window.sendEvent (AppKit hit-testing), keys through the app's key handler, touches through
// Multitouch.onFrame. Writes <data>/test-zoomlock.json.
import AppKit
import QuartzCore

extension AppDelegate {
    func runZoomLockTest(dir: String) {
        let pad = Multitouch.padMM
        var log: [[String: Any]] = []
        var steps: [(String, () -> Void)] = []
        var id: Int32 = 7000
        var sensorT = 0.0
        func frames(_ fs: [[Contact]]) {   // pushed like the driver, then processed
            for f in fs { sensorT += 0.008; Multitouch.onFrame?(f, CACurrentMediaTime(), sensorT) }
            canvas.flushInputForTest()
        }
        func c(_ i: Int32, _ x: Double, _ y: Double) -> Contact {
            Contact(id: i, state: 4, norm: CGPoint(x: x, y: y), mm: CGPoint(x: x * pad.width, y: y * pad.height), pressure: 25, size: 0.5, major: 7.5)
        }
        func pinch(spread: Bool) {   // two fingers moving apart (or together) for 0.3 s
            id += 2
            frames((0..<36).map { k in let d = 0.10 + (spread ? 1 : -1) * Double(k) * 0.003
                return [c(id, 0.5 - d, 0.5), c(id + 1, 0.5 + d, 0.5)] } + [[]])
        }
        func pan() { id += 2; frames((0..<30).map { k in [c(id, 0.4 - Double(k) * 0.004, 0.5), c(id + 1, 0.6 - Double(k) * 0.004, 0.5)] } + [[]]) }
        func stroke(from x0: Double, to x1: Double, y: Double = 0.5) {
            id += 1
            frames((0...30).map { k in [c(id, x0 + (x1 - x0) * Double(k) / 30, y + 0.02 * sin(Double(k) / 3))] } + [[]])
        }
        func key(_ ch: String, code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: code) { _ = self.key(e) }
        }
        func click(_ p: CGPoint?) {
            guard let p else { return }
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(e) }
            }
        }
        let tb = container.toolbar
        func add(_ name: String, _ body: @escaping () -> Void) { steps.append((name, body)) }

        // Control (unlocked): pinch zooms; each page keeps its own zoom.
        add("control: enter draw mode, zoom 3") {
            // Start from a known state, not the user's saved settings (test mode never saves).
            var t = ToolState(); t.zoomLocked = false; self.canvas.tools = t; self.container.toolbar.state = t
            self.enterDrawMode(lock: false); self.canvas.setZoomForTest(settingsWritingZoom: true)
        }
        add("control: new page, pinch to zoom it") { self.page(0); pinch(spread: true) }
        add("control: back to page 1") { self.page(-1) }
        // Lock, then every path.
        // The toolbar is hidden in draw mode (the pointer is frozen there), so toolbar clicks happen outside it.
        add("LOCK via toolbar button") { self.exitDrawMode(); click(tb.center(of: .zoomLock)); self.enterDrawMode(lock: false) }
        add("pinch out") { pinch(spread: true) }
        add("pinch in") { pinch(spread: false) }
        add("two-finger pan") { pan() }
        add("draw a stroke") { stroke(from: 0.3, to: 0.5) }
        add("tool keys P M H E P, sizes 1 3 5") {
            for (ch, code) in [("p", 35), ("m", 46), ("h", 4), ("e", 14), ("p", 35), ("1", 18), ("3", 20), ("5", 23)] { key(ch, code: UInt16(code)) }
        }
        add("pen panel: colour + size") { self.exitDrawMode(); click(tb.center(of: .tool(.pen))); click(tb.panel.centerOfColor(7)); click(tb.panel.centerOfSize(2)); tb.hidePanel() }
        add("background panel: dot") { click(tb.center(of: .background)); click(tb.panel.centerOfBackground(2)); tb.hidePanel() }
        add("writing on (toolbar), panel: ½ page, Left, Centre") {
            click(tb.center(of: .writing)); click(tb.center(of: .writing))
            click(tb.panel.centerOfWriting(0)); click(tb.panel.centerOfWriting(5)); click(tb.panel.centerOfWriting(4)); tb.hidePanel()
        }
        add("settings panel opened and closed") { click(tb.center(of: .settings)); click(tb.center(of: .settings)) }
        add("writing: strokes to the edge (auto-pan) and past the line width (new line)") {
            self.enterDrawMode(lock: false)
            var x = 0.2
            for _ in 0..<14 { stroke(from: x, to: x + 0.06); x += 0.08; if x > 0.85 { x = 0.45 } }
        }
        add("writing off (W)") { key("w", code: 13) }
        add("new page (N)") { key("n", code: 45) }
        add("previous / next page (toolbar)") { self.exitDrawMode(); click(tb.center(of: .prevPage)); click(tb.center(of: .nextPage)); click(tb.center(of: .prevPage)); self.enterDrawMode(lock: false) }
        add("Cmd-0 zoom to page") { self.resetZoom() }
        add("leave draw mode (Esc), two-finger scroll") {
            key("\u{1b}", code: 53)
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -80, wheel2: -60, wheel3: 0), let e = NSEvent(cgEvent: cg) { self.canvas.scrollWheel(with: e) }
        }
        add("draw a stroke, then undo it") { self.enterDrawMode(lock: false); stroke(from: 0.3, to: 0.6, y: 0.4) }
        add("undo") { self.canvas.undo() }
        add("redo, clear page, undo the clear") { self.canvas.redo(); self.canvas.clearPage(); self.canvas.undo() }
        add("saved state reloads locked") {}
        // Unlock: Z in draw mode, then pinch must zoom again.
        add("UNLOCK via Z key") { self.enterDrawMode(lock: false); key("z", code: 6) }
        add("pinch out (unlocked)") { pinch(spread: true) }
        // Shortcuts: E outside draw mode picks the eraser and enters draw mode; P picks the pen; D leaves and enters.
        add("Esc, then E (outside draw mode)") { key("\u{1b}", code: 53); key("e", code: 14) }
        add("P (outside draw mode)") { key("p", code: 35) }
        add("D enters draw mode") { key("d", code: 2); key("d", code: 2) }   // leaves (E turned it on), then enters
        add("L locks (in draw mode)") { key("l", code: 37) }
        add("L unlocks (outside draw mode)") { key("\u{1b}", code: 53); key("l", code: 37) }

        var i = 0
        var lockedZoom: Double?
        func next() {
            guard i < steps.count else { finish(); return }
            let (name, body) = steps[i]; i += 1
            body()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.canvas.flushInputForTest()
                let z = self.canvas.camera.zoom, locked = self.canvas.tools.zoomLocked
                if name.hasPrefix("LOCK") { lockedZoom = z }
                var row: [String: Any] = ["step": name, "locked": locked, "zoom": (z * 1000).rounded() / 1000, "page": self.canvas.pageIndex + 1,
                                          "toolbarShowsLocked": tb.state.zoomLocked, "tool": self.canvas.tools.tool.rawValue,
                                          "toolbarTool": tb.state.tool.rawValue, "drawMode": self.canvas.drawMode]
                if name == "saved state reloads locked" { row["reloadedLocked"] = ToolState.load().zoomLocked || !self.canvas.testMode }
                if let lz = lockedZoom { row["zoomUnchangedSinceLock"] = abs(z - lz) < 1e-9 }
                log.append(row)
                next()
            }
        }
        func finish() {
            try? JSONSerialization.data(withJSONObject: ["steps": log], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: dir + "/test-zoomlock.json"))
            try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
        }
        next()
    }
}
