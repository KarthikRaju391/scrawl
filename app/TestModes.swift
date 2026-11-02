// --test-modes: every mode / tool input from every state, against one rule set (the state x input matrix).
//   D, W, L/Z (and their toolbar buttons and menu items) toggle draw mode, writing mode, zoom lock.
//   A tool (P M H E, or its toolbar button): if it's the active tool, it turns off (M H E -> pen, P -> the last
//   other tool), draw mode unchanged; otherwise it becomes active, and from outside draw mode draw mode turns on.
//   A toggle never opens a panel; the toolbar shows the result. A secondary click opens a button's panel.
// checks/modes.sh reads test-modes.json.
import AppKit

enum TestModes {
    struct S: Equatable { var draw: Bool; var writing: Bool; var tool: ToolKind; var locked: Bool }

    static func run(app: AppDelegate) {
        let canvas = app.canvas, tb = app.container.toolbar, dir = AppPaths.dataDir
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func click(_ item: ToolbarView.Item, secondary: Bool = false, control: Bool = false, chevron: Bool = false) {
            guard let p = chevron ? tb.chevron(of: item) : tb.center(of: item) else { return }
            let types: [NSEvent.EventType] = secondary ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            for t in types {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: control ? [.control] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }
            }
        }
        func menu(_ selName: String) -> Bool {
            let sel = NSSelectorFromString(selName)
            for top in NSApp.mainMenu?.items ?? [] {
                for i in top.submenu?.items ?? [] where i.action == sel { NSApp.sendAction(sel, to: i.target, from: i); return true }
            }
            return false
        }
        func set(_ s: S) {
            if canvas.drawMode != s.draw { if s.draw { app.enterDrawMode(lock: false) } else { app.exitDrawMode("test") } }
            if canvas.writingMode != s.writing { app.toggleWriting() }
            app.noteTool(.marker)                                          // last other tool: marker (or the tool itself)
            var t = canvas.tools; t.tool = s.tool; t.zoomLocked = s.locked; canvas.tools = t; tb.state = t
            app.noteTool(s.tool)
            tb.hidePanel()
        }
        func now() -> S { S(draw: canvas.drawMode, writing: canvas.writingMode, tool: canvas.tools.tool, locked: canvas.tools.zoomLocked) }
        func expect(_ s: S, _ input: String) -> S {
            var e = s
            func tool(_ k: ToolKind) {
                if s.tool == k { e.tool = k == .pen ? (s.tool == .pen ? .marker : .pen) : .pen }   // last other = marker
                else { e.tool = k; if !s.draw { e.draw = true } }
            }
            switch input {
            case "key D", "button draw", "menu draw": e.draw.toggle()
            case "key W", "button writing", "menu writing": e.writing.toggle()
            case "key L", "key Z", "button zoomLock", "menu zoomLock": e.locked.toggle()
            case "key P", "button pen", "menu pen": tool(.pen)
            case "key M", "button marker", "menu marker": tool(.marker)
            case "key H", "button highlighter", "menu highlighter": tool(.highlighter)
            case "key E", "button eraser", "menu eraser": tool(.eraser)
            case "key S", "button select", "menu select": tool(.select)
            default: break
            }
            return e
        }
        let keys: [(String, String, UInt16)] = [("key D", "d", 2), ("key W", "w", 13), ("key L", "l", 37), ("key Z", "z", 6),
                                                ("key P", "p", 35), ("key M", "m", 46), ("key H", "h", 4), ("key E", "e", 14), ("key S", "s", 1)]
        let buttons: [(String, ToolbarView.Item)] = [("button draw", .draw), ("button writing", .writing), ("button zoomLock", .zoomLock),
                                                     ("button pen", .tool(.pen)), ("button marker", .tool(.marker)), ("button highlighter", .tool(.highlighter)),
                                                     ("button eraser", .tool(.eraser)), ("button select", .tool(.select))]
        let menus: [(String, String)] = [("menu draw", "toggleDrawModeAction"), ("menu writing", "toggleWritingAction"), ("menu zoomLock", "toggleZoomLockAction"),
                                         ("menu pen", "penAction"), ("menu marker", "markerAction"), ("menu highlighter", "highlighterAction"), ("menu eraser", "eraserAction"), ("menu select", "selectAction")]
        var failures: [[String: Any]] = [], cases = 0
        var missingMenus = Set<String>()
        for draw in [false, true] { for writing in [false, true] { for tool in [ToolKind.pen, .marker, .highlighter, .eraser, .select] { for locked in [false, true] {
            let s = S(draw: draw, writing: writing, tool: tool, locked: locked)
            var inputs: [(String, () -> Void)] = keys.map { k in (k.0, { key(k.1, k.2) }) }
            if !draw { inputs += buttons.map { b in (b.0, { click(b.1) }) } }   // the toolbar is hidden in draw mode
            inputs += menus.map { m in (m.0, { if !menu(m.1) { missingMenus.insert(m.0) } }) }
            for (name, act) in inputs {
                set(s); app.container.toast.isHidden = true; act()
                let got = now(), want = expect(s, name)
                let panelOpened = !tb.panel.isHidden
                let shown = tb.state.tool == got.tool && tb.state.zoomLocked == got.locked && tb.writingMode == got.writing && tb.drawMode == got.draw
                // In draw mode the toolbar is hidden: a short note says what changed (tool, writing, zoom lock).
                let wantNote = got.draw && (got.tool != s.tool || got.writing != s.writing || got.locked != s.locked)
                let toast = app.container.toast, noted = !toast.isHidden && !toast.stringValue.isEmpty
                cases += 1
                if got != want || panelOpened || !shown || noted != wantNote {
                    failures.append(["from": "\(s)", "input": name, "want": "\(want)", "got": "\(got)", "panelOpened": panelOpened, "toolbarShowsIt": shown,
                                     "noteWanted": wantNote, "note": noted ? toast.stringValue : ""])
                }
            }
        }}}}
        // Secondary click opens the panel (writing settings; a tool's sizes) without toggling.
        set(S(draw: false, writing: true, tool: .pen, locked: false)); click(.writing, secondary: true)
        let writingPanel = ["opened": !tb.panel.isHidden && tb.panel.mode == .writing, "stillWriting": canvas.writingMode]
        set(S(draw: false, writing: false, tool: .eraser, locked: false)); click(.tool(.eraser), secondary: true)
        let toolPanel = ["opened": !tb.panel.isHidden && tb.panel.mode == .tool, "stillEraser": canvas.tools.tool == .eraser]
        // Control-click and the chevron do the same; a size picked in another tool's panel changes that tool, not the active one.
        set(S(draw: false, writing: true, tool: .pen, locked: false)); click(.writing, control: true)
        let ctrlWriting = !tb.panel.isHidden && tb.panel.mode == .writing && canvas.writingMode
        set(S(draw: false, writing: false, tool: .pen, locked: false)); click(.tool(.marker), chevron: true)
        let chevMarker = !tb.panel.isHidden && tb.panel.mode == .tool && tb.panel.state.tool == .marker && canvas.tools.tool == .pen && !canvas.drawMode
        let before = canvas.tools.sizeIndex
        if let p = Optional(tb.panel.centerOfSize(4)), let e1 = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e1) }
        let sizeOnMarker = canvas.tools.sizeIndex[.marker] == 4 && canvas.tools.sizeIndex[.pen] == before[.pen] && canvas.tools.tool == .pen
        set(S(draw: false, writing: true, tool: .pen, locked: false)); click(.writing, chevron: true)
        let chevWriting = !tb.panel.isHidden && tb.panel.mode == .writing && canvas.writingMode
        // The menu shows the modes' state with checkmarks.
        func menuState(_ selName: String) -> Bool? {
            let sel = NSSelectorFromString(selName)
            for top in NSApp.mainMenu?.items ?? [] { for i in top.submenu?.items ?? [] where i.action == sel { _ = app.validateMenuItem(i); return i.state == .on } }
            return nil
        }
        set(S(draw: false, writing: true, tool: .highlighter, locked: true))
        let checks = ["draw": menuState("toggleDrawModeAction") == false, "writing": menuState("toggleWritingAction") == true, "zoomLock": menuState("toggleZoomLockAction") == true,
                      "highlighter": menuState("highlighterAction") == true, "pen": menuState("penAction") == false]
        tb.hidePanel()
        // Screenshots of the toolbar: 1 writing + zoom lock + eraser on; 2 a click on the writing button with writing on;
        // 3 E pressed in draw mode (the eraser turned off).
        func spin(_ t: Double) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }
        func shot(_ n: Int) {
            try? "\(n)".write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
            let d = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") && Date() < d { spin(0.03) }
        }
        set(S(draw: false, writing: true, tool: .eraser, locked: true)); spin(0.3); shot(1)
        click(.writing); spin(0.3); shot(2)
        set(S(draw: true, writing: false, tool: .eraser, locked: false)); key("e", 14); spin(0.3); shot(3)
        set(S(draw: false, writing: false, tool: .pen, locked: false))
        let r: [String: Any] = ["cases": cases, "failures": failures, "missingMenus": Array(missingMenus), "writingPanel": writingPanel, "toolPanel": toolPanel,
                                "ctrlWriting": ctrlWriting, "chevMarker": chevMarker, "sizeOnMarker": sizeOnMarker, "chevWriting": chevWriting, "menuChecks": checks]
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-modes.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
