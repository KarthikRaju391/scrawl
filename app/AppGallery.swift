// The page overview (Gallery.swift) wired into the window: G / toolbar button / View › Pages, draw mode,
// and the grow / shrink transition between a grid cell and the canvas.
import AppKit

extension AppDelegate {
    var galleryShown: Bool { gallery.map { !$0.isHidden } ?? false }

    func toggleGallery() { galleryShown ? openPage(canvas.pageIndex) : showGallery() }

    /// The canvas shrinks into the current page's cell; the grid shows every page.
    func showGallery() {
        guard !galleryShown, transitionView == nil else { return }
        galleryReturnsToDraw = canvas.drawMode
        exitDrawMode("gallery")
        container.toolbar.hidePanel()
        let g = gallery ?? {
            let g = GalleryView(frame: container.bounds)
            g.autoresizingMask = [.width, .height]
            g.onOpen = { [weak self] i in self?.openPage(i) }
            g.onNewPage = { [weak self] in self?.openNewPage() }
            container.addSubview(g)
            gallery = g
            return g
        }()
        g.frame = container.bounds
        g.reload(pages: canvas.pages, pageSize: canvas.camera.page, current: canvas.pageIndex)
        g.isHidden = false
        let from = canvas.frame, to = g.cellRect(canvas.pageIndex, in: container)
        transition(kind: "close", page: canvas.pageIndex, image: viewImage(of: canvas.pageIndex), from: from, to: to) {}
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
        transition(kind: "open", page: i, image: viewImage(of: i), from: from, to: canvas.frame) { [weak self] in
            guard let self else { return }
            self.gallery?.isHidden = true
            if self.galleryReturnsToDraw { self.enterDrawMode(lock: !self.canvas.testMode) }
        }
    }

    /// What the canvas shows for page i (its saved view), rendered on the CPU for the transition.
    func viewImage(of i: Int) -> NSImage? {
        let cam = canvas.cameraForPage(i), rr = canvas.renderRect(for: cam)
        let scale = window.backingScaleFactor
        guard let cg = PageImage.render(canvas.pages[i], rect: rr, pageWidth: cam.page.width, pageTop: cam.page.height,
                                        px: CGSize(width: canvas.bounds.width * scale, height: canvas.bounds.height * scale),
                                        background: canvas.tools.background) else { return nil }
        return NSImage(cgImage: cg, size: canvas.bounds.size)
    }

    static var transitionSeconds: Double { ProcessInfo.processInfo.environment["TRACKPAD_DRAW_SLOW_TRANSITION"] != nil ? 2.0 : 0.3 }

    /// An image of the page animates between the two rects (container coordinates), then goes away.
    private func transition(kind: String, page: Int, image: NSImage?, from: CGRect, to: CGRect, then: @escaping () -> Void) {
        let tv = NSImageView(frame: from)
        tv.image = image; tv.imageScaling = .scaleAxesIndependently
        tv.wantsLayer = true; tv.layer?.cornerRadius = 6; tv.layer?.masksToBounds = true
        container.addSubview(tv)
        transitionView = tv
        lastTransition = ["kind": kind, "page": page, "from": [from.minX, from.minY, from.width, from.height], "to": [to.minX, to.minY, to.width, to.height],
                          "startFrame": [tv.frame.minX, tv.frame.minY, tv.frame.width, tv.frame.height]]
        // Driven by a run-loop timer (common modes), not Core Animation: it runs the same in a hidden or
        // background window, and every intermediate frame is a plain, inspectable view frame.
        let t0 = CACurrentMediaTime(), dur = Self.transitionSeconds
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let u = min((CACurrentMediaTime() - t0) / dur, 1)
            let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2   // ease in-out
            tv.frame = CGRect(x: from.minX + (to.minX - from.minX) * e, y: from.minY + (to.minY - from.minY) * e,
                              width: from.width + (to.width - from.width) * e, height: from.height + (to.height - from.height) * e)
            guard u >= 1 else { return }
            timer.invalidate()
            self.lastTransition["endFrame"] = [tv.frame.minX, tv.frame.minY, tv.frame.width, tv.frame.height]
            tv.removeFromSuperview()
            self.transitionView = nil
            then()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func toggleGalleryAction() { toggleGallery() }
}
