// --test-a11y: what VoiceOver gets from the toolbar (one custom-drawn view): one element per button, with its name,
// role (a checkbox for the buttons that toggle, with its state), help (the tooltip), dimmed when unusable, a frame
// over the button, and a press that does what a click does. checks/a11y.sh reads test-a11y.json.
import AppKit

enum TestAccessibility {
    static func run(app: AppDelegate) {
        let tb = app.container.toolbar, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        if app.canvas.drawMode { app.exitDrawMode("test") }
        app.container.layoutSubtreeIfNeeded(); spin(0.2)
        var r: [String: Any] = ["elements": tb.accessibilityForTest, "window": { let f = app.window.frame; return [f.minX, f.minY, f.width, f.height] }(),
                                "toolbarRole": tb.accessibilityRole()?.rawValue ?? "", "toolbarIsElement": tb.isAccessibilityElement()]
        func index(_ label: String) -> Int { (tb.accessibilityForTest.firstIndex { ($0["label"] as? String) == label }) ?? -1 }
        // Presses, as VoiceOver's VO-Space sends them.
        var presses: [String: Any] = [:]
        presses["prevOnFirstPage"] = tb.accessibilityPressForTest(index("Previous page"))
        _ = tb.accessibilityPressForTest(index("Writing mode")); presses["writingOn"] = app.canvas.writingMode
        presses["writingValue"] = tb.accessibilityForTest[index("Writing mode")]["value"]
        _ = tb.accessibilityPressForTest(index("Writing mode")); presses["writingOffAgain"] = !app.canvas.writingMode
        _ = tb.accessibilityPressForTest(index("New page")); presses["newPage"] = app.canvas.pages.count
        _ = tb.accessibilityPressForTest(index("Eraser")); presses["eraserAndDraw"] = app.canvas.tools.tool == .eraser && app.canvas.drawMode
        presses["childrenInDrawMode"] = tb.accessibilityChildren()?.count ?? -1   // hidden in draw mode: nothing to reach
        app.exitDrawMode("test"); presses["childrenAfter"] = tb.accessibilityChildren()?.count ?? -1
        r["presses"] = presses
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-a11y.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
