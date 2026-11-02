// --test-select: the Select tool end to end in the real app, in the background, with a dry pointer lock (it refuses to
// run otherwise). S picks it (and draw mode); a one-finger drag through the trackpad path makes the rectangle; the bar
// shows next to it; ⌘C (the menu item) puts PNG, PDF and SVG on the test pasteboard and shows "Copied"; Esc leaves draw
// mode and keeps the selection; a pointer drag replaces it; the bar's Copy and Export… work; Export Selection… opens the
// sheet on Selection and saves the region; Esc, another tool and another page clear it; nothing is an edit.
// checks/select.sh photographs the window when asked (shot-<name>.req) and reads test-select.json.
import AppKit

enum TestSelect {
    static func run(app: AppDelegate) {
        let dir = AppPaths.dataDir, c = app.canvas, pad = Multitouch.padMM
        var r: [String: Any] = [:]
        func finish() {
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-select.json"))
            try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
        }
        guard CursorLock.dry, Launch.background else { r["refused"] = "needs TRACKPAD_DRAW_DRYLOCK and the background"; finish(); return }
        TestCrash.noReports(crashOnly: true)
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func photo(_ name: String) {
            c.setNeedsRender(); app.container.needsLayout = true; spin(0.3)
            FileManager.default.createFile(atPath: dir + "/shot-\(name).req", contents: nil)
            let d = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(name).done") && Date() < d { spin(0.1) }
        }
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func menuItem(_ sel: Selector) -> NSMenuItem? {
            for top in NSApp.mainMenu?.items ?? [] { if let m = top.submenu { m.update(); if let i = m.items.first(where: { $0.action == sel }) { return i } } }
            return nil
        }
        func perform(_ sel: Selector) -> Bool {
            guard let i = menuItem(sel), i.isEnabled, let m = i.menu, let k = m.items.firstIndex(of: i) else { return false }
            m.performActionForItem(at: k); return true
        }
        var t = 0.0, nextId: Int32 = 1
        func frame(_ cs: [(Int32, CGPoint)]) {
            t += 0.008
            c.handle(cs.map { Contact(id: $0.0, state: 4, norm: $0.1, mm: CGPoint(x: $0.1.x * pad.width, y: $0.1.y * pad.height), pressure: 30, size: 0.5, major: 7.5) },
                     arrival: t + 1000, sensorT: t)
        }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            nextId += 1; let id = nextId
            for k in 0...30 { let f = Double(k) / 30; frame([(id, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))]) }
            for _ in 0..<3 { frame([]) }
            spin(0.1)
        }
        /// Straight to the canvas's handlers: in the background the window would take a click as activating it (the canvas
        /// doesn't accept first mouse outside draw mode); in front, AppKit routes these events to the same handlers.
        func mouse(_ type: NSEvent.EventType, _ viewPt: CGPoint) {
            let p = c.convert(viewPt, to: nil)
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type { case .leftMouseDown: c.mouseDown(with: e); case .leftMouseDragged: c.mouseDragged(with: e); default: c.mouseUp(with: e) }
        }
        func rect(_ s: CGRect?) -> [Double] { s.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [] }
        func viewRect(_ s: CGRect) -> CGRect {
            let lo = c.viewPoint(fromCanvas: CGPoint(x: s.minX, y: s.minY)), hi = c.viewPoint(fromCanvas: CGPoint(x: s.maxX, y: s.maxY))
            return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        }
        func bar() -> [String: Any] {
            let b = app.container.selectionBar
            return ["shown": !b.isHidden, "frame": [b.frame.minX, b.frame.minY, b.frame.width, b.frame.height], "copy": b.copy.title, "export": b.export.title]
        }
        let pb = AppDelegate.pasteboard
        func pasteboard() -> [String: Any] {
            var out: [String: Any] = ["types": (pb.types ?? []).map(\.rawValue), "change": pb.changeCount]
            if let d = pb.data(forType: .png), let i = CGImageSourceCreateWithData(d as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) { out["png"] = [i.width, i.height] }
            out["pdfBytes"] = pb.data(forType: .pdf)?.count ?? 0
            out["svgHasViewBox"] = pb.data(forType: .svgImage).map { String(decoding: $0, as: UTF8.self).contains("viewBox=") } ?? false
            return out
        }
        func toast() -> String { app.container.toast.isHidden ? "" : app.container.toast.stringValue }

        // A page with writing on grid paper, at 250%.
        if c.drawMode { app.exitDrawMode("test") }
        func wave(_ x: Double, _ y: Double) -> [StrokePoint] {
            (0..<120).map { StrokePoint(p: CGPoint(x: x + Double($0) * 8, y: y + sin(Double($0) / 5) * 30), pressure: 0.3 + 0.4 * abs(sin(Double($0) / 7))) }
        }
        for k in 0..<5 { c.testAddStroke(wave(120, 880 - Double(k) * 110)) }
        c.testAddStroke(wave(200, 560), tool: .highlighter, color: SIMD4(0xFD / 255, 0xD6 / 255, 0x63 / 255, 0.35), sizePt: 24)
        var tl = c.tools; tl.background = 1; c.tools = tl; app.container.toolbar.state = tl
        c.setVisibleForReplay(x: 150, y: 420, w: 0, z: 2.5)
        spin(0.3)
        let doc = c.doc, strokes0 = doc.strokes.count, version0 = doc.version, undo0 = doc.canUndo
        r["menu"] = ["select": menuItem(#selector(AppDelegate.selectAction))?.title ?? "", "exportSelection": menuItem(#selector(AppDelegate.exportSelectionAction))?.title ?? "",
                     "exportSelectionKey": menuItem(#selector(AppDelegate.exportSelectionAction)).map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" } ?? "",
                     "exportSelectionEnabledWithout": menuItem(#selector(AppDelegate.exportSelectionAction))?.isEnabled ?? true,
                     "copyTitleWithout": menuItem(#selector(AppDelegate.copyPageAction))?.title ?? ""]

        // 1. S: Select, in draw mode (dry lock). A one-finger drag makes the rectangle.
        key("s", 1)
        r["afterS"] = ["tool": c.tools.tool.rawValue, "draw": c.drawMode, "toolbarTool": app.container.toolbar.state.tool.rawValue]
        let a = CGPoint(x: 0.25, y: 0.35), b = CGPoint(x: 0.6, y: 0.75)
        drag(a, b)
        let ca = c.pagePointForTest(Contact(id: 0, state: 4, norm: a, mm: CGPoint(x: a.x * pad.width, y: a.y * pad.height), pressure: 30, size: 0.5, major: 7.5))
        let cb = c.pagePointForTest(Contact(id: 0, state: 4, norm: b, mm: CGPoint(x: b.x * pad.width, y: b.y * pad.height), pressure: 30, size: 0.5, major: 7.5))
        let v = c.camera.visible, m = Camera.margin, kk = 1 / (1 - 2 * m)
        func exp(_ p: CGPoint) -> CGPoint { CGPoint(x: v.minX + (p.x - m) * kk * v.width, y: v.minY + (p.y - m) * kk * v.height) }
        let want = CGRect(x: exp(a).x, y: exp(a).y, width: exp(b).x - exp(a).x, height: exp(b).y - exp(a).y)
        r["drag"] = ["selection": rect(c.selection), "want": rect(want), "mapping": [ca.x, ca.y, cb.x, cb.y], "strokes": c.doc.strokes.count]
        c.setNeedsRender(); spin(0.3)
        r["drawn"] = rect(c.selectionDrawnForTest)
        r["barDrawMode"] = bar()
        r["barNextTo"] = { () -> Bool in
            guard let s = c.selection else { return false }
            let vr = viewRect(s), f = app.container.selectionBar.frame
            return abs(f.maxX - vr.maxX) < 1.5 && (abs(f.maxY - (vr.minY - 8)) < 1.5 || abs(f.minY - (vr.maxY + 8)) < 1.5)
        }()
        r["menuWith"] = ["copyTitle": menuItem(#selector(AppDelegate.copyPageAction))?.title ?? "", "exportSelectionEnabled": menuItem(#selector(AppDelegate.exportSelectionAction))?.isEnabled ?? false]
        photo("1-select-drawmode")

        // 2. ⌘C: PNG at 2x, PDF and SVG on the pasteboard; "Copied".
        pb.clearContents()
        let copied = perform(#selector(AppDelegate.copyPageAction))
        r["copy"] = ["performed": copied, "pasteboard": pasteboard(), "toast": toast(), "want": [Int(((c.selection?.width ?? 0) * 2).rounded()), Int(((c.selection?.height ?? 0) * 2).rounded())]]

        // 3. Esc leaves draw mode and keeps the selection; the bar's buttons are for the pointer now.
        let kept = c.selection
        key("\u{1b}", 53); spin(0.3)
        r["escInDraw"] = ["draw": c.drawMode, "kept": c.selection == kept && kept != nil, "bar": bar()]
        photo("2-select-bar")

        // 4. A pointer drag outside draw mode replaces it.
        let p0 = CGPoint(x: c.bounds.width * 0.3, y: c.bounds.height * 0.6), p1 = CGPoint(x: c.bounds.width * 0.55, y: c.bounds.height * 0.35)
        mouse(.leftMouseDown, p0); for k in 1...10 { let f = Double(k) / 10; mouse(.leftMouseDragged, CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f)) }
        mouse(.leftMouseUp, p1); spin(0.2)
        let q0 = c.canvasPoint(fromView: p0), q1 = c.canvasPoint(fromView: p1)
        r["pointer"] = ["selection": rect(c.selection), "want": rect(CGRect(x: min(q0.x, q1.x), y: min(q0.y, q1.y), width: abs(q1.x - q0.x), height: abs(q1.y - q0.y))), "bar": bar()]

        // 5. The bar's Copy button.
        let ch0 = pb.changeCount
        app.container.selectionBar.copy.performClick(nil); spin(0.1)
        r["barCopy"] = ["changed": pb.changeCount != ch0, "pasteboard": pasteboard()]

        // 6. The bar's Export…: the sheet on Selection; saved in the test folder, the region at the sheet's scale.
        let out = dir + "/exports"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        app.exportDirectoryForTest = out
        ExportOptions.testStore = ["format": "png", "scale": 3.0, "area": "screen", "background": "white"]
        app.container.selectionBar.export.performClick(nil)
        var d = Date().addingTimeInterval(5)
        while app.window.attachedSheet == nil && Date() < d { spin(0.05) }
        spin(0.4)
        let acc = app.exportAccessory
        r["sheet"] = ["open": app.window.attachedSheet != nil, "area": acc?.area.titleOfSelectedItem ?? "", "areas": acc?.area.itemTitles ?? [], "label": acc?.sizeLabel.stringValue ?? "",
                      "want": [Int(((c.selection?.width ?? 0) * 3).rounded()), Int(((c.selection?.height ?? 0) * 3).rounded())]]
        photo("3-export-selection-sheet")
        if let p = app.exportPanel { app.window.endSheet(p, returnCode: .OK) }
        d = Date().addingTimeInterval(5)
        while app.window.attachedSheet != nil && Date() < d { spin(0.05) }
        spin(0.3)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
        if let f = files.first(where: { $0.hasSuffix(".png") }), let i = CGImageSourceCreateWithURL(URL(fileURLWithPath: out + "/" + f) as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
            r["exported"] = ["name": f, "size": [i.width, i.height]]
        }
        r["rememberedAreaAfter"] = ExportOptions.testStore?["area"] as? String ?? ""
        // 7. Esc (outside draw mode) clears; the bar goes; Export Page… then offers no Selection area.
        key("\u{1b}", 53); spin(0.2)
        r["escOutside"] = ["cleared": c.selection == nil, "bar": bar(), "exportSelectionEnabled": menuItem(#selector(AppDelegate.exportSelectionAction))?.isEnabled ?? true,
                           "copyTitle": menuItem(#selector(AppDelegate.copyPageAction))?.title ?? ""]
        app.exportPage()
        d = Date().addingTimeInterval(5)
        while app.window.attachedSheet == nil && Date() < d { spin(0.05) }
        spin(0.3)
        r["sheetWithout"] = ["areas": app.exportAccessory?.area.itemTitles ?? [], "area": app.exportAccessory?.area.titleOfSelectedItem ?? ""]
        if let p = app.exportPanel { app.window.endSheet(p, returnCode: .cancel) }
        d = Date().addingTimeInterval(5)
        while app.window.attachedSheet != nil && Date() < d { spin(0.05) }
        // 8. Another tool clears it (P: S again goes back to the pen); another page clears it.
        c.setSelectionForTest(CGRect(x: 300, y: 600, width: 200, height: 100)); spin(0.1)
        key("s", 1)   // Select again: back to the pen
        r["toolSwitch"] = ["tool": c.tools.tool.rawValue, "cleared": c.selection == nil]
        if c.drawMode { app.exitDrawMode("test") }
        var t3 = c.tools; t3.tool = .select; c.tools = t3; app.container.toolbar.state = t3
        c.setSelectionForTest(CGRect(x: 300, y: 600, width: 200, height: 100)); spin(0.1)
        app.page(0)   // a new page
        r["pageSwitch"] = ["cleared": c.selection == nil, "bar": bar()]
        app.page(-1)
        r["notAnEdit"] = ["sameDoc": c.doc === doc, "strokes": doc.strokes.count, "strokes0": strokes0, "version": doc.version, "version0": version0, "canUndo": doc.canUndo, "canUndo0": undo0]
        finish()
    }
}
