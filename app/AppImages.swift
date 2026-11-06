// Bringing pictures in, wired into the window. ⌘V, a drop on the page and File › Insert Image… (⇧⌘I) put the picture on
// the open page (Attachments.swift: then it can be moved and resized with the Select tool; ⌘Z takes it away). File ›
// New Page from Image… (⇧⌘N), a drop or paste in the pages overview, and the Inbox (the browser extension's snapshots)
// make a new page with the picture across it; ⌘Z right after takes that page away, like undoing a page delete.
import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
    /// Where pictures go: onto the open page (centred on a page point, or the view's centre), or each on a new page.
    enum ImageTarget { case page(CGPoint?), newPages }

    /// Store and decode the pictures in the background, then place them: on the open page (in the overview: new pages),
    /// or a page for each (the last one is opened).
    func importImages(_ requests: [ImagePageRequest], via: String, to target: ImageTarget = .newPages) {
        guard !requests.isEmpty else { showToast("No image to add"); return }
        // A large picture takes a moment to decode: say so if it isn't there at once.
        var done = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in if !done { self?.showToast(requests.count == 1 ? "Adding the image…" : "Adding \(requests.count) images…", seconds: 3) } }
        ImageStore.decodeQueue.async { [weak self] in
            let results = requests.map { r in Result { try ImagePages.prepare(r) } }
            DispatchQueue.main.async {
                done = true
                guard let self else { return }
                let ok = results.compactMap { try? $0.get() }
                let onPage: CGPoint??
                if case .page(let c) = target, !self.galleryShown { onPage = .some(c) } else { onPage = nil }
                if let c = onPage { self.insertImages(ok, center: c, via: via) }
                else { for (k, p) in ok.enumerated() { self.makeImagePage(p, open: k == ok.count - 1, via: via) } }
                if let e = results.compactMap({ r -> Error? in if case .failure(let e) = r { return e }; return nil }).first {
                    self.showToast(ok.isEmpty ? (e.localizedDescription) : "\(ok.count) added; \(results.count - ok.count) couldn't be read", seconds: 3)
                } else if onPage != nil {
                    self.showToast(ok.count == 1 ? "Picture added · drag to move, corners to resize · ⌘Z to undo" : "\(ok.count) pictures added · ⌘Z to undo", seconds: 2.5)
                } else {
                    self.showToast(ok.count == 1 ? "New page from \(ok[0].request.source.label) · ⌘Z to undo" : "\(ok.count) new pages · ⌘Z to undo", seconds: 2.5)
                }
            }
        }
    }

    /// Pictures onto the open page, each a little below and right of the one before. Outside draw mode the Select tool is
    /// picked with the last one selected, so it can be moved or resized at once; in draw mode the tool stays.
    func insertImages(_ ps: [PreparedImagePage], center: CGPoint?, via: String) {
        guard !ps.isEmpty else { return }
        let step = 24 / max(canvas.ptPerUnit * canvas.camera.zoom, 1e-6)
        var last: ImageObject?
        for (k, p) in ps.enumerated() {
            let c = center ?? CGPoint(x: canvas.camera.visible.midX, y: canvas.camera.visible.midY)
            last = canvas.insertImage(p, center: CGPoint(x: c.x + Double(k) * step, y: c.y - Double(k) * step))
            usage.record("insert_image", ["source": via, "kind": p.asset.ext])
        }
        if !canvas.drawMode, canvas.tools.tool != .select { apply(.tool(.select), from: "insertImage") }
        if !canvas.drawMode { canvas.selectedImageId = last?.id }
        updateUndoState(); warmThumbnailSoon(); container.pageMap.refresh()
    }

    /// One new page from a prepared picture: opened (with the overview's grow-from-tile when it's showing) or not.
    @discardableResult
    func makeImagePage(_ p: PreparedImagePage, open: Bool, via: String, undoable: Bool = true) -> Int {
        let i: Int
        if open && galleryShown { i = openNewPage { self.canvas.newImagePage(p) } ?? canvas.newImagePage(p, open: false) }
        else { i = canvas.newImagePage(p, open: open) }
        if undoable { pageOps.append(.created(canvas.pages[i])) }
        usage.record("image_page", ["source": via, "kind": p.asset.ext, "strokes": p.request.strokes.count])
        afterImagePage()
        return i
    }
    private func afterImagePage() {
        updateBanner(); updateUndoState(); warmThumbnailSoon()
        container.pageMap.refresh(); container.needsLayout = true
        if galleryShown, let g = gallery { g.reload(pages: canvas.pages, pageSize: canvas.camera.page, current: canvas.pageIndex) }
    }

    // MARK: ⌘V

    /// Edit › Paste with no text field focused: an image (or image files) on the pasteboard becomes a new page.
    @objc func paste(_ sender: Any?) {
        let reqs = ImagePages.requests(from: Self.pasteboard, kind: .paste)
        guard !reqs.isEmpty else { NSSound.beep(); return }
        importImages(reqs, via: "paste", to: .page(nil))
    }

    // MARK: File › New Page from Image…

    @objc func newPageFromImageAction() { chooseImages(to: .newPages) }
    @objc func insertImageAction() { chooseImages(to: .page(nil)) }
    private func chooseImages(to target: ImageTarget) {
        exitDrawMode("open image")
        let p = NSOpenPanel()
        p.allowedContentTypes = ImagePages.fileTypes
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if case .newPages = target { p.message = "Each image becomes a new page." } else { p.message = "The images go on this page." }
        p.prompt = "Add"
        guard !Launch.background else { return }   // tests use importImages directly
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK else { return }
            let reqs = p.urls.compactMap { u in (try? Data(contentsOf: u, options: .alwaysMapped)).map { ImagePageRequest(data: $0, source: ImageSource(kind: .file, fileName: u.lastPathComponent)) } }
            self?.importImages(reqs, via: "open", to: target)
        }
    }

    // MARK: dropping

    /// A drop at `at` (container points): onto the page there (in the overview: new pages).
    func dropImages(_ pb: NSPasteboard, at: CGPoint? = nil) -> Bool {
        let reqs = ImagePages.requests(from: pb, kind: .file)
        guard !reqs.isEmpty else { return false }
        let c = at.map { canvas.canvasPoint(fromView: canvas.convert($0, from: container)) }
        importImages(reqs, via: "drop", to: .page(c))
        return true
    }

    /// At launch: every picture's decoded copy ready in the background (the open page's first), so pages, thumbnails and
    /// the overview's transitions never wait for a decode.
    func prepareImages() {
        var seen = Set<String>(), list: [ImageAsset] = []
        for d in [canvas.doc] + canvas.pages { for i in d.images where seen.insert(i.asset.key).inserted { list.append(i.asset) } }
        ImageStore.decodeQueue.async { [weak self] in
            ImageStore.trimCache()
            for a in list { _ = a.preview() }
            DispatchQueue.main.async { self?.canvas.setNeedsRender(); if !list.isEmpty { self?.warmThumbnailSoon() } }
        }
    }

    // MARK: the Inbox

    func startInbox() {
        guard AppPaths.persists else { return }   // tests without a data folder: no Inbox
        let inbox = Inbox()
        inbox.onItem = { [weak self, weak inbox] id, r in
            guard let self, let inbox else { return }
            // Already made (the app stopped after saving the page, before removing the item).
            if let i = self.canvas.pages.firstIndex(where: { $0.importId == id }) { inbox.finish(id, page: i, pages: self.canvas.pages.count, error: nil); return }
            switch r {
            case .failure(let e): inbox.finish(id, page: nil, pages: self.canvas.pages.count, error: e.localizedDescription)
            case .success(let req):
                ImageStore.decodeQueue.async {
                    let p = Result { try ImagePages.prepare(req) }
                    DispatchQueue.main.async {
                        switch p {
                        case .failure(let e): inbox.finish(id, page: nil, pages: self.canvas.pages.count, error: e.localizedDescription)
                        case .success(let p):
                            // Never turns the page under a finger: while drawing it is added, and a note says so. Nor while
                            // the overview is up: the page is a new tile there (0.1.6 closed the overview into it, and into
                            // draw mode if the overview was opened from it).
                            let open = !self.canvas.drawMode && !self.galleryShown
                            let i = self.makeImagePage(p, open: open, via: "inbox", undoable: false)
                            let doc = self.canvas.pages[i]
                            if !open { self.showToast("Page \(i + 1) added from \(p.request.source.label)", seconds: 2.5) }
                            self.inboxWaiting.append((id, doc, self.canvas.autosaver.changes))
                            self.canvas.autosaver.saveNow(sync: false)
                        }
                    }
                }
            }
        }
        canvas.autosaver.onSaved = { [weak self] through in
            guard let self else { return }
            let ready = self.inboxWaiting.filter { $0.through <= through }
            self.inboxWaiting.removeAll { $0.through <= through }
            for w in ready {
                let page = self.canvas.pages.firstIndex { $0 === w.doc }
                self.inbox?.finish(w.id, page: page, pages: self.canvas.pages.count, error: page == nil ? "the page was deleted before it was saved" : nil)
            }
        }
        inbox.start()
        self.inbox = inbox
    }

    // MARK: the selected picture

    @objc func deletePictureAction() { canvas.deleteSelectedImage(); updateUndoState() }
    @objc func bringForwardAction() { canvas.reorderSelectedImage(1); updateUndoState() }
    @objc func sendBackwardAction() { canvas.reorderSelectedImage(-1); updateUndoState() }
    /// ⌘C with a picture selected: the picture itself, its original bytes (and the file's type), on the pasteboard.
    func copySelectedPicture() -> Bool {
        guard !galleryShown, let s = canvas.selectedImage, let d = s.asset.data() else { return false }
        let pb = Self.pasteboard
        pb.clearContents()
        let t = UTType(filenameExtension: s.asset.ext) ?? .data
        pb.setData(d, forType: NSPasteboard.PasteboardType(t.identifier))
        if t != .png, !s.asset.isPDF, let img = s.asset.full()?.cgImage {   // and a PNG, for apps that don't read the original's type
            let rep = NSBitmapImageRep(cgImage: img); if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        }
        usage.record("copy_picture", ["kind": s.asset.ext])
        showToast("Picture copied")
        return true
    }

    // MARK: undo

    /// ⌘Z after making or deleting a page: undo that. False if there's nothing to undo here.
    func undoPageOp() -> Bool {
        guard let op = pageOps.popLast() else { return false }
        switch op {
        case .deleted(let d):
            canvas.restorePage(d)
            usage.record("restore_page")
            afterPagesChanged(select: min(d.index, canvas.pages.count - 1))
            showToast("Page \(min(d.index, canvas.pages.count - 1) + 1) restored")
        case .created(let doc):
            guard let i = canvas.pages.firstIndex(where: { $0 === doc }) else { return undoPageOp() }
            _ = canvas.deletePage(i)
            afterPagesChanged(select: min(i, canvas.pages.count - 1))
            showToast("Image page removed")
        }
        return true
    }

    /// The page header's note on where the page's picture came from ("from Screenshot.png").
    var imageSourceNote: String {
        guard let i = canvas.doc.images.first else { return "" }
        return "  ·  from \(i.source.label)"
    }
}

/// A page made or deleted, for ⌘Z.
enum PageOp {
    case deleted(CanvasView.DeletedPage)
    case created(Document)
    var imageKeys: [String] {
        switch self {
        case .deleted(let d): return d.doc.images.map(\.asset.key) + (d.doc.history.undo + d.doc.history.redo).flatMap(\.images).map(\.asset.key)
        case .created: return []
        }
    }
}
