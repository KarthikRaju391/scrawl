// --test-arrowkeys: arrow keys pan the canvas (10% of the view, Shift: one view; clamped at the page's sides
// and top; zoom lock, draw mode and writing mode; never a new line or a page change; not while a text
// field has focus), and move a selection in the pages overview (Return / Space opens it).
import AppKit

enum TestArrowKeys {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, container = app.container!, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        let arrows: [String: (UInt16, Int)] = ["left": (123, 0xF702), "right": (124, 0xF703), "down": (125, 0xF701), "up": (126, 0xF700)]
        func press(_ name: String, shift: Bool = false) {
            let (code, ch) = arrows[name]!
            let s = String(Character(UnicodeScalar(ch)!))
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift, .numericPad, .function] : [.numericPad, .function], timestamp: 0,
                                        windowNumber: app.window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func v() -> [Double] { let r = canvas.camera.visible; return [r.minX, r.minY, r.width, r.height] }
        var r: [String: Any] = [:]
        if canvas.drawMode { app.exitDrawMode("test") }
        canvas.clearPage()
        // 1. Canvas panning, windowed and full-screen sizes, zoom 1 and 3.
        var pans: [[String: Any]] = []
        for (shape, size) in [("window", nil), ("full screen 1512x950", CGSize(width: 1512, height: 950))] as [(String, CGSize?)] {
            if let size { container.setFrameSize(size); container.needsLayout = true; container.layoutSubtreeIfNeeded() }
            for zoom in [1.0, 3.0] {
                for locked in [false, true] {
                    var t = canvas.tools; t.zoomLocked = locked; canvas.tools = t
                    let pw = canvas.camera.page.width, w = pw / zoom
                    // Start a little down and in from the top-left, so every direction can move (except at zoom 1 sideways).
                    canvas.setVisibleForReplay(x: zoom > 1 ? pw * 0.3 : 0, y: canvas.camera.page.height - canvas.camera.page.height / zoom - 300, w: w, z: zoom)
                    var row: [String: Any] = ["shape": shape, "zoom": zoom, "locked": locked, "start": v()]
                    for (name, shift) in [("right", false), ("left", false), ("down", false), ("up", false), ("right", true), ("down", true)] {
                        let before = v(); press(name, shift: shift); row["\(shift ? "shift-" : "")\(name)"] = [before, v()]
                    }
                    // Clamp: many ups reach the page top and stop; many lefts reach the left side and stop.
                    for _ in 0..<40 { press("up", shift: true) }; row["topAfterUps"] = canvas.camera.visible.maxY; row["pageTop"] = canvas.camera.page.height
                    for _ in 0..<40 { press("left", shift: true) }; row["leftAfterLefts"] = canvas.camera.visible.minX
                    for _ in 0..<40 { press("right", shift: true) }; row["rightAfterRights"] = canvas.camera.visible.maxX; row["pageWidth"] = pw
                    row["zoomAfter"] = canvas.camera.zoom
                    pans.append(row)
                }
            }
        }
        r["pans"] = pans
        container.setFrameSize(app.window.contentRect(forFrameRect: app.window.frame).size); container.needsLayout = true; container.layoutSubtreeIfNeeded()
        // 2. Draw mode + writing mode: arrows pan, no new line, no page change.
        var tl = canvas.tools; tl.zoomLocked = false; canvas.tools = tl
        app.enterDrawMode(lock: false); if !canvas.writingMode { app.toggleWriting() }
        canvas.setVisibleForReplay(x: 400, y: canvas.camera.page.height - canvas.camera.page.height / 3 - 200, w: canvas.camera.page.width / 3, z: 3)
        let nl0 = canvas.newLineCount, page0 = canvas.pageIndex, pages0 = canvas.pages.count, v0 = v()
        press("right"); press("down"); press("right", shift: true)
        r["drawWriting"] = ["moved": v() != v0, "newLines": canvas.newLineCount - nl0, "page": canvas.pageIndex, "page0": page0, "pages": canvas.pages.count, "pages0": pages0, "drawMode": canvas.drawMode]
        app.toggleWriting(); app.exitDrawMode("test")
        // 3. A text field with focus gets the keys (letters and arrows), not the canvas.
        let tf = NSTextField(frame: CGRect(x: 20, y: 20, width: 200, height: 24)); container.addSubview(tf)
        app.window.makeFirstResponder(tf)
        let vt = v(); press("right"); key("d", 2)
        r["textField"] = ["viewMoved": v() != vt, "drawMode": canvas.drawMode, "focusedField": app.window.firstResponder is NSText]
        tf.removeFromSuperview(); app.window.makeFirstResponder(canvas)
        // 4. Pages overview: 41 pages, current page 3.
        canvas.clearPage()
        while canvas.pages.count < 41 { canvas.newPage() }
        canvas.goToPage(2)
        key("g", 5); waitTransition()
        let g = app.gallery!
        var nav: [String: Any] = ["columns": g.columns, "cells": g.cellCount, "startSelected": g.selected]
        func sel(_ moves: [String]) -> Int { for m in moves { press(m) }; return g.selected }
        g.selected = 0; nav["leftFromFirst"] = sel(["left"]); nav["upFromFirstRow"] = sel(["up"])
        g.selected = 0; nav["rightFromFirst"] = sel(["right"]); nav["downFromFirst"] = sel(["down"])
        g.selected = g.cellCount - 1; nav["rightFromLast"] = sel(["right"]); nav["downFromLast"] = sel(["down"])
        // The last row is partial: from the row above it, a column past its end goes to the last tile.
        let cols = g.columns, lastRowStart = ((g.cellCount - 1) / cols) * cols
        g.selected = lastRowStart - 1                                   // last column of the row above the last row
        nav["downIntoPartialRow"] = sel(["down"]); nav["lastCell"] = g.cellCount - 1
        nav["rowEndRight"] = { g.selected = cols - 1; return sel(["right"]) }()   // end of the first row -> first of the next
        // Selection scrolls into view.
        g.selected = 5; _ = sel(["down", "down", "down", "down", "down", "down", "down", "down"])
        let clip = g.scroll.contentView
        nav["selectedAfterDowns"] = g.selected
        nav["selectedVisible"] = clip.bounds.contains(g.cellRect(g.selected, in: clip))
        // Return opens the selected page with the grow transition from its cell.
        g.selected = 9
        let cell9 = g.cellRect(9, in: container)
        key("\r", 36); waitTransition()
        nav["return"] = ["page": canvas.pageIndex, "from": app.lastTransition["from"] ?? [], "want": [cell9.minX, cell9.minY, cell9.width, cell9.height], "galleryHidden": !app.galleryShown]
        // Space opens too; the selection starts on the current page when the overview opens.
        key("g", 5); waitTransition()
        nav["startSelectedSecondOpen"] = g.selected
        press("right"); press("right")
        key(" ", 49); waitTransition()
        nav["space"] = ["page": canvas.pageIndex]
        // "+ New page": selectable, creates a page only on Return.
        key("g", 5); waitTransition()
        g.selected = g.cellCount - 2; press("right")
        let pagesBefore = canvas.pages.count
        nav["newTileSelected"] = g.selected == g.cellCount - 1; nav["pagesBeforeReturn"] = pagesBefore
        key("\r", 36); waitTransition()
        nav["newPage"] = ["pages": canvas.pages.count, "page": canvas.pageIndex]
        r["gallery"] = nav
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-arrowkeys.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
