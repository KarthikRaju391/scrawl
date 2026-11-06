// --test-stability (checks/stability.sh): the 0.1.6.1 fixes that need the whole app (the window's chevron, the overview, Settings,
// the Inbox, the overview's tiles), driven through the app delegate's own entry points on a virtual clock. Runs in the
// background with --offscreen: no window is put on screen, nothing takes focus, the pointer is never locked (test modes
// enter draw mode without the lock). Uses only API 0.1.6 has too, so the same file runs against 7955f70.
//   #3 draw mode never on behind the overview: ⌃⌥D there, closing Settings, an Inbox import
//   #4 the chevron is the waiting move: ⌘Z, N, ⌘], Esc, G each hide it with the move; Esc and G: no move, no haptic later
//   #6 a page deleted outside the overview, a stroke, N: the new page's tile isn't the deleted page's
//   #16 Settings opened from draw mode: after you turn draw mode on and off yourself, closing it doesn't start drawing
import AppKit

enum TestStability {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        var r: [String: Any] = [:]
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func wait(_ s: Double, _ cond: () -> Bool) -> Bool { let end = Date().addingTimeInterval(s); while !cond() && Date() < end { spin(0.02) }; return cond() }
        // The canvas's clock is virtual: a waiting move fires only when the test moves the clock (never by real time).
        var now = 1000.0
        canvas.now = { now }
        var acts: [String] = []
        let prev = canvas.onAct
        canvas.onAct = { a, e in acts.append(a); prev?(a, e) }
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        var t = 500.0, nextId: Int32 = 1
        /// One long stroke across the ½-page line limit through the trackpad entry point: a next-line move waits.
        func strokePastLimit(y: Double = 0.6) {
            nextId += 1
            let pad = Multitouch.padMM
            for k in 0...30 {
                let x = 0.08 + 0.67 * Double(k) / 30
                t += 0.008
                canvas.handle([Contact(id: nextId, state: 4, norm: CGPoint(x: x, y: y), mm: CGPoint(x: x * pad.width, y: y * pad.height), pressure: 25, size: 0.5, major: 7.5)],
                              arrival: t, sensorT: t)
            }
            t += 0.008; canvas.handle([], arrival: t, sensorT: t)
            canvas.flushInputForTest()
        }
        var chevron: Bool { !app.container.pendingMove.isHidden }
        func drawAndWrite() {
            if !canvas.drawMode { app.apply(.draw, from: "test") }
            if !canvas.writingMode { app.apply(.writing, from: "test") }
            var s = canvas.tools; s.lineWidthIndex = 0; canvas.tools = s; app.container.toolbar.state = s
        }
        func moveLater() -> (moved: Bool, haptics: Int) {
            let h0 = Haptics.count, n0 = acts.filter { $0 == "newLine" }.count
            now += 2; canvas.advanceClock(); spin(0.05)
            return (acts.filter { $0 == "newLine" }.count > n0, Haptics.count - h0)
        }

        // MARK: #4 the chevron and the waiting move
        drawAndWrite()
        var c4: [String: Any] = [:]
        for name in ["cmdZ", "N", "cmdRightBracket"] {
            if name == "cmdRightBracket" { app.page(-1) }   // a page after this one (N made it)
            drawAndWrite()
            strokePastLimit()
            let shownBefore = chevron && canvas.hasPendingMoveForTest
            switch name { case "cmdZ": app.undo(); case "N": app.page(0); default: app.page(1) }
            let after = (pending: canvas.hasPendingMoveForTest, chevron: chevron)
            let later = moveLater()
            c4[name] = ["chevronBefore": shownBefore, "pendingAfter": after.pending, "chevronAfter": after.chevron,
                        "movedLater": later.moved, "ok": shownBefore && !after.pending && !after.chevron && !later.moved]
        }
        for (name, code, ch) in [("esc", UInt16(53), "\u{1b}"), ("G", UInt16(5), "g")] {
            drawAndWrite()
            strokePastLimit()
            let shownBefore = chevron && canvas.hasPendingMoveForTest
            key(ch, code)
            app.finishTransitionNow()
            let after = (pending: canvas.hasPendingMoveForTest, chevron: chevron)
            let later = moveLater()
            c4[name] = ["chevronBefore": shownBefore, "pendingAfter": after.pending, "chevronAfter": after.chevron, "movedLater": later.moved, "haptics": later.haptics,
                        "ok": shownBefore && !after.pending && !after.chevron && !later.moved && later.haptics == 0]
            if app.galleryShown { app.openPage(canvas.pageIndex); app.finishTransitionNow() }
        }
        r["chevron"] = c4
        if canvas.writingMode { app.apply(.writing, from: "test") }
        if canvas.drawMode { app.apply(.draw, from: "test") }

        // MARK: #3 draw mode behind the overview
        var c3: [String: Any] = [:]
        var behind = false
        let watch = Timer(timeInterval: 0.005, repeats: true) { _ in if canvas.drawMode && app.galleryShown { behind = true } }
        RunLoop.main.add(watch, forMode: .common)
        // ⌃⌥D with the overview open (from the page, not from draw mode).
        app.showGallery(); app.finishTransitionNow()
        behind = false
        HotKey.action?()
        let hotkeyNow = canvas.drawMode && app.galleryShown
        _ = wait(1) { !app.galleryShown && app.transitionView == nil }
        app.finishTransitionNow()
        c3["hotkey"] = ["behindAtOnce": hotkeyNow, "behindEver": behind, "overviewAfter": app.galleryShown, "drawAfter": canvas.drawMode,
                        "ok": !hotkeyNow && !behind && !app.galleryShown && canvas.drawMode]
        if canvas.drawMode { app.exitDrawMode("test") }
        // Settings opened from draw mode (what showSettings does, without showing its window), the overview, then Settings closes.
        app.apply(.draw, from: "test")
        app.settingsResumeDraw = true; app.exitDrawMode("settings")
        app.showGallery(); app.finishTransitionNow()
        behind = false
        app.settingsWindow.onClose?()
        app.finishTransitionNow(); spin(0.1)
        c3["settingsClose"] = ["behindEver": behind, "overviewAfter": app.galleryShown, "drawAfter": canvas.drawMode, "ok": !behind && !(canvas.drawMode && app.galleryShown)]
        if canvas.drawMode { app.exitDrawMode("test") }
        if app.galleryShown { app.openPage(canvas.pageIndex); app.finishTransitionNow() }
        // An Inbox page arriving while the overview, opened from draw mode, is up.
        app.apply(.draw, from: "test")
        app.showGallery(); app.finishTransitionNow()
        behind = false
        let pages0 = canvas.pages.count
        let item = "stability-\(getpid())"
        writeInboxItem(id: item, dataDir: dir)
        let arrived = wait(15) { canvas.pages.contains { $0.importId == item } }
        spin(0.5); app.finishTransitionNow(); spin(0.1)
        c3["inbox"] = ["arrived": arrived, "pages": canvas.pages.count - pages0, "overviewAfter": app.galleryShown, "drawAfter": canvas.drawMode, "behindEver": behind,
                       "ok": arrived && app.galleryShown && !canvas.drawMode && !behind]
        if app.galleryShown { app.openPage(canvas.pageIndex); app.finishTransitionNow() }
        if canvas.drawMode { app.exitDrawMode("test") }
        watch.invalidate()
        r["overview"] = c3

        // MARK: #16 Settings' "go back to drawing" expires
        app.apply(.draw, from: "test")
        app.settingsResumeDraw = true; app.exitDrawMode("settings")
        app.apply(.draw, from: "test"); app.apply(.draw, from: "test")   // on and off again yourself
        app.settingsWindow.onClose?()
        app.finishTransitionNow()
        r["settingsResume"] = ["drawAfterClose": canvas.drawMode, "ok": !canvas.drawMode]
        if canvas.drawMode { app.exitDrawMode("test") }

        // MARK: #6 a deleted page's tile on a new page
        app.warmsThumbnails = true
        let cache = ThumbnailCache.shared
        var c6: [String: Any] = ["tries": 0]
        func pixels(_ i: CGImage?) -> Data? { i.flatMap { $0.dataProvider?.data as Data? } }
        for attempt in 1...40 {
            app.page(0)                                   // P: a new page with three long lines
            drawAndWrite(); app.apply(.writing, from: "test")
            for k in 0..<3 { strokePastLimit(y: 0.8 - 0.15 * Double(k)) }
            let p = canvas.doc, pIndex = canvas.pageIndex, pKey = ObjectIdentifier(p), pVersion = p.version
            app.warmThumbnails()
            _ = wait(5) { cache.cached(p).fresh }
            let pTile = pixels(cache.cached(p).image)
            app.exitDrawMode("test")
            app.page(-1)                                  // back to the page before, then P is deleted (not in the overview)
            app.deletePage(pIndex)
            app.apply(.draw, from: "test"); strokePastLimit(y: 0.3)   // a stroke: ⌘Z is for the ink again, P is gone
            app.exitDrawMode("test")
            app.page(0)                                   // N
            let n = canvas.doc
            c6["tries"] = attempt
            guard ObjectIdentifier(n) == pKey else { continue }
            c6["addressReused"] = true
            app.apply(.draw, from: "test")
            while n.version < pVersion { nextId += 1; t += 0.008
                let pad = Multitouch.padMM
                for k in 0...3 { t += 0.008; canvas.handle([Contact(id: nextId, state: 4, norm: CGPoint(x: 0.3 + 0.01 * Double(k), y: 0.5), mm: CGPoint(x: (0.3 + 0.01 * Double(k)) * pad.width, y: 0.5 * pad.height), pressure: 25, size: 0.5, major: 7.5)], arrival: t, sensorT: t) }
                t += 0.008; canvas.handle([], arrival: t, sensorT: t); canvas.flushInputForTest() }
            app.exitDrawMode("test")
            c6["sameVersion"] = n.version == pVersion
            let takenFresh = cache.cached(n).fresh
            app.showGallery(); app.finishTransitionNow()
            _ = wait(5) { cache.cached(n).fresh }
            let nTile = pixels(cache.cached(n).image)
            c6["takenAsFresh"] = takenFresh
            c6["tileIsDeletedPages"] = nTile != nil && nTile == pTile
            c6["ok"] = !(takenFresh) && !(nTile != nil && nTile == pTile)
            app.openPage(canvas.pageIndex); app.finishTransitionNow()
            break
        }
        if c6["ok"] == nil { c6["ok"] = true; c6["note"] = "no address reuse in \(c6["tries"] ?? 0) tries: inconclusive in the app (the bench checks the cache with a reused address)" }
        r["deletedTile"] = c6

        r["allOk"] = [c4.values, c3.values].joined().allSatisfy { ($0 as? [String: Any])?["ok"] as? Bool == true }
            && (r["settingsResume"] as? [String: Any])?["ok"] as? Bool == true && c6["ok"] as? Bool == true
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: dir + "/test-stability.json")) }
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }

    /// An Inbox item the way the browser extension's host writes one (tools/inbox_write.py): a picture and page.json, renamed into place.
    static func writeInboxItem(id: String, dataDir: String) {
        let inbox = dataDir + "/Inbox", tmp = inbox + "/.tmp-" + id
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let w = 400, h = 300
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: tmp + "/page.png"))
            }
        }
        let page: [String: Any] = ["version": 1, "image": "page.png", "coordinateScale": 1, "source": ["title": "stability check"], "strokes": []]
        try? JSONSerialization.data(withJSONObject: page).write(to: URL(fileURLWithPath: tmp + "/page.json"))
        try? FileManager.default.moveItem(atPath: tmp, toPath: inbox + "/" + id + ".scrawlpage")
    }
}
