// Bringing pictures in, wired into the window: ⌘V, dropping files or images on the window, File › New Page from
// Image…, and the Inbox (the browser extension's snapshots). Each picture becomes a new page (Images.swift); ⌘Z right
// after takes the page away again, like undoing a page delete.
import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
    /// Store and decode the pictures in the background, then make a page for each (the last one is opened).
    func importImages(_ requests: [ImagePageRequest], via: String) {
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
                for (k, p) in ok.enumerated() { self.makeImagePage(p, open: k == ok.count - 1, via: via) }
                if let e = results.compactMap({ r -> Error? in if case .failure(let e) = r { return e }; return nil }).first {
                    self.showToast(ok.isEmpty ? (e.localizedDescription) : "\(ok.count) added; \(results.count - ok.count) couldn't be read", seconds: 3)
                } else {
                    self.showToast(ok.count == 1 ? "New page from \(ok[0].request.source.label) · ⌘Z to undo" : "\(ok.count) new pages · ⌘Z to undo", seconds: 2.5)
                }
            }
        }
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
        importImages(reqs, via: "paste")
    }

    // MARK: File › New Page from Image…

    @objc func newPageFromImageAction() {
        exitDrawMode("open image")
        let p = NSOpenPanel()
        p.allowedContentTypes = ImagePages.fileTypes
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.message = "Each image becomes a new page."
        p.prompt = "Add"
        guard !Launch.background else { return }   // tests use importImages directly
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK else { return }
            let reqs = p.urls.compactMap { u in (try? Data(contentsOf: u, options: .alwaysMapped)).map { ImagePageRequest(data: $0, source: ImageSource(kind: .file, fileName: u.lastPathComponent)) } }
            self?.importImages(reqs, via: "open")
        }
    }

    // MARK: dropping

    func dropImages(_ pb: NSPasteboard) -> Bool {
        let reqs = ImagePages.requests(from: pb, kind: .file)
        guard !reqs.isEmpty else { return false }
        importImages(reqs, via: "drop")
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
                            // Never turns the page under a finger: while drawing it is added, and a note says so.
                            let open = !self.canvas.drawMode
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
