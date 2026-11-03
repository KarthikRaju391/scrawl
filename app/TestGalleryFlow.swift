// --test-galleryflow: Karthik's loop in the pages overview (30 Oct): the pointer highlights a tile, G opens that page,
// G goes back, over and over, including a page saved at 370%, with presses 0.25 s apart (and faster). Every
// transition's first and last frames are rendered and compared with what is really there: the tile as the overview
// draws it, and the page with its toolbar. One press = one change; transitions never stack.
import AppKit
import CoreImage

enum TestGalleryFlow {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func key(_ ch: String, _ code: UInt16) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) { _ = app.key(e) }
        }
        func hover(cell i: Int) {
            guard let g = app.gallery, app.galleryShown else { return }
            let rc = g.cellRect(i, in: app.container)
            let p = app.container.convert(CGPoint(x: rc.midX, y: rc.midY), to: nil)
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 0) { app.window.sendEvent(e) }
        }
        // Small grey images (96 px wide) to compare what two things show.
        let W = 96
        func gray(_ draw: (CGContext, CGSize) -> Void, aspect: CGFloat) -> [UInt8] {
            let h = max(Int((CGFloat(W) / max(aspect, 0.01)).rounded()), 1)
            guard let ctx = CGContext(data: nil, width: W, height: h, bitsPerComponent: 8, bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: h))
            draw(ctx, CGSize(width: W, height: h))
            guard let d = ctx.data else { return [] }
            return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: UInt8.self), count: W * h))
        }
        /// What the moving page shows right now (its layer and sublayers, as composited).
        func transitionImage() -> [UInt8] {
            guard let tv = app.transitionView, let l = tv.layer else { return [] }
            let b = tv.bounds
            // What's on screen there: the overview underneath (where the moving page lets it through), then the page.
            var under: CGImage? = nil
            if app.galleryShown, let g = app.gallery {
                let rg = g.convert(tv.frame, from: app.container)
                if let rep = g.bitmapImageRepForCachingDisplay(in: rg) { g.cacheDisplay(in: rg, to: rep); under = rep.cgImage }
            }
            return gray({ ctx, sz in
                if let u = under { ctx.draw(u, in: CGRect(origin: .zero, size: sz)) }
                ctx.scaleBy(x: sz.width / b.width, y: sz.height / b.height)
                // The moving page's layers drawn as the window server shows them (render(in:) can't draw an IOSurface).
                ctx.addRect(b); ctx.clip()
                if let bg = l.backgroundColor { ctx.setFillColor(bg); ctx.fill(b) }
                for sub in [l] + (l.sublayers ?? []) {
                    guard let img = image(of: sub.contents), sub.opacity > 0 else { continue }
                    let f = sub === l ? b : sub.frame
                    var r = f
                    if sub.contentsGravity == .resizeAspectFill {
                        let k = max(f.width / CGFloat(img.width), f.height / CGFloat(img.height))
                        r = CGRect(x: f.midX - CGFloat(img.width) * k / 2, y: f.midY - CGFloat(img.height) * k / 2, width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
                    }
                    ctx.saveGState(); ctx.addRect(f); ctx.clip(); ctx.setAlpha(CGFloat(sub.opacity)); ctx.interpolationQuality = .high
                    ctx.draw(img, in: r); ctx.restoreGState()
                }
            }, aspect: b.width / max(b.height, 1))
        }
        /// A layer's picture as a CGImage (it may be an IOSurface).
        func image(of contents: Any?) -> CGImage? {
            guard let c = contents else { return nil }
            if CFGetTypeID(c as CFTypeRef) == CGImage.typeID { return (c as! CGImage) }
            if CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                let ci = CIImage(ioSurface: c as! IOSurfaceRef)
                return CIContext().createCGImage(ci, from: ci.extent)
            }
            return nil
        }
        /// A screenshot of the window, taken by the check script (screencapture of this window), named `name`.
        func shot(_ name: String, rect: CGRect) {
            let w = app.container.convert(rect, to: nil), fh = app.window.frame.height
            let info: [String: Any] = ["rect": [w.minX, fh - w.maxY, w.width, w.height], "scale": app.window.backingScaleFactor]
            try? JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: dir + "/\(name).json"))
            try? name.write(toFile: dir + "/\(name).req", atomically: true, encoding: .utf8)
            let d = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: dir + "/\(name).done") && Date() < d { spin(0.01) }
        }
        /// What tile i shows in the overview (drawn by the overview itself).
        func tileImage(_ i: Int) -> [UInt8] {
            guard let g = app.gallery else { return [] }
            let rc = g.cellRect(i, in: app.container), rg = g.convert(rc, from: app.container)
            guard let rep = g.bitmapImageRepForCachingDisplay(in: rg) else { return [] }
            g.cacheDisplay(in: rg, to: rep)
            guard let cg = rep.cgImage else { return [] }
            return gray({ ctx, sz in ctx.draw(cg, in: CGRect(origin: .zero, size: sz)) }, aspect: rc.width / max(rc.height, 1))
        }
        /// What the overview draws in a rect of the window (container coordinates).
        func regionImage(_ rc: CGRect) -> [UInt8] {
            guard let g = app.gallery else { return [] }
            let rg = g.convert(rc, from: app.container)
            guard let rep = g.bitmapImageRepForCachingDisplay(in: rg) else { return [] }
            g.cacheDisplay(in: rg, to: rep)
            guard let cg = rep.cgImage else { return [] }
            return gray({ ctx, sz in ctx.draw(cg, in: CGRect(origin: .zero, size: sz)) }, aspect: rc.width / max(rc.height, 1))
        }
        /// The page as the canvas shows it.
        func pageImage() -> [UInt8] {
            guard let cg = canvas.snapshot(scale: 1) else { return [] }
            return gray({ ctx, sz in ctx.draw(cg, in: CGRect(origin: .zero, size: sz)) }, aspect: canvas.bounds.width / max(canvas.bounds.height, 1))
        }
        /// How far any picture in the transition is drawn above its own resolution (1 = pixel for pixel).
        func upscale() -> Double {
            guard let root = app.transitionView?.layer else { return 0 }
            let bs = Double(app.window.backingScaleFactor)
            var worst = 0.0
            func visit(_ l: CALayer) {
                var size: (Int, Int)? = nil
                if let c = l.contents {
                    if CFGetTypeID(c as CFTypeRef) == CGImage.typeID { let img = c as! CGImage; size = (img.width, img.height) }
                    else if CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() { let sf = c as! IOSurfaceRef; size = (IOSurfaceGetWidth(sf), IOSurfaceGetHeight(sf)) }
                }
                if let (w, h) = size, w > 0, h > 0, l.opacity > 0.01 {
                    // Aspect-fill draws at the larger of the two axis scales; resize at each axis's own.
                    worst = max(worst, Double(l.bounds.width) * bs / Double(w), Double(l.bounds.height) * bs / Double(h))
                }
                l.sublayers?.forEach(visit)
            }
            visit(root)
            return worst
        }
        func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard !a.isEmpty, a.count == b.count else { return 255 }
            // Ignore a 2-px border (rounded corners, the ring's antialiasing).
            let h = a.count / W; var s = 0.0, n = 0
            for y in 2..<max(h - 2, 2) { for x in 2..<(W - 2) { s += abs(Double(a[y * W + x]) - Double(b[y * W + x])); n += 1 } }
            return n > 0 ? s / Double(n) : 255
        }
        /// The toolbar is on screen in front: visible, and composited above the moving page and the overview.
        func toolbarOnTop() -> Bool {
            let tb = app.container.toolbar
            guard !tb.isHidden, tb.alphaValue > 0.8 else { return false }
            let subs = app.container.subviews
            func rank(_ v: NSView?) -> (CGFloat, Int) { guard let v, let i = subs.firstIndex(of: v) else { return (-1, -1) }; return (v.layer?.zPosition ?? 0, i) }
            let t = rank(tb)
            var others: [NSView] = []
            if let tv = app.transitionView { others.append(tv) }
            if app.galleryShown, let g = app.gallery { others.append(g) }
            for o in others {
                let r = rank(o)
                if t.0 < r.0 || (t.0 == r.0 && t.1 < r.1) { return false }
            }
            return true
        }
        /// Transition views in the window (plain NSViews: every other view there has its own class).
        func transitionViews() -> Int { app.container.subviews.filter { type(of: $0) == NSView.self }.count }

        if canvas.drawMode { app.exitDrawMode("test") }
        canvas.clearPage()
        while canvas.pages.count < 8 { canvas.newPage() }
        // Every page has its own ink: rows of wavy lines at a different height and length per page.
        for p in 0..<8 {
            canvas.goToPage(p)
            for row in 0..<(3 + p % 4) {
                let y0 = 900.0 - Double(row) * 60 - Double(p) * 20, x0 = 80.0 + Double(p % 3) * 120
                let dx: Double = 9 + Double(p)
                var pts: [StrokePoint] = []
                for j in 0..<80 { let x: Double = x0 + Double(j) * dx, y: Double = y0 + sin(Double(j) / 2.5) * 14; pts.append(StrokePoint(p: CGPoint(x: x, y: y), pressure: 0.7)) }
                canvas.testAddStroke(pts)
            }
        }
        // TRACKPAD_DRAW_TEST_IMAGES: pages 2 and 5 have a picture under their ink (page 5: a tall one, tiled at 370%).
        if ProcessInfo.processInfo.environment["TRACKPAD_DRAW_TEST_IMAGES"] != nil {
            for (p, w, h, hue) in [(1, 1600, 1000, 0.08), (4, 4000, 9000, 0.55)] {
                if let a = try? ImageStore.importImage(TestImages.encode(TestImages.card(w, h, hue: hue), .png)) { canvas.testPlaceImage(a, page: p) }
            }
        }
        // Page 5 (index 4) is saved at 370%, on its ink.
        canvas.goToPage(4)
        canvas.setVisibleForReplay(x: 300, y: 700, w: canvas.camera.page.width / 3.7, z: 3.7)
        // Page 7 (index 6) at 300%: never opened again this session before the loop opens it.
        canvas.goToPage(6)
        canvas.setVisibleForReplay(x: 500, y: 620, w: canvas.camera.page.width / 3, z: 3)
        canvas.goToPage(0)
        spin(0.5)

        var out: [[String: Any]] = []
        /// Where things are heading: the overview (true) or a page; a running transition counts as its end.
        func target() -> Bool { app.transitionView != nil ? (app.lastTransition["kind"] as? String) != "open" : app.galleryShown }
        var shown = target(), presses = 0, changes = 0, maxViews = 0
        // With TRACKPAD_DRAW_SLOW_TRANSITION (2 s) the calm loop waits for each transition to end, so its first and last
        // frames are close to its ends (the comparisons); at normal speed the gaps are his (0.25-0.6 s).
        let slow = AppDelegate.transitionSeconds > 1
        /// One G press; the transition it starts is sampled frame by frame until it ends (or the next press comes).
        func press(tile: Int?, nextIn: Double) {
            let before = target(), page = canvas.pageIndex   // heading to the overview: this press opens a page
            if let t = tile { hover(cell: t) }
            key("g", 5); presses += 1
            let opening = before
            var rec: [String: Any] = ["opening": opening, "tile": tile ?? -1, "pageBefore": page]
            // The first frame, right as the press is handled.
            if app.transitionView != nil {
                let first = transitionImage()
                // Against the overview's own drawing of that same area: what was on screen there before the press.
                if opening, let tv = app.transitionView { rec["firstVsTile"] = diff(first, regionImage(tv.frame)) }
                rec["toolbarOnTopFirst"] = toolbarOnTop()
            }
            var last: [UInt8] = [], lastToolbar = true, maxUp = 0.0, midShot: String? = nil
            let t0 = Date()
            while Date().timeIntervalSince(t0) < nextIn {
                maxViews = max(maxViews, transitionViews())
                if let tv = app.transitionView {
                    last = transitionImage(); lastToolbar = toolbarOnTop(); maxUp = max(maxUp, upscale())
                    // Mid-way through a slow opening (the moving page 40-60% of the window's width): a real screenshot.
                    let f = tv.frame.width / max(canvas.frame.width, 1)
                    if slow, opening, midShot == nil, f > 0.4, f < 0.6 { midShot = "mid-\(out.count)"; shot(midShot!, rect: tv.frame) }
                }
                spin(0.004)
            }
            rec["maxUpscale"] = maxUp
            if let m = midShot, app.transitionView == nil {
                spin(0.3)   // the page drawn by the canvas itself
                shot("end-\(out.count)", rect: canvas.frame); rec["midShot"] = m; rec["endShot"] = "end-\(out.count)"
            }
            rec["toolbarOnTopLast"] = lastToolbar
            let after = app.galleryShown, aim = target()
            if aim != shown { changes += 1; shown = aim }
            rec["shownAfter"] = after; rec["pageAfter"] = canvas.pageIndex; rec["settled"] = app.transitionView == nil
            if app.transitionView == nil && !last.isEmpty {
                // The transition ended inside this window: its last frame against what is now really there.
                if opening { rec["lastVsPage"] = diff(last, pageImage()) } else { rec["lastVsTile"] = diff(last, tileImage(canvas.pageIndex)) }
            }
            out.append(rec)
        }
        // Calm loop: 0.3 s (his fastest, 30 Oct 19:54) and 0.6 s between presses, through pages 2, 5 (370%), 3, 5, 7, 1.
        for (t, gap) in [(1, 0.6), (4, 0.6), (2, 0.3), (6, 0.3), (3, 0.3), (4, 0.6), (0, 0.6)] {
            let g = slow ? AppDelegate.transitionSeconds + 0.4 : gap
            press(tile: nil, nextIn: g)            // G: back to the overview
            press(tile: t, nextIn: g)              // pointer on a tile, G: open it
        }
        let calm = out.count
        // Faster than a transition (0.12 s): each press still makes exactly one change, nothing stacks.
        let presses0 = presses, changes0 = changes
        for t in [3, 4, 5, 4] { press(tile: nil, nextIn: 0.12); press(tile: t, nextIn: 0.12) }
        spin(slow ? 2.5 : 0.6)
        let r: [String: Any] = ["transitions": out, "calmCount": calm, "fastPresses": presses - presses0, "fastChanges": changes - changes0,
                                "maxTransitionViews": maxViews, "endShown": app.galleryShown, "endSettled": app.transitionView == nil]
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-galleryflow.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
