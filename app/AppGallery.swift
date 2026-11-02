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
        let img = canvasSnapshot(); lap("snapshot")
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
        transition(kind: "close", page: canvas.pageIndex, snapshot: img, cell: to) {}
        // Commit the grid and the page's picture over it together, now, before the next frame (flushed before the
        // picture was added, one frame could show the overview alone, then the page again: a flash).
        CATransaction.flush(); lap("flush")
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
        let from = g.cellRectAsShown(i, in: container)   // where it is now: no scroll at the moment of opening
        canvas.goToPage(i)
        updateBanner()
        finishOpening(page: i, from: from)
    }

    /// The "New page" tile (first in the overview): a page is added after the last one and grows from that tile.
    func openNewPage() {
        finishTransitionNow()
        guard let g = gallery, galleryShown, transitionView == nil else { return }
        let from = g.cellRectAsShown(canvas.pages.count, in: container)
        canvas.newPage()
        updateBanner()
        finishOpening(page: canvas.pageIndex, from: from)
    }

    private func finishOpening(page i: Int, from: CGRect) {
        transition(kind: "open", page: i, snapshot: canvasSnapshot(), cell: from) { [weak self] in
            guard let self else { return }
            self.gallery?.isHidden = true
            self.logGallery("galleryHidden", ["page": i])
            self.window.makeFirstResponder(self.canvas)
            if self.galleryReturnsToDraw { self.enterDrawMode(lock: !self.canvas.testMode) }
        }
    }

    /// A G (or a click) while a transition still runs: that one ends now, then the new one starts from where things
    /// really are (Karthik presses G as fast as every 0.25 s; transitions never stack).
    func finishTransitionNow() { transitionFinish?() }

    /// What the canvas shows now (the page being opened has already been switched to): a GPU snapshot at the screen's
    /// resolution, so the transition's last frame is the page exactly as the canvas then draws it (at point resolution
    /// it was soft, then snapped sharp).
    func canvasSnapshot() -> Any? { canvas.snapshotSurface() ?? canvas.snapshot() }

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

    /// The page grows from its tile to the full window (or shrinks back) as one continuous move, and no picture is
    /// ever shown larger than it was rendered (Karthik, 30 Oct: a different page opened through a blurry, upscaled
    /// image that then snapped sharp). The page's view is rendered at the screen's resolution and only ever shrinks
    /// from full size; it fades in over the first quarter of opening, over the overview's own tile (which is what the
    /// first frame shows), and fades out over the last quarter of closing, uncovering that tile (the last frame).
    /// The toolbar and header stay above it and fade in (open) or out (close).
    /// System Settings › Accessibility › Display › Reduce motion: the page fades in and out at full size instead of
    /// growing from its tile (tests can force it).
    nonisolated(unsafe) static var reduceMotionForTest: Bool?
    static var reduceMotion: Bool { reduceMotionForTest ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func transition(kind: String, page: Int, snapshot: Any?, cell tile: CGRect, then: @escaping () -> Void) {
        let opening = kind == "open", full = canvas.frame, still = Self.reduceMotion
        let cell = still ? full : tile
        let from = opening ? cell : full, to = opening ? full : cell
        let tv = NSView(frame: from)
        tv.wantsLayer = true
        let root = tv.layer!
        root.masksToBounds = true; root.zPosition = 50
        let snapLayer = CALayer()
        snapLayer.contents = snapshot; snapLayer.contentsGravity = .resizeAspectFill; snapLayer.masksToBounds = true
        snapLayer.contentsScale = window.backingScaleFactor
        root.addSublayer(snapLayer)
        container.addSubview(tv)
        transitionView = tv
        // The toolbar and header: above the moving page, fading with it (never a frame without them).
        let chrome: [NSView] = [container.toolbar, container.hint, container.capsule, container.zoomBadge, container.pageMap].filter { !$0.isHidden }
        for c in chrome { c.wantsLayer = true; c.layer?.zPosition = 60 }
        func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        func apply(_ p: Double) {   // p: 0 = the tile, 1 = the full page
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(p) }
            let clip = CGRect(x: mix(cell.minX, full.minX), y: mix(cell.minY, full.minY), width: mix(cell.width, full.width), height: mix(cell.height, full.height))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            tv.frame = clip
            root.cornerRadius = 6 * (1 - CGFloat(p))
            snapLayer.frame = CGRect(origin: .zero, size: clip.size)
            snapLayer.opacity = Float(still ? p : smooth(p, 0, 0.25))   // opaque from a quarter of the way: no overview seen through the page
            CATransaction.commit()
            let a = CGFloat(smooth(p, 0.5, 1))
            for c in chrome { c.alphaValue = a }
        }
        lastTransition = ["kind": kind, "page": page, "reduceMotion": still, "from": [from.minX, from.minY, from.width, from.height], "to": [to.minX, to.minY, to.width, to.height],
                          "startFrame": [tv.frame.minX, tv.frame.minY, tv.frame.width, tv.frame.height]]
        // Driven by the display link (one step per screen refresh), not Core Animation: it runs the same in a hidden or
        // background window, and every intermediate frame is a plain, inspectable view frame.
        let start = CACurrentMediaTime(), dur = Self.transitionSeconds
        let inputAt = TransitionTiming.inputAt; TransitionTiming.inputAt = nil
        if let i = inputAt { lastTransition["inputToStartMs"] = (start - i) * 1000 }
        lastTransition["durationS"] = dur
        // Not coalesced or throttled while it runs (e.g. when the system is saving power).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "page transition")
        // The first step is applied right now, one frame's worth in; the clock then runs from the first display tick
        // (the overview's grid can take 10-40 ms to reach the screen first: counted in, that ate half the move and the
        // page jumped from full size to 60% in one frame).
        var t0: Double? = nil
        var first = true, done = false, lastFrame = CACurrentMediaTime(), maxGap = 0.0, gaps: [Double] = []
        func step(force: Bool, tick: Bool = true) {
            guard !done else { return }
            let now = CACurrentMediaTime()
            // Gaps between animation frames on screen: from the first display tick on (before it, the overview's grid
            // reaches the screen with the first frame, and the clock doesn't run).
            if t0 != nil { maxGap = max(maxGap, now - lastFrame); gaps.append((now - lastFrame) * 1000) }
            lastFrame = now
            if tick, t0 == nil { t0 = now - 1.0 / 120 }
            let u = force ? 1 : t0.map { min((now - $0) / dur, 1) } ?? (1.0 / 120) / dur
            let e = 1 - pow(1 - u, 2)   // ease out (quadratic): immediate, but no big jump in the first frames
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
            // Opening: the canvas draws the opened page now, in the same screen update that removes the picture and
            // hides the overview (it still held the page it drew before; for a frame or two that page flashed).
            if opening { canvas.drawNowWithTransaction() }
            tv.removeFromSuperview()
            transitionView = nil; transitionFinish = nil
            then()
        }
        transitionFinish = { step(force: true) }
        step(force: false, tick: false)
        // Paced by the window's display link (one step per screen refresh), not a timer: macOS throttles
        // timers of apps whose windows are behind others (measured: one step every ~40 ms).
        TransitionDriver.start(on: container) { step(force: false) }
    }

    @objc func toggleGalleryAction() { toggleGallery() }

    // MARK: deleting pages (no confirm dialog: ⌘Z brings a page back)

    func deletePage(_ i: Int) {
        let shownAt = galleryShown ? gallery?.position(of: i) : nil   // the tile that takes its place gets the highlight
        guard let d = canvas.deletePage(i) else { return }
        deletedPages.append(d)
        usage.record("delete_page", ["pages": canvas.pages.count])
        afterPagesChanged(select: min(i, canvas.pages.count - 1), position: shownAt)
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
    /// `select`: a page to highlight in the overview, or `position`: the tile position to highlight (after a delete,
    /// the page that moved into the deleted tile's place; never the New page tile while there are pages).
    private func afterPagesChanged(select: Int, position: Int? = nil) {
        updateBanner(); updateUndoState()
        container.pageMap.refresh(); container.needsLayout = true
        if galleryShown, let g = gallery {
            g.reload(pages: canvas.pages, pageSize: canvas.camera.page, current: canvas.pageIndex)
            if let p = position { g.select(position: min(max(p, 1), g.cellCount - 1)) } else { g.selected = select }
            g.moveSelection(dx: 0, dy: 0)
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
        if textFocused { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self); return }   // ⌘C in a text field: its text
        if canvas.selection != nil && !galleryShown { copySelectionAction(); return }   // ⌘C with a selection: the selection
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
