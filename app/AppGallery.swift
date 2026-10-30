// The page overview (Gallery.swift) wired into the window: G / toolbar button / View › Pages, draw mode,
// and the grow / shrink transition between a grid cell and the canvas.
import AppKit

extension AppDelegate {
    var galleryShown: Bool { gallery.map { !$0.isHidden } ?? false }

    func toggleGallery() { finishTransitionNow(); galleryShown ? openPage(canvas.pageIndex) : showGallery() }

    /// The session log: what made the overview show or a page open (the input event, if any, and who called).
    func logGallery(_ what: String, _ extra: [String: Any] = [:]) {
        var d = extra
        d["shown"] = galleryShown; d["inTransition"] = transitionView != nil
        if let e = NSApp.currentEvent {
            d["event"] = "\(e.type.rawValue)"
            switch e.type {
            case .keyDown, .keyUp: d["key"] = e.charactersIgnoringModifiers ?? ""; d["repeat"] = e.isARepeat
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown: d["clicks"] = e.clickCount; d["pressure"] = Double(e.pressure)
                let p = container.convert(e.locationInWindow, from: nil); d["at"] = [Int(p.x), Int(p.y)]
            default: break
            }
            d["eventAge"] = Int((ProcessInfo.processInfo.systemUptime - e.timestamp) * 1000)
        }
        canvas.act(what, d)
    }

    /// The canvas shrinks into the current page's cell; the grid shows every page.
    func showGallery() {
        finishTransitionNow()
        logGallery("galleryShow")
        tips.openedOverview(); practiceTick(.overview); usage.record("overview", ["pages": canvas.pages.count])
        guard !galleryShown, transitionView == nil else { return }
        var ms: [String: Double] = [:]; var tl = CACurrentMediaTime()
        func lap(_ k: String) { let n = CACurrentMediaTime(); ms[k] = (n - tl) * 1000; tl = n }
        // The tile it lands on shows this page's thumbnail as it is now (rendered here if the page changed), so the
        // transition ends on exactly the image the tile keeps.
        _ = ThumbnailCache.shared.image(for: canvas.doc, page: canvas.camera.page); lap("thumbnail")
        let shown = canvas.renderRect, img = canvasSnapshot(); lap("snapshot")
        canvas.renderingPaused = true   // covered by the overview from now on
        galleryReturnsToDraw = canvas.drawMode
        exitDrawMode("gallery"); lap("exitDraw")
        container.toolbar.hidePanel()
        let g = gallery ?? {
            let g = GalleryView(frame: container.bounds)
            g.autoresizingMask = [.width, .height]
            g.onOpen = { [weak self] i in self?.openPage(i) }
            g.onNewPage = { [weak self] in self?.openNewPage() }
            g.onDelete = { [weak self] i in self?.deletePage(i) }
            g.onSearchReturn = { [weak self] in
                self?.usage.record("overview_search", ["result": (self?.gallery?.matching.isEmpty ?? true) ? "none" : "found"])
                self?.openSelectedTile()
            }
            container.addSubview(g)
            gallery = g
            return g
        }()
        g.frame = container.bounds
        g.reload(pages: canvas.pages, pageSize: canvas.camera.page, current: canvas.pageIndex); lap("reload")
        g.isHidden = false
        window.acceptsMouseMovedEvents = true; window.makeFirstResponder(g)   // hover moves the highlight
        let to = g.cellRect(canvas.pageIndex, in: container); lap("cellRect")
        g.display(); lap("display")
        CATransaction.flush(); lap("flush")   // draw and commit the grid now, before the first frame, not during the animation
        transition(kind: "close", page: canvas.pageIndex, snapshot: img, shows: shown, cell: to) {}
        lastTransition["stepsMs"] = ms
    }

    /// Return / Space in the overview: open the selected tile (a page, or "+ New page").
    func openSelectedTile() {
        finishTransitionNow()
        guard let g = gallery, galleryShown else { return }
        if g.selected >= 0 && g.selected < canvas.pages.count { openPage(g.selected) } else if g.selected == canvas.pages.count { openNewPage() }
    }

    /// Page i grows from its cell to the full canvas.
    func openPage(_ i: Int) {
        finishTransitionNow()
        logGallery("galleryOpenPage", ["page": i])
        guard let g = gallery, galleryShown, transitionView == nil, canvas.pages.indices.contains(i) else { return }
        let from = g.cellRect(i, in: container)
        canvas.goToPage(i)
        updateBanner()
        finishOpening(page: i, from: from)
    }

    /// The "New page" tile: a page is added after the last one and grows from that tile.
    func openNewPage() {
        finishTransitionNow()
        guard let g = gallery, galleryShown, transitionView == nil else { return }
        let from = g.cellRect(canvas.pages.count, in: container)
        canvas.newPage()
        updateBanner()
        finishOpening(page: canvas.pageIndex, from: from)
    }

    private func finishOpening(page i: Int, from: CGRect) {
        transition(kind: "open", page: i, snapshot: canvasSnapshot(), shows: canvas.renderRect, cell: from) { [weak self] in
            guard let self else { return }
            self.canvas.renderingPaused = false   // renders the opened page under the transition's last frame
            self.gallery?.isHidden = true
            self.logGallery("galleryHidden", ["page": i])
            self.window.makeFirstResponder(self.canvas)
            if self.galleryReturnsToDraw { self.enterDrawMode(lock: !self.canvas.testMode) }
        }
    }

    /// A G (or a click) while a transition still runs: that one ends now, then the new one starts from where things
    /// really are (Karthik presses G as fast as every 0.25 s; transitions never stack).
    func finishTransitionNow() { transitionFinish?() }

    /// What the canvas shows now (the page being opened has already been switched to): a GPU snapshot.
    /// At point resolution: it's on screen for 0.22 s, then the canvas itself takes over.
    func canvasSnapshot() -> CGImage? { canvas.snapshot(scale: 1) }

    /// What the canvas shows for page i (its saved view), rendered on the CPU (slow; kept for comparison).
    func viewImage(of i: Int) -> NSImage? {
        let cam = canvas.cameraForPage(i), rr = canvas.renderRect(for: cam)
        let scale = window.backingScaleFactor
        guard let cg = PageImage.render(canvas.pages[i], rect: rr, pageWidth: cam.page.width, pageTop: cam.page.height,
                                        px: CGSize(width: canvas.bounds.width * scale, height: canvas.bounds.height * scale),
                                        background: canvas.tools.background) else { return nil }
        return NSImage(cgImage: cg, size: canvas.bounds.size)
    }

    /// Short, and easing out: it moves most right after the press, so it feels immediate.
    static var transitionSeconds: Double { ProcessInfo.processInfo.environment["TRACKPAD_DRAW_SLOW_TRANSITION"] != nil ? 2.0 : 0.24 }

    /// The page zooms between its tile and the full window as one continuous move (Karthik, 30 Oct: the content
    /// jumped, the tile flashed a different image, and the toolbar went missing for a frame).
    /// One mapping takes the page from "the part the tile shows, filling the tile" to "the part the page's view
    /// shows, filling the window"; the tile's own thumbnail and a snapshot of the view ride on it and crossfade,
    /// so the first frame is exactly the tile and the last exactly the page (and the reverse when closing).
    /// The toolbar and header stay above it and fade in (open) or out (close).
    private func transition(kind: String, page: Int, snapshot: CGImage?, shows view: CGRect, cell: CGRect, then: @escaping () -> Void) {
        let opening = kind == "open", full = canvas.frame
        let doc = canvas.pages.indices.contains(page) ? canvas.pages[page] : canvas.doc
        let thumb = ThumbnailCache.shared.cachedWithRegion(doc)
        let region = thumb?.region ?? ThumbnailCache.region([], page: canvas.camera.page)
        let from = opening ? cell : full, to = opening ? full : cell
        // The page's view and the tile's region have the window's and the tile's shapes; the mapping keeps one scale.
        let k0 = cell.width / max(region.width, 1e-6), k1 = full.width / max(view.width, 1e-6)
        func mapping(_ p: Double) -> (scale: Double, anchorPage: CGPoint, anchorView: CGPoint, clip: CGRect) {
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
            let k = exp(mix(log(k0), log(k1)))
            let ap = CGPoint(x: mix(region.midX, view.midX), y: mix(region.midY, view.midY))
            let av = CGPoint(x: mix(cell.midX, full.midX), y: mix(cell.midY, full.midY))
            let clip = CGRect(x: mix(cell.minX, full.minX), y: mix(cell.minY, full.minY), width: mix(cell.width, full.width), height: mix(cell.height, full.height))
            return (k, ap, av, clip)
        }
        let tv = NSView(frame: from)
        tv.wantsLayer = true
        let root = tv.layer!
        root.backgroundColor = NSColor.white.cgColor; root.masksToBounds = true; root.zPosition = 50
        let thumbLayer = CALayer(), snapLayer = CALayer()
        for l in [thumbLayer, snapLayer] { l.contentsGravity = .resize; l.anchorPoint = .zero; root.addSublayer(l) }
        thumbLayer.contents = thumb?.image; snapLayer.contents = snapshot
        container.addSubview(tv)
        transitionView = tv
        // The toolbar and header: above the moving page, fading with it (never a frame without them).
        let chrome: [NSView] = [container.toolbar, container.hint, container.capsule, container.zoomBadge, container.pageMap].filter { !$0.isHidden }
        for c in chrome { c.wantsLayer = true; c.layer?.zPosition = 60 }
        func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        func apply(_ p: Double) {
            let m = mapping(p)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            tv.frame = m.clip
            root.cornerRadius = 6 * (1 - p)
            for (l, q) in [(thumbLayer, region), (snapLayer, view)] {
                let x = m.anchorView.x + (q.minX - m.anchorPage.x) * m.scale - m.clip.minX
                let y = m.anchorView.y + (q.minY - m.anchorPage.y) * m.scale - m.clip.minY
                l.frame = CGRect(x: x, y: y, width: q.width * m.scale, height: q.height * m.scale)
            }
            snapLayer.opacity = Float(smooth(p, 0.35, 0.9))
            CATransaction.commit()
            let a = CGFloat(smooth(p, 0.5, 1))
            for c in chrome { c.alphaValue = a }
        }
        lastTransition = ["kind": kind, "page": page, "from": [from.minX, from.minY, from.width, from.height], "to": [to.minX, to.minY, to.width, to.height],
                          "startFrame": [tv.frame.minX, tv.frame.minY, tv.frame.width, tv.frame.height]]
        // Driven by the display link (one step per screen refresh), not Core Animation: it runs the same in a hidden or
        // background window, and every intermediate frame is a plain, inspectable view frame.
        let start = CACurrentMediaTime(), dur = Self.transitionSeconds
        let inputAt = TransitionTiming.inputAt; TransitionTiming.inputAt = nil
        if let i = inputAt { lastTransition["inputToStartMs"] = (start - i) * 1000 }
        lastTransition["durationS"] = dur
        // Not coalesced or throttled while it runs (e.g. when the system is saving power).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "page transition")
        // The clock starts one frame back so the first step is applied right now, not at the first timer tick.
        let t0 = start - 1.0 / 120
        var first = true, done = false, lastFrame = CACurrentMediaTime(), maxGap = 0.0, gaps: [Double] = []
        func step(force: Bool) {
            guard !done else { return }
            let now = CACurrentMediaTime(); maxGap = max(maxGap, now - lastFrame); gaps.append((now - lastFrame) * 1000); lastFrame = now
            let u = force ? 1 : min((now - t0) / dur, 1)
            let e = 1 - pow(1 - u, 3)   // ease out (cubic): most of the movement right after the press
            apply(opening ? e : 1 - e)
            if first {
                first = false
                if let i = inputAt { lastTransition["inputToFirstFrameMs"] = (CACurrentMediaTime() - i) * 1000 }
                lastTransition["firstFrameProgress"] = e   // how far the first frame moved (0...1)
            }
            guard u >= 1 else { return }
            done = true
            TransitionDriver.stop()
            ProcessInfo.processInfo.endActivity(activity)
            lastTransition["endFrame"] = [tv.frame.minX, tv.frame.minY, tv.frame.width, tv.frame.height]
            lastTransition["totalMs"] = (now - start) * 1000; lastTransition["maxFrameGapMs"] = maxGap * 1000; lastTransition["gapsMs"] = gaps.map { ($0 * 10).rounded() / 10 }
            lastTransition["finishedEarly"] = force
            for c in chrome { c.layer?.zPosition = 0; c.alphaValue = 1 }
            tv.removeFromSuperview()
            transitionView = nil; transitionFinish = nil
            then()
        }
        transitionFinish = { step(force: true) }
        step(force: false)
        // Paced by the window's display link (one step per screen refresh), not a timer: macOS throttles
        // timers of apps whose windows are behind others (measured: one step every ~40 ms).
        TransitionDriver.start(on: container) { step(force: false) }
    }

    @objc func toggleGalleryAction() { toggleGallery() }

    // MARK: deleting pages (no confirm dialog: ⌘Z brings a page back)

    func deletePage(_ i: Int) {
        guard let d = canvas.deletePage(i) else { return }
        deletedPages.append(d)
        usage.record("delete_page", ["pages": canvas.pages.count])
        afterPagesChanged(select: min(i, canvas.pages.count - 1))
        showToast(d.blank != nil ? "Page deleted (a blank page stays) · ⌘Z to undo" : "Page \(i + 1) deleted · ⌘Z to undo", seconds: 3)
    }
    /// ⌘Z or the toolbar's undo right after deleting a page: put it back. False if there's nothing to restore.
    func undoPageDelete() -> Bool {
        guard let d = deletedPages.popLast() else { return false }
        canvas.restorePage(d)
        usage.record("restore_page")
        afterPagesChanged(select: min(d.index, canvas.pages.count - 1))
        showToast("Page \(min(d.index, canvas.pages.count - 1) + 1) restored")
        return true
    }
    private func afterPagesChanged(select: Int) {
        updateBanner(); updateUndoState()
        container.pageMap.refresh(); container.needsLayout = true
        if galleryShown, let g = gallery {
            g.reload(pages: canvas.pages, pageSize: canvas.camera.page, current: canvas.pageIndex)
            g.selected = select; g.moveSelection(dx: 0, dy: 0)
        }
    }
    @objc func deletePageAction() { deletePage(actionPageIndex) }
    /// Test hook: the tile's context menu, then its Delete Page item picked.
    func robotTileMenu(_ i: Int) -> [String: Any] {
        guard let g = gallery, galleryShown, let m = g.tileMenu(i) else { return ["error": "no menu"] }
        let items = m.items.map(\.title)
        if let d = m.items.first(where: { $0.title == "Delete Page" }), let a = d.action { NSApp.sendAction(a, to: d.target, from: d) }
        return ["items": items]
    }

    /// ⌘F: the overview with its search field focused.
    @objc func findInPagesAction() {
        if !galleryShown { showGallery() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.gallery?.focusSearch() }
    }
    /// The page ⌘C and Share act on: the overview's selection, or the open page.
    var actionPageIndex: Int { galleryShown ? min(max(gallery?.selected ?? canvas.pageIndex, 0), canvas.pages.count - 1) : canvas.pageIndex }
    /// The page as a PNG file in a temporary folder (for the pasteboard and Share).
    func pagePNG(_ i: Int) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Scrawl-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Scrawl page \(i + 1).png")
        return (try? canvas.exportPNG(to: url, page: i)) != nil ? url : nil
    }
    /// Tests copy to their own pasteboard, never the one you're using.
    static let pasteboard = Launch.testing ? NSPasteboard(name: NSPasteboard.Name("scrawl.test")) : NSPasteboard.general
    @objc func copyPageAction() {
        guard let url = pagePNG(actionPageIndex), let data = try? Data(contentsOf: url) else { return }
        let pb = Self.pasteboard
        pb.clearContents(); pb.setData(data, forType: .png)
        usage.record("copy_page")
        showToast("Page \(actionPageIndex + 1) copied as an image")
    }
    @objc func sharePageAction() {
        exitDrawMode("share")
        guard let url = pagePNG(actionPageIndex) else { return }
        let picker = NSSharingServicePicker(items: [url])
        usage.record("share")
        lastSharePicker = picker
        guard !Launch.background else { return }   // tests check the file, not the menu
        picker.show(relativeTo: CGRect(x: container.bounds.midX - 1, y: container.bounds.maxY - 40, width: 2, height: 2), of: container, preferredEdge: .minY)
    }
}

/// Calls a closure on every display refresh of a view's screen until stopped.
final class TransitionDriver: NSObject {
    nonisolated(unsafe) private static var current: TransitionDriver?
    private var link: CADisplayLink?
    private let onFrame: () -> Void
    private init(_ f: @escaping () -> Void) { onFrame = f }
    static func start(on view: NSView, _ f: @escaping () -> Void) {
        stop()
        let d = TransitionDriver(f)
        let l = view.displayLink(target: d, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        d.link = l; current = d
    }
    static func stop() { current?.link?.invalidate(); current = nil }
    @objc private func frame(_ l: CADisplayLink) { onFrame() }
}
