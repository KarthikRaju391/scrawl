// --test-gallerykeys: one highlight in the pages overview, moved by the arrow keys and the pointer;
// G / Return / Space open the highlighted page; Esc goes back to the page that was open.
import AppKit

enum TestGalleryKeys {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func arrow(_ code: UInt16, _ ch: Int) {
            let s = String(Character(UnicodeScalar(ch)!))
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: app.window.windowNumber,
                                        context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func right() { arrow(124, 0xF703) }
        func mouse(_ type: NSEvent.EventType, cell i: Int) {
            guard let g = app.gallery else { return }
            let rc = g.cellRect(i, in: app.container)
            let p = app.container.convert(CGPoint(x: rc.midX, y: rc.midY), to: nil)
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .mouseMoved ? 0 : 1) { app.window.sendEvent(e) }
        }
        func rings() -> [String: Int] {
            app.gallery!.displayGridNow()
            return Dictionary(uniqueKeysWithValues: app.gallery!.ringsDrawn.map { (String($0.key), $0.value) })
        }
        func shot(_ n: Int) {
            app.gallery!.displayGridNow()
            try? "\(n)".write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
            let d = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") && Date() < d { spin(0.03) }
        }
        var r: [String: Any] = [:]
        if canvas.drawMode { app.exitDrawMode("test") }
        canvas.clearPage()
        while canvas.pages.count < 12 { canvas.newPage() }
        canvas.goToPage(2)
        // Open on page 3: one ring, on page 3.
        key("g", 5); waitTransition()
        r["open"] = ["selected": app.gallery!.selected, "rings": rings()]
        shot(0)
        // Arrows move that one ring.
        right(); right()
        r["afterRightRight"] = ["selected": app.gallery!.selected, "rings": rings(), "currentDot": app.gallery!.currentDotDrawn]
        shot(1)
        // G opens the highlighted page (5), not the one that was open (3).
        key("g", 5); waitTransition()
        r["gOpens"] = ["page": canvas.pageIndex, "galleryShown": app.galleryShown, "from": app.lastTransition["from"] ?? [], "kind": app.lastTransition["kind"] ?? ""]
        // Back in: the highlight starts on the current page (5); move it, then Esc: back to page 5.
        key("g", 5); waitTransition()
        let startSel = app.gallery!.selected
        right(); right(); right()
        key("\u{1b}", 53); waitTransition()
        r["esc"] = ["startSelected": startSel, "page": canvas.pageIndex, "galleryShown": app.galleryShown]
        // Pointer: hovering a tile moves the highlight there; Return then opens it. A click opens the tile clicked.
        key("g", 5); waitTransition()
        mouse(.mouseMoved, cell: 7)
        let hovered = app.gallery!.selected, hoverRings = rings()
        key("\r", 36); waitTransition()
        r["hover"] = ["selected": hovered, "rings": hoverRings, "pageAfterReturn": canvas.pageIndex]
        key("g", 5); waitTransition()
        mouse(.leftMouseDown, cell: 9); mouse(.leftMouseUp, cell: 9); waitTransition()
        r["click"] = ["page": canvas.pageIndex]
        // Space opens too; '+ New page' with G creates a page.
        key("g", 5); waitTransition(); right(); key(" ", 49); waitTransition()
        r["space"] = ["page": canvas.pageIndex]
        key("g", 5); waitTransition()
        let pages0 = canvas.pages.count
        app.gallery!.selected = app.gallery!.cellCount - 2; right()
        key("g", 5); waitTransition()
        r["newPage"] = ["pagesBefore": pages0, "pages": canvas.pages.count, "page": canvas.pageIndex]
        // A held key (Karthik, 30 Oct: the overview and pages flashing back and forth while he held G): the key
        // auto-repeats (macOS: first repeat after ~225 ms, then every ~33 ms). One press is one change, however long
        // it's held: count the transitions and the overview <-> page switches while the repeats come in.
        func hold(_ ch: String, _ code: UInt16, seconds: Double) -> [String: Any] {
            var transitions = 0, switches = 0, lastTV: NSView? = nil, lastShown = app.galleryShown
            func sample() {
                if let tv = app.transitionView, tv !== lastTV { transitions += 1; lastTV = tv }
                if app.galleryShown != lastShown { switches += 1; lastShown = app.galleryShown }
            }
            func send(_ rep: Bool) {
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                            characters: ch, charactersIgnoringModifiers: ch, isARepeat: rep, keyCode: code) { _ = app.key(e) }
                sample()
            }
            let pageBefore = canvas.pageIndex, shownBefore = app.galleryShown
            send(false)
            let t0 = Date(); var next = 0.225
            while Date().timeIntervalSince(t0) < seconds {
                spin(0.005); sample()
                if Date().timeIntervalSince(t0) >= next { send(true); next += 0.033 }
            }
            waitTransition(); sample()
            return ["transitions": transitions, "switches": switches, "shownBefore": shownBefore, "shownAfter": app.galleryShown,
                    "pageBefore": pageBefore, "pageAfter": canvas.pageIndex]
        }
        canvas.goToPage(3)
        r["holdGOnPage"] = hold("g", 5, seconds: 1.5)            // a page open: G held -> the overview, once
        mouse(.mouseMoved, cell: 6)
        r["holdGInOverview"] = hold("g", 5, seconds: 1.5)        // the overview, page 7 highlighted: G held -> page 7, once
        key("g", 5); waitTransition(); mouse(.mouseMoved, cell: 8)
        r["holdReturnInOverview"] = hold("\r", 36, seconds: 1.5) // Return held -> page 9, once
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-gallerykeys.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
