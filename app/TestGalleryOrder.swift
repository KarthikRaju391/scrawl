// --test-gallery-order: the pages overview shows the "New page" tile first, then the pages, the most recently
// changed first (Karthik, 31 Oct). Changes are made on a controlled clock through the app's own paths: ink, the
// eraser (a real swipe through the input path), scratch-out, undo; a view change and an eraser swipe over blank paper
// don't count. A page with only a created date (older files) sorts by it; one with no dates goes last. Also: the
// initial highlight, G back and forth, arrows and Return on the New page tile, ⌘] in notebook order, Delete and ⌘Z.
// Uses only what the overview had before the change (tile rects, labels, the selection), so it runs on older builds
// too. checks/galleryorder.sh reads test-gallery-order.json.
import AppKit

enum TestGalleryOrder {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir, pad = Multitouch.padMM
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        func key(_ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func arrow(_ code: UInt16, _ ch: Int) { key(String(Character(UnicodeScalar(ch)!)), code, [.numericPad, .function]) }
        func left() { arrow(123, 0xF702) }; func right() { arrow(124, 0xF703) }; func up() { arrow(126, 0xF700) }
        func shot(_ n: Int) {
            app.gallery?.displayGridNow()
            try? "\(n)".write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
            let d = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") && Date() < d { spin(0.03) }
        }
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 } }
        /// The tiles as a person reads them: top row first, left to right (items: page index, or pages.count = New page).
        func visual() -> [Int] {
            guard let g = app.gallery else { return [] }
            return (0..<g.cellCount).sorted { a, b in
                let ra = g.cellRectInGrid(a), rb = g.cellRectInGrid(b)
                return abs(ra.minY - rb.minY) > 1 ? ra.minY < rb.minY : ra.minX < rb.minX
            }
        }
        func labels() -> [String] { visual().map { app.gallery!.tileLabel($0) } }
        func overview() -> [String: Any] {
            let g = app.gallery!; g.displayGridNow()
            let v = visual()
            return ["visual": v.map { $0 == g.cellCount - 1 ? "new" : "\($0)" }, "labels": labels(), "selected": g.selected == g.cellCount - 1 ? "new" : "\(g.selected)",
                    "selectedAt": v.firstIndex(of: g.selected) ?? -1, "ringOn": g.ringsDrawn.keys.map { $0 == g.cellCount - 1 ? "new" : "\($0)" },
                    "pages": canvas.pages.count, "current": canvas.pageIndex]
        }
        /// An eraser swipe through the input path, across the middle of the pad (or high up, over blank paper).
        var t0 = 0.0
        func eraserSwipe(yMM: Double) {
            var t = canvas.tools; t.tool = .eraser; canvas.tools = t
            app.enterDrawMode(lock: false)
            for k in 0...40 {
                t0 += 0.008
                let x = 30 + Double(k) * 1.6
                canvas.handle([Contact(id: 3, state: 4, norm: CGPoint(x: x / pad.width, y: yMM / pad.height), mm: CGPoint(x: x, y: yMM), pressure: 30, size: 0.5, major: 7.5)],
                              arrival: t0 + 1000, sensorT: t0)
            }
            for _ in 0..<5 { t0 += 0.008; canvas.handle([], arrival: t0 + 1000, sensorT: t0) }
            canvas.flushInputForTest()
            app.exitDrawMode("test")
            t.tool = .pen; canvas.tools = t
        }
        /// Ink across the middle of the current view (under the eraser swipe).
        func ink() {
            let v = canvas.camera.visible, y = canvas.camera.canvas(fromPad: CGPoint(x: 0.5, y: 38 / pad.height)).y
            canvas.testAddStroke((0...60).map { StrokePoint(p: CGPoint(x: v.minX + v.width * (0.15 + Double($0) * 0.01), y: y), pressure: 0.6) })
        }
        var r: [String: Any] = [:]
        if canvas.drawMode { app.exitDrawMode("test") }
        let T0 = 1_792_400_000.0   // Oct 19, 2026
        var clock = Date(timeIntervalSince1970: T0)
        Document.clock = { clock }
        func at(_ s: Double) { clock = Date(timeIntervalSince1970: T0 + s) }
        // Pages 1-8 (indices 0-7), each made with a little ink a minute apart.
        canvas.pages[0].created = clock; canvas.pages[0].edited = clock
        ink()
        for k in 1...7 { at(Double(k) * 100); app.page(0); ink() }
        // Changes, a later time each.
        at(1000); canvas.goToPage(1); ink()                                            // page 2: ink added
        at(2000); canvas.goToPage(3); eraserSwipe(yMM: 38)                              // page 4: erased (the real eraser)
        r["erasedOnPage4"] = canvas.pages[3].strokes.count
        at(3000); canvas.goToPage(0); canvas.doc.scratchOut(erasing: [canvas.doc.strokes[0]])   // page 1: scratched out
        at(4000); canvas.goToPage(4); canvas.undo()                                    // page 5: undo
        canvas.pages[6].edited = nil; canvas.pages[6].created = Date(timeIntervalSince1970: T0 + 2500)   // page 7: an older file (created only)
        canvas.pages[7].edited = nil; canvas.pages[7].created = nil                     // page 8: no dates at all
        at(5000); canvas.goToPage(2)                                                    // page 3: only looked at, panned and zoomed,
        canvas.setZoom(3); canvas.panByArrow(dx: 1, dy: 0, screen: false); canvas.panByArrow(dx: 0, dy: 1, screen: false)
        eraserSwipe(yMM: 8)                                                             // and an eraser swipe over blank paper
        r["page3Strokes"] = canvas.pages[2].strokes.count
        r["edited"] = canvas.pages.map { $0.edited.map { $0.timeIntervalSince1970 - T0 } ?? -1 }
        app.updateBanner()
        r["hintBefore"] = app.container.hint.stringValue

        // 1. G: the overview, from page 3 (the open page).
        key("g", 5); waitTransition()
        r["open1"] = overview()
        r["closeInto"] = ["to": (app.lastTransition["to"] as? [CGFloat] ?? []).map { (Double($0) * 10).rounded() / 10 }, "page3Tile": rect(app.gallery!.cellRect(2, in: app.container))]
        shot(0)
        // 2. G again opens the highlighted page (the one you came from), growing from its tile.
        let tile3 = app.gallery!.cellRectAsShown(2, in: app.container)
        key("g", 5); waitTransition()
        r["gBack"] = ["page": canvas.pageIndex, "from": (app.lastTransition["from"] as? [CGFloat] ?? []).map { (Double($0) * 10).rounded() / 10 }, "tile": rect(tile3)]
        // 3. ⌘] / ⌘[ on the page keep the notebook's order.
        app.page(1); r["nextFromPage3"] = canvas.pageIndex
        app.page(-1); r["prevBack"] = canvas.pageIndex
        // 4. Arrows: up and left as far as they go reach the first tile; right from there; Return on New page.
        key("g", 5); waitTransition()
        for _ in 0..<12 { up(); left() }
        r["afterUpLeft"] = overview()
        right(); r["rightFromFirst"] = overview()
        left(); left(); r["leftFromFirst"] = overview()
        let newTile = app.gallery!.cellRectAsShown(app.gallery!.selected, in: app.container)
        at(6000); key("\r", 36); waitTransition()
        r["afterReturn"] = ["pages": canvas.pages.count, "page": canvas.pageIndex, "strokes": canvas.doc.strokes.count,
                            "from": (app.lastTransition["from"] as? [CGFloat] ?? []).map { (Double($0) * 10).rounded() / 10 }, "tile": rect(newTile)]
        app.updateBanner(); r["hintNew"] = app.container.hint.stringValue
        // 5. Back to the overview: the new page is the most recent, right after the New page tile.
        key("g", 5); waitTransition()
        r["open2"] = overview(); shot(1)
        // 6. Delete the highlighted page (the new one): the tile that moves into its place gets the highlight. ⌘Z brings it back.
        let before = labels()
        key("\u{7f}", 51); spin(0.2)
        r["afterDelete"] = overview(); r["labelsBeforeDelete"] = before
        app.undo(); spin(0.2)
        r["afterRestore"] = overview()
        // 7. Reduce motion: the page fades at full size, no zoom from or into the tile.
        AppDelegate.reduceMotionForTest = true
        key("\u{1b}", 53); waitTransition()
        func tr() -> [String: Any] { ["from": (app.lastTransition["from"] as? [CGFloat] ?? []).map { Double($0) }, "to": (app.lastTransition["to"] as? [CGFloat] ?? []).map { Double($0) },
                                     "reduce": app.lastTransition["reduceMotion"] as? Bool ?? false] }
        let full = [canvas.frame.minX, canvas.frame.minY, canvas.frame.width, canvas.frame.height].map { Double($0) }
        key("g", 5); waitTransition(); let rmClose = tr()
        key("g", 5); waitTransition(); let rmOpen = tr()
        AppDelegate.reduceMotionForTest = nil
        r["reduceMotion"] = ["close": rmClose, "open": rmOpen, "full": full]
        key("g", 5); waitTransition()
        // 8. Search with no query matches every page, in tile order.
        r["matching"] = app.gallery!.matching
        key("\u{1b}", 53); waitTransition()
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-gallery-order.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
