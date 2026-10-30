// Page overview: every page of the notebook as a thumbnail in a scrolling grid, with a "+ New page"
// tile last. Clicking a page grows it from its grid cell to the full canvas; G (or the toolbar's grid
// button) from a page shrinks the canvas back into its cell. Thumbnails show the top screen of each
// page and are cached per page until its contents change (Document.version), so reopening is instant.
import AppKit

/// When the click or key that starts a transition arrived (for the click-to-first-frame measurement).
enum TransitionTiming { nonisolated(unsafe) static var inputAt: Double? }

/// CPU rendering of part of a page (the same stroke outlines the PDF export uses).
enum PageImage {
    /// `rect` (page units) drawn into an image of `px` pixels; off-page space is the grey desk.
    static func render(_ doc: Document, rect: CGRect, pageWidth: Double, pageTop: Double, px: CGSize, background: Int = 0, spacing: Double = 48) -> CGImage? {
        render(doc.strokes, rect: rect, pageWidth: pageWidth, pageTop: pageTop, px: px, background: background, spacing: spacing)
    }
    /// `fast`: thumbnails. Each stroke is one round-capped line at its average width, through points at least
    /// 1.5 px apart, instead of its exact pressure outline: the same at thumbnail size, and ~10x quicker.
    static func render(_ strokes: [Stroke], rect: CGRect, pageWidth: Double, pageTop: Double, px: CGSize, background: Int = 0, spacing: Double = 48, fast: Bool = false) -> CGImage? {
        let w = max(Int(px.width), 1), h = max(Int(px.height), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sx = Double(w) / rect.width, sy = Double(h) / rect.height
        ctx.setFillColor(CGColor(srgbRed: 0.80, green: 0.82, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.setFillColor(.white)
        let paper = CGRect(x: 0, y: rect.minY - 1, width: pageWidth, height: pageTop - rect.minY + 1)
        ctx.fill(paper)
        if background != 0 {   // the canvas's paper pattern (as in the background shader): lines at multiples of `spacing`
            ctx.saveGState(); ctx.clip(to: paper)
            let lw = 1 / sx, line = CGColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 1)
            ctx.setFillColor(background == 2 ? CGColor(srgbRed: 0.65, green: 0.68, blue: 0.72, alpha: 1) : line)
            let y0 = (rect.minY / spacing).rounded(.down) * spacing, x0 = (rect.minX / spacing).rounded(.down) * spacing
            var y = y0
            while y <= rect.maxY {
                if background == 1 || background == 3 { ctx.fill(CGRect(x: rect.minX, y: y - lw / 2, width: rect.width, height: lw)) }
                if background == 2 { var x = x0; while x <= rect.maxX { ctx.fillEllipse(in: CGRect(x: x - 1.5 / sx, y: y - 1.5 / sx, width: 3 / sx, height: 3 / sx)); x += spacing } }
                y += spacing
            }
            if background == 1 { var x = x0; while x <= rect.maxX { ctx.fill(CGRect(x: x - lw / 2, y: rect.minY, width: lw, height: rect.height)); x += spacing } }
            ctx.restoreGState()
        }
        if fast {
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let minStep = 1.5 / sx
            for s in strokes where s.bounds.intersects(rect) && !s.points.isEmpty {
                let c = CGColor(srgbRed: CGFloat(s.color.x), green: CGFloat(s.color.y), blue: CGFloat(s.color.z), alpha: CGFloat(s.color.w))
                ctx.setStrokeColor(c)
                let avgR = s.radii.isEmpty ? s.size / 2 : s.radii.reduce(0, +) / Double(s.radii.count)
                ctx.setLineWidth(max(avgR * 2, 0.7 / sx))
                var last = s.points[0].p
                ctx.move(to: last)
                for q in s.points.dropFirst() where hypot(q.p.x - last.x, q.p.y - last.y) >= minStep { ctx.addLine(to: q.p); last = q.p }
                if let e = s.points.last?.p, e != last { ctx.addLine(to: e) }
                if s.points.count == 1 { ctx.addLine(to: CGPoint(x: last.x + 0.01, y: last.y)) }
                ctx.strokePath()
            }
        } else {
            for s in strokes where s.bounds.intersects(rect) {
                ctx.setFillColor(CGColor(srgbRed: CGFloat(s.color.x), green: CGFloat(s.color.y), blue: CGFloat(s.color.z), alpha: CGFloat(s.color.w)))
                ctx.addPath(strokePath(s.points, size: s.size, brush: Brush.of(s.tool)))
                ctx.fillPath(using: .winding)
            }
        }
        return ctx.makeImage()
    }
}

/// Thumbnails by page, re-rendered only when the page's contents change. Rendering happens on a background
/// queue: the grid draws whatever is cached (an older version while a page's new one renders) and redraws
/// when it's ready, so opening the overview never waits for a render.
final class ThumbnailCache {
    private var cache: [ObjectIdentifier: (version: Int, image: CGImage)] = [:]
    /// The part of the page each cached thumbnail shows (page units): the page transitions zoom from it.
    private var regions: [ObjectIdentifier: CGRect] = [:]
    private var pending = Set<ObjectIdentifier>()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "scrawl.thumbnails", qos: .userInitiated, attributes: .concurrent)   // pages render in parallel
    /// One cache for the app: warmed in the background after launch and after edits, so the overview opens
    /// with every thumbnail ready.
    static let shared = ThumbnailCache()
    private var renderCount = 0
    var renders: Int { lock.lock(); defer { lock.unlock() }; return renderCount }
    static let pixelWidth = 480.0

    private func render(_ strokes: [Stroke], version: Int, key: ObjectIdentifier, page: CGSize) -> CGImage? {
        lock.lock(); let have = cache[key]; lock.unlock()
        if let have, have.version == version { return have.image }   // rendered meanwhile
        let rect = Self.region(strokes, page: page)
        guard let img = PageImage.render(strokes, rect: rect, pageWidth: page.width, pageTop: page.height,
                                         px: CGSize(width: Self.pixelWidth, height: Self.pixelWidth * page.height / page.width), fast: true) else { return nil }
        lock.lock(); renderCount += 1; if (cache[key]?.version ?? -1) <= version { cache[key] = (version, img); regions[key] = rect }; lock.unlock()
        return img
    }
    /// The part of the page a thumbnail shows: the ink with a margin, in the tile's shape (at least a third of
    /// the page wide, so a dot isn't blown up), inside the page; the top screen when there's no ink. A few
    /// lines at the top used to make a near-blank card.
    static func region(_ strokes: [Stroke], page: CGSize) -> CGRect {
        let top = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        guard var ink = strokes.first?.bounds else { return top }
        for s in strokes.dropFirst() { ink = ink.union(s.bounds) }
        let a = page.width / page.height, m = max(ink.width, ink.height) * 0.08 + page.width * 0.01
        var w = ink.width + 2 * m, h = ink.height + 2 * m
        if w / h < a { w = h * a } else { h = w / a }
        if w < page.width / 3 { w = page.width / 3; h = w / a }
        if w > page.width { w = page.width; h = w / a }
        let x = min(max(ink.midX - w / 2, 0), page.width - w)
        let maxY = min(ink.midY + h / 2, page.height)
        return CGRect(x: x, y: maxY - h, width: w, height: h)
    }
    /// The cached image and whether it is up to date (no rendering).
    func cached(_ doc: Document) -> (image: CGImage?, fresh: Bool) {
        lock.lock(); defer { lock.unlock() }
        let c = cache[ObjectIdentifier(doc)]
        return (c?.image, c?.version == doc.version)
    }
    /// The cached image and the part of the page it shows, as the overview's tile draws it (no rendering).
    func cachedWithRegion(_ doc: Document) -> (image: CGImage, region: CGRect)? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(doc)
        guard let c = cache[key], let r = regions[key] else { return nil }
        return (c.image, r)
    }
    /// Up to date, rendering now if needed (tests).
    func image(for doc: Document, page: CGSize) -> CGImage? {
        let (img, fresh) = cached(doc)
        if fresh { return img }
        let strokes = doc.strokes, v = doc.version, key = ObjectIdentifier(doc)
        return queue.sync { render(strokes, version: v, key: key, page: page) }
    }
    /// Render in the background if out of date; `ready` runs on the main queue afterwards.
    func refresh(_ doc: Document, page: CGSize, ready: @escaping () -> Void) {
        let key = ObjectIdentifier(doc)
        lock.lock()
        let fresh = cache[key]?.version == doc.version, busy = pending.contains(key)
        if !fresh && !busy { pending.insert(key) }
        lock.unlock()
        guard !fresh && !busy else { return }
        let strokes = doc.strokes, v = doc.version   // a copy: the page may change while this renders
        queue.async { [weak self] in
            _ = self?.render(strokes, version: v, key: key, page: page)
            self?.lock.lock(); self?.pending.remove(key); self?.lock.unlock()
            DispatchQueue.main.async(execute: ready)
        }
    }
    /// Tests: forget every thumbnail (the worst case: the overview opens with nothing rendered).
    func dropAll() { lock.lock(); cache = [:]; lock.unlock() }
    /// Drop pages that no longer exist.
    func keep(_ docs: [Document]) { let ids = Set(docs.map(ObjectIdentifier.init)); lock.lock(); cache = cache.filter { ids.contains($0.key) }; lock.unlock() }
}

final class GalleryView: NSView {
    static let cellWidth: CGFloat = 240, gap: CGFloat = 28, label: CGFloat = 38, header: CGFloat = 54
    let scroll = NSScrollView()
    private let grid = GridView()
    private let title = NSTextField(labelWithString: "Pages")
    private let hintLabel = NSTextField(labelWithString: "Arrows or the pointer choose  ·  Return, Space or G opens  ·  Esc goes back  ·  • = the page you came from")
    var onOpen: ((Int) -> Void)?
    var onNewPage: (() -> Void)?
    let thumbnails = ThumbnailCache.shared
    let titles = PageTitles()
    /// ⌘F: pages whose handwriting contains this; the others dim.
    let search = NSSearchField()
    var query = "" { didSet { if query != oldValue { applyQuery() } } }
    var onSearchReturn: (() -> Void)?
    var onDelete: ((Int) -> Void)?
    /// A tile's context menu (Control-click or right-click): Open, Delete Page.
    func tileMenu(_ i: Int) -> NSMenu? {
        guard i < pages.count else { return nil }
        let m = NSMenu()
        let open = NSMenuItem(title: "Open", action: #selector(menuOpen(_:)), keyEquivalent: ""); open.tag = i; open.target = self
        let del = NSMenuItem(title: "Delete Page", action: #selector(menuDelete(_:)), keyEquivalent: ""); del.tag = i; del.target = self
        m.addItem(open); m.addItem(.separator()); m.addItem(del)
        return m
    }
    @objc private func menuOpen(_ i: NSMenuItem) { clicked(i.tag) }
    @objc private func menuDelete(_ i: NSMenuItem) { onDelete?(i.tag) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1).cgColor
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        addSubview(scroll)
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.textColor = NSColor(white: 0.15, alpha: 1)
        hintLabel.font = .systemFont(ofSize: 12); hintLabel.textColor = NSColor(white: 0.45, alpha: 1)
        addSubview(title); addSubview(hintLabel)
        search.placeholderString = "Search handwriting (⌘F)"
        search.sendsSearchStringImmediately = true
        search.target = self; search.action = #selector(searchChanged)
        addSubview(search)
        grid.gallery = self
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let g = self?.grid else { return }
            g.setNeedsDisplay(g.visibleRect)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private(set) var pages: [Document] = []
    private(set) var pageSize = CGSize(width: 1600, height: 984)
    private(set) var current = 0
    /// The tile the arrow keys have selected (Return / Space opens it).
    var selected = -1

    func reload(pages: [Document], pageSize: CGSize, current: Int) {
        self.pages = pages; self.pageSize = pageSize; self.current = current
        selected = current   // the selection starts on the current page
        thumbnails.keep(pages)
        needsLayout = true; layoutSubtreeIfNeeded()
        grid.needsDisplay = true
        // Every page's thumbnail, not only the tiles on screen (they're quick, and in parallel), so scrolling
        // never finds a blank one.
        for d in pages { thumbnails.refresh(d, page: pageSize) { [weak self] in self?.grid.needsDisplay = true } }
        titles.refresh(pages, page: pageSize) { [weak self] in self?.grid.needsDisplay = true; self?.applyQuery(moveSelection: false) }
    }

    @objc private func searchChanged() {
        query = search.stringValue
        if let e = NSApp.currentEvent, e.type == .keyDown, e.keyCode == 36 || e.keyCode == 76 { onSearchReturn?() }   // Return opens the match
    }
    /// Pages that match the search (all of them when it's empty).
    var matching: [Int] { pages.indices.filter { titles.matches(pages[$0], query) } }
    private func applyQuery(moveSelection: Bool = true) {
        if moveSelection, !query.isEmpty, let first = matching.first { selected = first; grid.scrollToVisible(cellRectInGrid(first).insetBy(dx: 0, dy: -Self.gap)) }
        grid.needsDisplay = true
    }
    func redrawGrid() { if !isHidden { grid.needsDisplay = true } }
    func focusSearch() { window?.makeFirstResponder(search) }

    override func layout() {
        super.layout()
        title.sizeToFit(); hintLabel.sizeToFit()
        title.frame.origin = CGPoint(x: 28, y: bounds.height - Self.header + 14)
        hintLabel.frame.origin = CGPoint(x: title.frame.maxX + 16, y: bounds.height - Self.header + 18)
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.header)
        search.frame = CGRect(x: bounds.width - 268, y: bounds.height - Self.header + 14, width: 240, height: 24)
        grid.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(gridHeight, scroll.contentSize.height))
    }

    // MARK: geometry (grid coordinates are flipped: y down from the top)

    var columns: Int { max(1, Int((scroll.contentSize.width - Self.gap) / (Self.cellWidth + Self.gap))) }
    var thumbHeight: CGFloat { Self.cellWidth * pageSize.height / pageSize.width }
    var cellCount: Int { pages.count + 1 }   // + the "New page" tile, last
    private var gridHeight: CGFloat {
        let rows = (cellCount + columns - 1) / columns
        return Self.gap + CGFloat(rows) * (thumbHeight + Self.label + Self.gap)
    }
    /// Thumbnail rect of cell i in grid coordinates (the grid is centred horizontally).
    func cellRectInGrid(_ i: Int) -> CGRect {
        let cols = columns
        let used = CGFloat(cols) * Self.cellWidth + CGFloat(cols - 1) * Self.gap
        let x0 = max((grid.bounds.width - used) / 2, Self.gap)
        let r = i / cols, c = i % cols
        return CGRect(x: x0 + CGFloat(c) * (Self.cellWidth + Self.gap), y: Self.gap + CGFloat(r) * (thumbHeight + Self.label + Self.gap),
                      width: Self.cellWidth, height: thumbHeight)
    }
    /// Cell i's thumbnail rect in `view`'s coordinates (scrolled into view first).
    func cellRect(_ i: Int, in view: NSView) -> CGRect {
        let r = cellRectInGrid(i)
        grid.scrollToVisible(r.insetBy(dx: 0, dy: -Self.gap))
        return grid.convert(r, to: view)
    }
    func cellIndex(at gridPoint: CGPoint) -> Int? { (0..<cellCount).first { cellRectInGrid($0).insetBy(dx: -4, dy: -4).contains(gridPoint) } }

    /// The text under tile i: "Page 3  ·  Oct 25, 2026" (created date), "New page" for the last tile.
    func tileLabel(_ i: Int) -> String { i < pages.count ? "Page \(i + 1)  ·  \(PageDate.short(pages[i].created))" : "New page" }

    /// Arrow keys: ← → previous / next tile (continuing across rows), ↑ ↓ a row; no wrap-around. ↓ into a
    /// shorter last row from a column past its end goes to the last tile. The selection scrolls into view.
    func moveSelection(dx: Int, dy: Int) {
        let cols = columns, last = cellCount - 1
        var i = min(max(selected, 0), last)
        if dx != 0 { i = min(max(i + dx, 0), last) }
        if dy < 0, i - cols >= 0 { i -= cols }
        if dy > 0 {
            if i + cols <= last { i += cols } else if i / cols < last / cols { i = last }
        }
        selected = i
        grid.scrollToVisible(cellRectInGrid(i).insetBy(dx: 0, dy: -Self.gap))
        grid.needsDisplay = true
    }

    fileprivate func clicked(_ i: Int) { selected = i; grid.needsDisplay = true; if i < pages.count { onOpen?(i) } else { onNewPage?() } }
    /// Test hook: draw the grid now.
    func displayGridNow() { grid.display() }
    override var acceptsFirstResponder: Bool { true }
    // Pointer moves reach the overview as first responder (and the grid through its tracking area).
    override func mouseMoved(with e: NSEvent) { hovered(cellIndex(at: grid.convert(e.locationInWindow, from: nil))) }
    /// The pointer over a tile moves the highlight there (the same highlight the arrow keys move).
    fileprivate func hovered(_ i: Int?) {
        guard let i, i != selected else { return }
        selected = i; grid.needsDisplay = true
    }

    /// Test hook: rings drawn around tiles in the last full draw of the visible grid (tile index -> count).
    private(set) var ringsDrawn: [Int: Int] = [:]
    private(set) var currentDotDrawn = false

    fileprivate func drawGrid(_ dirty: CGRect) {
        ringsDrawn = [:]; currentDotDrawn = false
        let cols = columns
        for i in 0..<cellCount {
            let r = cellRectInGrid(i)
            guard r.insetBy(dx: -8, dy: -40).intersects(dirty) else { continue }
            _ = cols
            // A cheap shadow (offset soft rects, no blur: a blurred NSShadow per tile cost ~20 ms when the grid appears).
            NSColor(white: 0, alpha: 0.05).setFill(); NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 2).insetBy(dx: -1, dy: -1), xRadius: 7, yRadius: 7).fill()
            NSColor(white: 0, alpha: 0.07).setFill(); NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
            NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            let labelText: String
            if i < pages.count {
                let (cachedImage, fresh) = thumbnails.cached(pages[i])
                if !fresh { thumbnails.refresh(pages[i], page: pageSize) { [weak self] in self?.grid.needsDisplay = true } }
                if let img = cachedImage, let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.clip()
                    // The grid view is flipped: draw the (y-up) image the right way up.
                    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
                    ctx.restoreGState()
                }
                if !query.isEmpty && !titles.matches(pages[i], query) {   // not a search match: dimmed
                    NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 0.75).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                }
                labelText = tileLabel(i)
            } else {
                NSColor(white: 0.55, alpha: 1).setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6); p.lineWidth = 1.5
                p.setLineDash([6, 5], count: 2, phase: 0); p.stroke()
                let plus = NSAttributedString(string: "+", attributes: [.font: NSFont.systemFont(ofSize: 40, weight: .light), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
                plus.draw(at: CGPoint(x: r.midX - plus.size().width / 2, y: r.midY - plus.size().height / 2))
                labelText = "New page"
            }
            // One highlight: the blue ring, moved by the arrow keys and the pointer (it starts on the current page).
            if i == selected {
                NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1).setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8); p.lineWidth = 3; p.stroke()
                ringsDrawn[i, default: 0] += 1
            }
            let l = NSAttributedString(string: labelText, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: i == current ? .semibold : .regular),
                                                                       .foregroundColor: NSColor(white: 0.3, alpha: 1)])
            let lx = r.midX - l.size().width / 2
            l.draw(at: CGPoint(x: lx, y: r.maxY + 5))
            // The first handwritten line (read on this Mac), under the label.
            if i < pages.count, case let t = titles.title(pages[i]), !t.isEmpty {
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = .center
                let tl = NSAttributedString(string: "“\(t)”", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: style])
                tl.draw(in: CGRect(x: r.minX, y: r.maxY + 21, width: r.width, height: 16))
            }
            if i == current {   // the page that was open: a small blue dot before its (semibold) label
                NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1).setFill()
                NSBezierPath(ovalIn: CGRect(x: lx - 11, y: r.maxY + 5 + l.size().height / 2 - 3, width: 6, height: 6)).fill()
                currentDotDrawn = true
            }
        }
    }

    final class GridView: NSView {
        weak var gallery: GalleryView?
        override var isFlipped: Bool { true }
        // Only what's on screen: the first display marks the whole (tall) grid dirty, and drawing every tile
        // took ~30 ms. Scrolling redraws what comes into view (see GalleryView.init).
        override func draw(_ dirtyRect: NSRect) { gallery?.drawGrid(dirtyRect.intersection(visibleRect)) }
        override func mouseDown(with e: NSEvent) {
            TransitionTiming.inputAt = CACurrentMediaTime()
            let p = convert(e.locationInWindow, from: nil)
            if let i = gallery?.cellIndex(at: p) { gallery?.clicked(i) }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseMoved(with e: NSEvent) { gallery?.hovered(gallery?.cellIndex(at: convert(e.locationInWindow, from: nil))) }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let g = gallery, let i = g.cellIndex(at: convert(event.locationInWindow, from: nil)) else { return nil }
            g.selected = i; needsDisplay = true
            return g.tileMenu(i)
        }
    }
}

extension CanvasView {
    /// The current page as the canvas shows it (its view, paper pattern, ink), rendered offscreen on the
    /// GPU with the canvas's own renderer: a few milliseconds, versus hundreds for the CPU stroke outlines.
    func snapshot(scale requested: Double? = nil) -> CGImage? {
        let scale = requested ?? Double(window?.backingScaleFactor ?? 2)
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return nil }
        let dev = renderer.device, vis = renderRect
        let pxPerUnit = ptPerUnit * camera.zoom * scale
        let items: [Renderer.DrawItem] = doc.strokes.compactMap { s in
            guard s.bounds.intersects(vis) else { return nil }
            if s.mesh.buffer == nil { s.mesh = renderer.makeMesh(strokeMesh(s.points, radii: s.radii, pxPerUnit: pxPerUnit * 2)) }
            let c = s.color
            return .init(mesh: s.mesh, verts: nil, color: SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w))
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .shared
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        md.usage = .renderTarget; md.storageMode = .private; md.textureType = .type2DMultisample; md.sampleCount = Renderer.sampleCount
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: w, height: h, mipmapped: false)
        sd.usage = .renderTarget; sd.storageMode = .private; sd.textureType = .type2DMultisample; sd.sampleCount = Renderer.sampleCount
        guard let out = dev.makeTexture(descriptor: d), let ms = dev.makeTexture(descriptor: md), let st = dev.makeTexture(descriptor: sd),
              let cb = renderer.queue.makeCommandBuffer() else { return nil }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = ms; p.colorAttachments[0].resolveTexture = out
        p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .multisampleResolve
        p.stencilAttachment.texture = st; p.stencilAttachment.loadAction = .clear
        renderer.encode(cb, p, visible: vis, background: tools.background, spacing: 48, pxPerUnit: pxPerUnit,
                        page: CGRect(x: 0, y: -1e9, width: camera.page.width, height: camera.page.height + 1e9), items: items)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
