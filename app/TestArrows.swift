// --test-arrows write|read: page arrows dim (and do nothing) when there's no page that way: toolbar
// clicks and ⌘[ / ⌘] alike. write: one page, then three (first/middle/last), clicks and shortcuts at the
// ends, opening page 1 from the overview; saves with the last page open. read (a new launch): the state
// at launch. checks/arrows.sh reads test-arrows-<phase>.json.
import AppKit

enum TestArrows {
    static func run(_ phase: String, app: AppDelegate) {
        let canvas = app.canvas, tb = app.container.toolbar, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        func menuEnabled(_ sel: Selector) -> Bool {
            for top in NSApp.mainMenu?.items ?? [] { for i in top.submenu?.items ?? [] where i.action == sel { return app.validateMenuItem(i) } }
            return false
        }
        func state(_ label: String) -> [String: Any] {
            ["at": label, "page": canvas.pageIndex, "pages": canvas.pages.count, "prevArrow": tb.canGoBack, "nextArrow": tb.canGoForward,
             "prevMenu": menuEnabled(#selector(AppDelegate.prevPageAction)), "nextMenu": menuEnabled(#selector(AppDelegate.nextPageAction))]
        }
        func click(_ item: ToolbarView.Item) {
            guard let p = tb.center(of: item) else { return }
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }
            }
        }
        /// ⌘[ or ⌘] through the menu bar, as the keyboard would.
        func shortcut(_ ch: String, _ code: UInt16) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                           characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
        }
        var r: [String: Any] = ["phase": phase]
        if phase == "write" {
            if app.canvas.drawMode { app.exitDrawMode("test") }
            var steps: [[String: Any]] = [state("one page")]
            app.page(0); app.page(0)
            steps.append(state("three pages, on the last"))
            canvas.goToPage(1); steps.append(state("middle"))
            app.page(-1); steps.append(state("first"))
            // At the first page: Prev does nothing (click and ⌘[); Next works (control).
            click(.prevPage); let afterPrevClick = canvas.pageIndex
            let cmdBracketHandled = shortcut("[", 33); let afterCmdBracket = canvas.pageIndex
            _ = shortcut("]", 30); let afterCmdNext = canvas.pageIndex
            steps.append(["at": "first: click Prev, ⌘[", "pageAfterPrevClick": afterPrevClick, "pageAfterCmdBracket": afterCmdBracket, "cmdBracketHandled": cmdBracketHandled,
                          "pageAfterCmdCloseBracket": afterCmdNext])
            // At the last page: Next does nothing (click and ⌘]).
            canvas.goToPage(2)
            click(.nextPage); let afterNextClick = canvas.pageIndex
            _ = shortcut("]", 30); let afterCmdNextAtLast = canvas.pageIndex
            steps.append(["at": "last: click Next, ⌘]", "pageAfterNextClick": afterNextClick, "pageAfterCmdCloseBracket": afterCmdNextAtLast, "pages": canvas.pages.count])
            // Opening page 1 from the overview updates the arrows.
            app.showGallery(); waitTransition(); app.openPage(0); waitTransition()
            steps.append(state("page 1 opened from the overview"))
            canvas.goToPage(2)
            canvas.testAddStroke((0..<20).map { StrokePoint(p: CGPoint(x: 100 + Double($0) * 10, y: 600), pressure: 0.6) })
            canvas.autosaver.saveNow(sync: true)
            r["steps"] = steps
        } else {
            r["atLaunch"] = state("launch")   // the notebook was saved with page 3 of 3 open
        }
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-arrows-\(phase).json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
