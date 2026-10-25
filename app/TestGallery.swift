// --test-gallery write|read: the page overview. checks/gallery.sh runs write, then read in a new process
// (same TRACKPAD_DRAW_DATA), to check persistence. Geometry is asserted from the rects the transition
// actually used and the frame the animated view ended at. With TRACKPAD_DRAW_SLOW_TRANSITION it also
// requests screenshots during an opening transition (shot-N.req / shot-N.done, as in page.sh).
import AppKit

enum TestGallery {
    /// Page k (k < 6) has k+1 horizontal lines at known heights; page 3 is empty. More pages are empty.
    static func lines(_ k: Int) -> [Double] { k == 3 ? [] : (0...k).map { 900 - Double($0) * 120 } }

    static func run(_ phase: String, app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        var r: [String: Any] = ["phase": phase]
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func click(cell i: Int) {
            guard let g = app.gallery else { return }
            let rc = g.cellRect(i, in: app.container)
            let p = app.container.convert(CGPoint(x: rc.midX, y: rc.midY), to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }
            }
        }
        func rect(_ x: CGRect) -> [Double] { [x.minX, x.minY, x.width, x.height] }
        /// Rows (0 = top of the thumbnail, as a fraction of its height) where the thumbnail has dark ink.
        func inkRows(_ img: CGImage) -> [Double] {
            let w = img.width, h = img.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var rows: [Double] = []
            for y in 0..<h {   // bitmap memory is top row first
                var dark = 0
                for x in stride(from: 0, to: w, by: 2) where p[(y * w + x) * 4] < 100 { dark += 1 }
                if dark > w / 20 { rows.append(Double(y) / Double(h)) }
            }
            return rows
        }
        /// `afterCacheEdit`: page 3 also has the line added at y = 500 by the caching check.
        func thumbnailCheck(afterCacheEdit: Bool = false) -> [[String: Any]] {
            (0..<6).map { k -> [String: Any] in
                let img = app.gallery!.thumbnails.image(for: canvas.pages[k], page: canvas.camera.page)!
                let rows = inkRows(img)
                // Expected: a line at page y maps to thumbnail row (top - y) / height of the part the thumbnail
                // shows (cropped to the ink).
                let ys = lines(k) + (afterCacheEdit && k == 2 ? [500] : [])
                let reg = ThumbnailCache.region(canvas.pages[k].strokes, page: canvas.camera.page)
                let want = ys.map { (reg.maxY - $0) / reg.height }
                let found = want.map { w in rows.contains { abs($0 - w) < 0.02 } }
                let stray = rows.filter { r in !want.contains { abs($0 - r) < 0.03 } }.count
                return ["page": k, "want": want.count, "found": found.filter { $0 }.count, "strayRows": stray]
            }
        }
        if phase == "write" {
            canvas.clearPage()
            for k in 0..<40 {
                if k > 0 { canvas.newPage() }
                for y in lines(k < 6 ? k : 3) {
                    canvas.testAddStroke((0..<120).map { StrokePoint(p: CGPoint(x: 100 + Double($0) * 11, y: y), pressure: 0.7) })
                }
            }
            canvas.goToPage(2)
            app.enterDrawMode(lock: false)
            // 1. G from a page: draw mode off, the canvas shrinks into page 3's cell.
            key("g", 5); let galleryAfterG = app.galleryShown, drawAfterG = canvas.drawMode
            let closeT = app.lastTransition
            let wantClose = ["from": rect(canvas.frame), "to": rect(app.gallery!.cellRect(2, in: app.container))]
            waitTransition()
            r["close"] = ["shown": galleryAfterG, "drawModeInGallery": drawAfterG, "transition": app.lastTransition, "want": wantClose, "startRecorded": closeT["startFrame"] ?? []]
            r["columns"] = app.gallery!.columns
            // 2. Thumbnails show each page's contents.
            app.gallery!.needsDisplay = true; app.gallery!.display()
            r["thumbnails"] = thumbnailCheck()
            // 3. Cached: going back and reopening renders nothing new; changing one page re-renders only it.
            let renders0 = app.gallery!.thumbnails.renders
            key("\u{1b}", 53); waitTransition(); key("g", 5); waitTransition()
            app.gallery!.display()
            let renders1 = app.gallery!.thumbnails.renders
            key("\u{1b}", 53); waitTransition()
            canvas.testAddStroke((0..<60).map { StrokePoint(p: CGPoint(x: 300 + Double($0) * 5, y: 500), pressure: 0.7) })   // page 3 (index 2) changes
            key("g", 5); waitTransition(); app.gallery!.display()
            for k in 0..<6 { _ = app.gallery!.thumbnails.image(for: canvas.pages[k], page: canvas.camera.page) }
            let renders2 = app.gallery!.thumbnails.renders
            r["cache"] = ["first": renders0, "afterReopen": renders1, "afterOnePageChanged": renders2]
            // 4. Click page 5's cell: it grows from that cell to the canvas; page 5 is open, draw mode is back.
            let cell4 = app.gallery!.cellRect(4, in: app.container)
            click(cell: 4)
            let openT = app.lastTransition
            waitTransition()
            r["open"] = ["transition": app.lastTransition, "want": ["from": rect(cell4), "to": rect(canvas.frame)], "startRecorded": openT["startFrame"] ?? [],
                         "pageIndex": canvas.pageIndex, "galleryHidden": !app.galleryShown, "drawModeBack": canvas.drawMode]
            // 5. G twice: same page, draw mode back.
            key("g", 5); waitTransition(); key("g", 5); waitTransition()
            r["roundTrip"] = ["pageIndex": canvas.pageIndex, "drawMode": canvas.drawMode, "galleryHidden": !app.galleryShown]
            // 6. Many pages scroll: page 40's cell is scrolled into view inside the scroll view.
            key("g", 5); waitTransition()
            let clip = app.gallery!.scroll.contentView
            let y0 = clip.bounds.minY
            let c39 = app.gallery!.cellRect(39, in: clip)
            r["scroll"] = ["docHeight": app.gallery!.scroll.documentView!.frame.height, "visibleHeight": clip.bounds.height,
                           "scrolledBy": clip.bounds.minY - y0, "cell40Visible": clip.bounds.contains(c39)]
            // 7. The New page tile (last): a 41st page, opened, growing from that tile.
            let tile = app.gallery!.cellRect(40, in: app.container)
            click(cell: 40); waitTransition()
            r["newPage"] = ["pages": canvas.pages.count, "pageIndex": canvas.pageIndex, "from": ((app.lastTransition["from"] as? [CGFloat]) ?? []).map { Double($0) }, "want": rect(tile)]
            // 8. Esc in the gallery goes back to the current page.
            key("g", 5); waitTransition(); key("\u{1b}", 53); waitTransition()
            r["esc"] = ["galleryHidden": !app.galleryShown, "pageIndex": canvas.pageIndex]
            if ProcessInfo.processInfo.environment["TRACKPAD_DRAW_SLOW_TRANSITION"] != nil {
                // Screenshots: the grid, then an opening transition at three moments.
                key("g", 5); waitTransition()
                func shot(_ n: Int) {
                    try? "\(n)".write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
                    let d = Date().addingTimeInterval(10)
                    while !FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") && Date() < d { spin(0.03) }
                }
                shot(0)
                click(cell: 4)
                spin(0.25); shot(1); spin(0.5); shot(2); spin(0.5); shot(3)
                waitTransition(); shot(4)
            }
            canvas.autosaver.saveNow(sync: true)
        } else {   // read, after a restart
            key("g", 5); waitTransition(); app.gallery!.display()
            r["afterRestart"] = ["pages": canvas.pages.count, "galleryShown": app.galleryShown, "thumbnails": thumbnailCheck(afterCacheEdit: true), "load": app.notebookStatus]
        }
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-gallery-\(phase).json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
