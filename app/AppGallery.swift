// The page overview (Gallery.swift) wired into the window: G / toolbar button / View › Pages, draw mode,
// and the grow / shrink transition between a grid cell and the canvas.
import AppKit

extension AppDelegate {
    var galleryShown: Bool { gallery.map { !$0.isHidden } ?? false }

    func toggleGallery() { galleryShown ? openPage(canvas.pageIndex) : showGallery() }

    /// The canvas shrinks into the current page's cell; the grid shows every page.
    func showGallery() {
        tips.openedOverview(); practiceTick(.overview)
        guard !galleryShown, transitionView == nil else { return }
        var ms: [String: Double] = [:]; var tl = CACurrentMediaTime()
        func lap(_ k: String) { let n = CACurrentMediaTime(); ms[k] = (n - tl) * 1000; tl = n }
        canvas.renderingPaused = true   // covered by the overview from now on
        galleryReturnsToDraw = canvas.drawMode
        exitDrawMode("gallery"); lap("exitDraw")
        container.toolbar.hidePanel()
        let g = gallery ?? {
            let g = GalleryView(frame: container.bounds)
            g.autoresizingMask = [.width, .height]
            g.onOpen = { [weak self] i in self?.openPage(i) }
            g.onNewPage = { [weak self] in self?.openNewPage() }
            g.onSearchReturn = { [weak self] in self?.openSelectedTile() }
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
        let from = canvas.frame
        let img = canvasSnapshot(); lap("snapshot")
        transition(kind: "close", page: canvas.pageIndex, image: img, from: from, to: to) {}
        lastTransition["stepsMs"] = ms
    }

    /// Return / Space in the overview: open the selected tile (a page, or "+ New page").
    func openSelectedTile() {
        guard let g = gallery, galleryShown else { return }
        if g.selected >= 0 && g.selected < canvas.pages.count { openPage(g.selected) } else if g.selected == canvas.pages.count { openNewPage() }
    }

    /// Page i grows from its cell to the full canvas.
    func openPage(_ i: Int) {
        guard let g = gallery, galleryShown, transitionView == nil, canvas.pages.indices.contains(i) else { return }
        let from = g.cellRect(i, in: container)
        canvas.goToPage(i)
        updateBanner()
        finishOpening(page: i, from: from)
    }

    /// The "New page" tile: a page is added after the last one and grows from that tile.
    func openNewPage() {
        guard let g = gallery, galleryShown, transitionView == nil else { return }
        let from = g.cellRect(canvas.pages.count, in: container)
        canvas.newPage()
        updateBanner()
        finishOpening(page: canvas.pageIndex, from: from)
    }

    private func finishOpening(page i: Int, from: CGRect) {
        transition(kind: "open", page: i, image: canvasSnapshot(), from: from, to: canvas.frame) { [weak self] in
            guard let self else { return }
            self.canvas.renderingPaused = false   // renders the opened page under the transition's last frame
            self.gallery?.isHidden = true
            self.window.makeFirstResponder(self.canvas)
            if self.galleryReturnsToDraw { self.enterDrawMode(lock: !self.canvas.testMode) }
        }
    }

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

    /// Short, and easing out: it moves most right after the click, so it feels immediate.
    static var transitionSeconds: Double { ProcessInfo.processInfo.environment["TRACKPAD_DRAW_SLOW_TRANSITION"] != nil ? 2.0 : 0.22 }

    /// An image of the page animates between the two rects (container coordinates), then goes away.
    private func transition(kind: String, page: Int, image: CGImage?, from: CGRect, to: CGRect, then: @escaping () -> Void) {
        // A plain layer with the image as its contents: no NSImage conversion or redraw on the main thread.
        let tv = NSView(frame: from)
        tv.wantsLayer = true
        tv.layer?.contents = image; tv.layer?.contentsGravity = .resize
        tv.layer?.cornerRadius = 6; tv.layer?.masksToBounds = true
        container.addSubview(tv)
        transitionView = tv
        lastTransition = ["kind": kind, "page": page, "from": [from.minX, from.minY, from.width, from.height], "to": [to.minX, to.minY, to.width, to.height],
                          "startFrame": [tv.frame.minX, tv.frame.minY, tv.frame.width, tv.frame.height]]
        // Driven by a run-loop timer (common modes), not Core Animation: it runs the same in a hidden or
        // background window, and every intermediate frame is a plain, inspectable view frame.
        let start = CACurrentMediaTime(), dur = Self.transitionSeconds
        let inputAt = TransitionTiming.inputAt; TransitionTiming.inputAt = nil
        if let i = inputAt { lastTransition["inputToStartMs"] = (start - i) * 1000 }
        lastTransition["durationS"] = dur
        // Not coalesced or throttled while it runs (e.g. when the system is saving power).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "page transition")
        // The clock starts one frame back so the first step is applied right now, not at the first timer tick.
        let t0 = start - 1.0 / 120
        var first = true, lastFrame = CACurrentMediaTime(), maxGap = 0.0, gaps: [Double] = []
        func step(_ unused: Timer?) {
            let now = CACurrentMediaTime(); maxGap = max(maxGap, now - lastFrame); gaps.append((now - lastFrame) * 1000); lastFrame = now
            let u = min((CACurrentMediaTime() - t0) / dur, 1)
            let e = 1 - pow(1 - u, 3)   // ease out (cubic): most of the movement right after the click
            tv.frame = CGRect(x: from.minX + (to.minX - from.minX) * e, y: from.minY + (to.minY - from.minY) * e,
                              width: from.width + (to.width - from.width) * e, height: from.height + (to.height - from.height) * e)
            if first {
                first = false
                if let i = inputAt { lastTransition["inputToFirstFrameMs"] = (CACurrentMediaTime() - i) * 1000 }
                lastTransition["firstFrameProgress"] = e   // how far the first frame moved (0...1)
            }
            guard u >= 1 else { return }
            TransitionDriver.stop()
            ProcessInfo.processInfo.endActivity(activity)
            lastTransition["endFrame"] = [tv.frame.minX, tv.frame.minY, tv.frame.width, tv.frame.height]
            lastTransition["totalMs"] = (now - start) * 1000; lastTransition["maxFrameGapMs"] = maxGap * 1000; lastTransition["gapsMs"] = gaps.map { ($0 * 10).rounded() / 10 }
            tv.removeFromSuperview()
            transitionView = nil
            then()
        }
        step(nil)
        // Paced by the window's display link (one step per screen refresh), not a timer: macOS throttles
        // timers of apps whose windows are behind others (measured: one step every ~40 ms).
        TransitionDriver.start(on: container) { step(nil) }
    }

    @objc func toggleGalleryAction() { toggleGallery() }

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
        showToast("Page \(actionPageIndex + 1) copied as an image")
    }
    @objc func sharePageAction() {
        exitDrawMode("share")
        guard let url = pagePNG(actionPageIndex) else { return }
        let picker = NSSharingServicePicker(items: [url])
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
