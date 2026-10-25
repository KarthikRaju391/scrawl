// Page overview: every page of the notebook as a thumbnail in a scrolling grid, with a "+ New page"
// tile last. Clicking a page grows it from its grid cell to the full canvas; G (or the toolbar's grid
// button) from a page shrinks the canvas back into its cell. Thumbnails show the top screen of each
// page and are cached per page until its contents change (Document.version), so reopening is instant.
import AppKit

/// CPU rendering of part of a page (the same stroke outlines the PDF export uses).
enum PageImage {
    /// `rect` (page units) drawn into an image of `px` pixels; off-page space is the grey desk.
    static func render(_ doc: Document, rect: CGRect, pageWidth: Double, pageTop: Double, px: CGSize, background: Int = 0, spacing: Double = 48) -> CGImage? {
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
        for s in doc.strokes where s.bounds.intersects(rect) {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(s.color.x), green: CGFloat(s.color.y), blue: CGFloat(s.color.z), alpha: CGFloat(s.color.w)))
            ctx.addPath(strokePath(s.points, size: s.size, brush: Brush.of(s.tool)))
            ctx.fillPath(using: .winding)
        }
        return ctx.makeImage()
    }
}

/// Thumbnails by page, re-rendered only when the page's contents change.
final class ThumbnailCache {
    private var cache: [ObjectIdentifier: (version: Int, image: CGImage)] = [:]
    private(set) var renders = 0
    static let pixelWidth = 480.0

    func image(for doc: Document, page: CGSize) -> CGImage? {
        let key = ObjectIdentifier(doc)
        if let c = cache[key], c.version == doc.version { return c.image }
        let rect = CGRect(x: 0, y: 0, width: page.width, height: page.height)   // the top screen of the page
        guard let img = PageImage.render(doc, rect: rect, pageWidth: page.width, pageTop: page.height,
                                         px: CGSize(width: Self.pixelWidth, height: Self.pixelWidth * page.height / page.width)) else { return nil }
        renders += 1
        cache[key] = (doc.version, img)
        return img
    }
    /// Drop pages that no longer exist.
    func keep(_ docs: [Document]) { let ids = Set(docs.map(ObjectIdentifier.init)); cache = cache.filter { ids.contains($0.key) } }
}

final class GalleryView: NSView {
    static let cellWidth: CGFloat = 240, gap: CGFloat = 28, label: CGFloat = 22, header: CGFloat = 54
    let scroll = NSScrollView()
    private let grid = GridView()
    private let title = NSTextField(labelWithString: "Pages")
    private let hintLabel = NSTextField(labelWithString: "Click a page to open it  ·  G or Esc goes back")
    var onOpen: ((Int) -> Void)?
    var onNewPage: (() -> Void)?
    let thumbnails = ThumbnailCache()

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
        grid.gallery = self
    }
    required init?(coder: NSCoder) { fatalError() }

    private(set) var pages: [Document] = []
    private(set) var pageSize = CGSize(width: 1600, height: 984)
    private(set) var current = 0

    func reload(pages: [Document], pageSize: CGSize, current: Int) {
        self.pages = pages; self.pageSize = pageSize; self.current = current
        thumbnails.keep(pages)
        needsLayout = true; layoutSubtreeIfNeeded()
        grid.needsDisplay = true
    }

    override func layout() {
        super.layout()
        title.sizeToFit(); hintLabel.sizeToFit()
        title.frame.origin = CGPoint(x: 28, y: bounds.height - Self.header + 14)
        hintLabel.frame.origin = CGPoint(x: title.frame.maxX + 16, y: bounds.height - Self.header + 18)
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.header)
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

    fileprivate func clicked(_ i: Int) { if i < pages.count { onOpen?(i) } else { onNewPage?() } }

    fileprivate func drawGrid(_ dirty: CGRect) {
        let cols = columns
        for i in 0..<cellCount {
            let r = cellRectInGrid(i)
            guard r.insetBy(dx: -8, dy: -40).intersects(dirty) else { continue }
            _ = cols
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -2); sh.shadowColor = NSColor(white: 0, alpha: 0.18); sh.set()
            NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            NSGraphicsContext.restoreGraphicsState()
            let labelText: String
            if i < pages.count {
                if let img = thumbnails.image(for: pages[i], page: pageSize), let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.clip()
                    // The grid view is flipped: draw the (y-up) image the right way up.
                    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
                    ctx.restoreGState()
                }
                if i == current {
                    NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1).setStroke()
                    let p = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8); p.lineWidth = 3; p.stroke()
                }
                labelText = "Page \(i + 1)"
            } else {
                NSColor(white: 0.55, alpha: 1).setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6); p.lineWidth = 1.5
                p.setLineDash([6, 5], count: 2, phase: 0); p.stroke()
                let plus = NSAttributedString(string: "+", attributes: [.font: NSFont.systemFont(ofSize: 40, weight: .light), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
                plus.draw(at: CGPoint(x: r.midX - plus.size().width / 2, y: r.midY - plus.size().height / 2))
                labelText = "New page"
            }
            let l = NSAttributedString(string: labelText, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: i == current ? .semibold : .regular),
                                                                       .foregroundColor: NSColor(white: 0.3, alpha: 1)])
            l.draw(at: CGPoint(x: r.midX - l.size().width / 2, y: r.maxY + 5))
        }
    }

    final class GridView: NSView {
        weak var gallery: GalleryView?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { gallery?.drawGrid(dirtyRect) }
        override func mouseDown(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            if let i = gallery?.cellIndex(at: p) { gallery?.clicked(i) }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
