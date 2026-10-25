// --test-keys: every single-key mode shortcut toggles. Presses each key twice through the same key
// handler the window uses, and records the mode, tool and the toolbar's copy after every press.
import AppKit

enum TestKeys {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, tb = app.container.toolbar, dir = AppPaths.dataDir
        var steps: [[String: Any]] = []
        func press(_ ch: String, code: UInt16 = 0) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber,
                                        context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                _ = app.key(e)
            }
        }
        func snap(_ label: String) {
            steps.append(["after": label, "draw": canvas.drawMode, "writing": canvas.writingMode, "tool": canvas.tools.tool.rawValue,
                          "zoomLocked": canvas.tools.zoomLocked,
                          "toolbarTool": tb.state.tool.rawValue, "toolbarZoomLocked": tb.state.zoomLocked,
                          "toolbarWriting": tb.writingMode, "toolbarDraw": tb.drawMode])
        }
        var t = canvas.tools; t.tool = .pen; t.zoomLocked = false; canvas.tools = t; tb.state = t
        snap("start")
        for (k, label) in [("p", "P on pen, no other tool used yet"), ("d", "D"), ("d", "D again"), ("w", "W"), ("w", "W again"), ("l", "L"), ("l", "L again"), ("z", "Z"), ("z", "Z again"),
                           ("m", "M"), ("m", "M again"), ("h", "H"), ("h", "H again"), ("e", "E"), ("e", "E again"),
                           ("p", "P on pen (last other tool: eraser)"), ("p", "P again")] {
            press(k); snap(label)
        }
        // P with a tool picked in the toolbar, and P with no other tool ever used (fresh state).
        var s = tb.state; s.tool = .highlighter; tb.onChange?(s); tb.state = s; snap("toolbar: highlighter")
        press("p"); snap("P (from highlighter)"); press("p"); snap("P again (back to highlighter)")
        // Esc still leaves draw mode; D enters it again.
        press("d"); snap("D (enter)"); press("\u{1b}", code: 53); snap("Esc")
        let r: [String: Any] = ["steps": steps]
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-keys.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
