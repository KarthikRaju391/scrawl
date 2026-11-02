// Export: one page as PNG or SVG (File › Export Page…, ⇧⌘E: format, scale, area and background are chosen in the save
// sheet, ExportPanel.swift), every page as one vector PDF (⌘E). Pages are infinite downward, so a page export runs from
// the top of the page to just below the lowest ink; "What's on screen" is exactly the view's rect at its zoom.
// PNG, SVG and PDF draw the same stroke outline (strokePath: a union of circles and quads, one nonzero fill per stroke,
// so the highlighter's alpha is applied once) and the paper the canvas's background shader draws.
import AppKit
import UniformTypeIdentifiers

struct ExportOptions: Equatable {
    enum Format: String, CaseIterable { case png, svg }
    enum Area: String, CaseIterable { case page, screen, selection }
    enum Background: String, CaseIterable { case paper, white, transparent }
    var format = Format.png
    /// Output pixels per page unit (the page is 1,600 units wide: 2 = 3,200 px, the old PNG export's size). For SVG it sets
    /// the width and height; the viewBox stays in page units.
    var scale = 2.0
    var area = Area.page
    var background = Background.paper

    static let presets = [1.0, 2, 3, 4]
    static let customRange = 0.5...8.0
    /// Larger images are scaled down to fit: 16,384 px is the most CoreGraphics, Metal and most viewers take on a side,
    /// and 64 megapixels is 256 MB of bitmap before PNG encoding.
    static let maxSide = 16_384
    static let maxPixels = 64_000_000

    struct Size: Equatable { var width: Int; var height: Int; var scale: Double; var capped: Bool }
    /// The output size of `rect` (page units) at `scale`, scaled down to the limits if it's too large.
    static func size(of rect: CGRect, scale requested: Double) -> Size {
        var s = requested
        let rw = max(rect.width, 1e-6), rh = max(rect.height, 1e-6)
        s = min(s, Double(maxSide) / rw, Double(maxSide) / rh, (Double(maxPixels) / (rw * rh)).squareRoot())
        let capped = s < requested - 1e-9
        let w = min(max(Int((rw * s).rounded(capped ? .down : .toNearestOrEven)), 1), maxSide)
        let h = min(max(Int((rh * s).rounded(capped ? .down : .toNearestOrEven)), 1), maxSide)
        return Size(width: w, height: h, scale: s, capped: capped)
    }

    /// The file the sheet chose, with the format's extension. The out-of-process save panel can keep the name it had
    /// when the format was switched (a test run saved SVG into "….png"), so the extension is set here; if that name
    /// is another file that exists, a number is added rather than overwriting what the panel never asked about.
    static func url(_ chosen: URL, for f: Format) -> URL {
        guard chosen.pathExtension.lowercased() != f.rawValue else { return chosen }
        let base = chosen.deletingPathExtension()
        var u = base.appendingPathExtension(f.rawValue), n = 2
        while FileManager.default.fileExists(atPath: u.path) { u = URL(fileURLWithPath: base.path + " \(n)").appendingPathExtension(f.rawValue); n += 1 }
        return u
    }

    // The last choices, kept in defaults ("exportOptions"). Test runs keep them in memory only.
    nonisolated(unsafe) static var testStore: [String: Any]?
    static func load() -> ExportOptions {
        var o = ExportOptions()
        guard let d = Launch.testing ? testStore : UserDefaults.standard.dictionary(forKey: "exportOptions") else { return o }
        if let v = d["format"] as? String, let f = Format(rawValue: v) { o.format = f }
        if let v = d["scale"] as? Double, customRange.contains(v) { o.scale = v }
        if let v = d["area"] as? String, let a = Area(rawValue: v), a != .selection { o.area = a }   // Selection is per use
        if let v = d["background"] as? String, let b = Background(rawValue: v) { o.background = b }
        return o
    }
    /// Remembers these choices. Area Selection isn't kept (there may be none next time): the area saved before stays.
    func save() {
        var o = self
        if area == .selection { o.area = Self.load().area }
        let d: [String: Any] = ["format": o.format.rawValue, "scale": o.scale, "area": o.area.rawValue, "background": o.background.rawValue]
        if Launch.testing { Self.testStore = d } else { UserDefaults.standard.set(d, forKey: "exportOptions") }
    }
}

/// One page's export: its strokes in `rect` (page units, y up), at `options`. The page is `pageWidth` wide with its top at
/// `pageTop`; `paper` is the canvas's pattern (0 none, 1 square, 2 dot, 3 ruled), drawn with the Paper background.
struct PageExport {
    let strokes: [Stroke]
    let rect: CGRect
    let pageWidth: Double
    let pageTop: Double
    let paper: Int
    var spacing = 48.0
    let options: ExportOptions

    var size: ExportOptions.Size { ExportOptions.size(of: rect, scale: options.scale) }
    var visibleStrokes: [Stroke] { strokes.filter { $0.bounds.intersects(rect) } }

    // The canvas's colours (Renderer's background shader).
    static let desk = (0.80, 0.82, 0.85), deskShadow = (0.55, 0.57, 0.61)
    static let gridLine = (0.82, 0.84, 0.87), dot = (0.65, 0.68, 0.72)
    /// The shader's dots: full within 1 px, fading out by 2 px; the same ink as a 1.53 px disc.
    static let dotRadiusPx = 1.53
    /// The page's shadow on the desk: mix(desk, shadow, 0.6·exp(-d/10 px)), d = pixels from the page's edge.
    static let shadowStops: [Double] = [0, 2.5, 5, 7.5, 10, 15, 20, 30, 40]
    static func shadowAlpha(_ px: Double) -> Double { 0.6 * exp(-px / 10) }

    /// The page's paper inside `rect`, and the desk around it if `rect` reaches off the page.
    private var pageInRect: CGRect { rect.intersection(CGRect(x: 0, y: rect.minY - 1, width: pageWidth, height: pageTop - rect.minY + 1)) }
    private var reachesOffPage: Bool { rect.minX < 0 || rect.maxX > pageWidth || rect.maxY > pageTop }

    // MARK: PNG

    func image() -> CGImage? {
        let sz = size
        let opaque = options.background != .transparent
        guard let ctx = CGContext(data: nil, width: sz.width, height: sz.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else { return nil }
        let sx = Double(sz.width) / rect.width, sy = Double(sz.height) / rect.height
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        draw(in: ctx, sx: sx)
        return ctx.makeImage()
    }

    /// The area as vector PDF, one page `size / pdfPixelsPerPoint` points (2x: the page's points, as the PNG pastes).
    func pdfData(pixelsPerPoint: Double = 2) -> Data? {
        let sz = size, sx = Double(sz.width) / rect.width
        var box = CGRect(x: 0, y: 0, width: Double(sz.width) / pixelsPerPoint, height: Double(sz.height) / pixelsPerPoint)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPage(mediaBox: &box)
        ctx.scaleBy(x: box.width / rect.width, y: box.height / rect.height)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.clip(to: rect)
        draw(in: ctx, sx: sx)   // hairlines and dots sized as in the PNG at this scale
        ctx.endPage(); ctx.closePDF()
        return data as Data
    }

    /// Background, paper and ink in page units (the context is already mapped); `sx` = output pixels per page unit.
    private func draw(in ctx: CGContext, sx: Double) {
        func rgb(_ c: (Double, Double, Double), _ a: Double = 1) -> CGColor { CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a) }
        switch options.background {
        case .transparent: ctx.clear(rect)
        case .white: ctx.setFillColor(.white); ctx.fill(rect)
        case .paper:
            if reachesOffPage {
                ctx.setFillColor(rgb(Self.desk)); ctx.fill(rect)
                let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   colors: Self.shadowStops.map { rgb(Self.deskShadow, Self.shadowAlpha($0)) } as CFArray,
                                   locations: Self.shadowStops.map { CGFloat($0 / Self.shadowStops.last!) })!
                let band = Self.shadowStops.last! / sx
                for b in shadowBands(band) {
                    ctx.saveGState(); ctx.clip(to: b.rect)
                    if let c = b.corner {
                        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: band, options: [])
                    } else {
                        ctx.drawLinearGradient(g, start: b.from, end: b.to, options: [])
                    }
                    ctx.restoreGState()
                }
            }
            let paper = pageInRect
            ctx.setFillColor(.white); ctx.fill(paper)
            if paper.width > 0, paper.height > 0, self.paper != 0 {
                ctx.saveGState(); ctx.clip(to: paper)
                let lw = 1 / sx
                if self.paper == 2 {
                    ctx.setFillColor(rgb(Self.dot))
                    let r = Self.dotRadiusPx / sx
                    forEachDot(in: paper) { ctx.addEllipse(in: CGRect(x: $0.x - r, y: $0.y - r, width: 2 * r, height: 2 * r)) }
                    ctx.fillPath()
                } else {
                    ctx.setFillColor(rgb(Self.gridLine))
                    for y in gridYs(in: paper) { ctx.addRect(CGRect(x: paper.minX, y: y - lw / 2, width: paper.width, height: lw)) }
                    if self.paper == 1 { for x in gridXs(in: paper) { ctx.addRect(CGRect(x: x - lw / 2, y: paper.minY, width: lw, height: paper.height)) } }
                    ctx.fillPath(using: .winding)   // one fill: crossings aren't darker, as in the shader
                }
                ctx.restoreGState()
            }
        }
        for s in visibleStrokes { Self.fill(s, in: ctx) }
    }

    /// Points per piece when a stroke is filled (PNG) or written as a group (SVG). CoreGraphics' fill time grows much
    /// faster than the number of overlapping subpaths in one fill: a 3,886-point highlighter scribble on a real page took
    /// 67 s as one path and 0.12 s in pieces of 16 (Quick Look and Preview draw SVG and PDF the same way).
    static let fillPiece = 16, svgPiece = 64
    /// SVG strokes up to this many points are one <path> (98% of strokes in a real notebook); longer ones are a <g>.
    static let svgOnePathMax = 512

    /// strokePath's outline, points `a..<b` (the circle at each, and the quad from the point before).
    static func outline(_ s: Stroke, _ a: Int, _ b: Int) -> CGPath {
        let p = CGMutablePath(), pts = s.points, r = s.radii
        for i in a..<b {
            if i > 0 {
                let pa = pts[i - 1].p, pb = pts[i].p, ra = r[i - 1], rb = r[i]
                let dx = pb.x - pa.x, dy = pb.y - pa.y, d = hypot(dx, dy)
                if d > 1e-6 {
                    let nx = -dy / d, ny = dx / d
                    p.move(to: CGPoint(x: pa.x - nx * ra, y: pa.y - ny * ra))
                    p.addLine(to: CGPoint(x: pb.x - nx * rb, y: pb.y - ny * rb))
                    p.addLine(to: CGPoint(x: pb.x + nx * rb, y: pb.y + ny * rb))
                    p.addLine(to: CGPoint(x: pa.x + nx * ra, y: pa.y + ny * ra))
                    p.closeSubpath()
                }
            }
            p.addEllipse(in: CGRect(x: pts[i].p.x - r[i], y: pts[i].p.y - r[i], width: 2 * r[i], height: 2 * r[i]))
        }
        return p
    }
    /// One stroke, filled in pieces. A translucent stroke (the highlighter) is drawn opaque into a transparency layer that
    /// is composited once at its alpha: where it crosses itself it isn't darker.
    static func fill(_ s: Stroke, in ctx: CGContext) {
        guard !s.points.isEmpty else { return }
        let a = CGFloat(s.color.w)
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: CGFloat(s.color.x), green: CGFloat(s.color.y), blue: CGFloat(s.color.z), alpha: 1))
        if a < 1 { ctx.clip(to: s.bounds.insetBy(dx: -1, dy: -1)); ctx.setAlpha(a); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        for i in stride(from: 0, to: s.points.count, by: fillPiece) {
            ctx.addPath(outline(s, i, min(i + fillPiece, s.points.count))); ctx.fillPath(using: .winding)
        }
        if a < 1 { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    /// `dpi`: nil leaves the PNG at 72 dpi (files, as before); the pasteboard gets 72 x scale so a 2x copy pastes at the
    /// page's size in points, not twice it.
    func pngData(dpi: Double? = nil) -> Data? {
        guard let img = image() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props = dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, img, props)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: paper geometry (page units)

    private func gridYs(in r: CGRect) -> [Double] {
        stride(from: (r.minY / spacing).rounded(.up) * spacing, through: r.maxY, by: spacing).map { $0 }
    }
    private func gridXs(in r: CGRect) -> [Double] {
        stride(from: (r.minX / spacing).rounded(.up) * spacing, through: r.maxX, by: spacing).map { $0 }
    }
    private func forEachDot(in r: CGRect, _ body: (CGPoint) -> Void) {
        let pad = spacing / 2   // dots just outside still show their edge
        let ys = gridYs(in: r.insetBy(dx: -pad, dy: -pad)), xs = gridXs(in: r.insetBy(dx: -pad, dy: -pad))
        for y in ys { for x in xs { body(CGPoint(x: x, y: y)) } }
    }
    /// The shadow along the page's left, right and top edges (`band` page units deep), as gradient strips; the two top
    /// corners are radial. Only the parts inside `rect`.
    private func shadowBands(_ band: Double) -> [(rect: CGRect, from: CGPoint, to: CGPoint, corner: CGPoint?)] {
        let W = pageWidth, T = pageTop, far = rect.minY - 1, h = T - far
        let all: [(CGRect, CGPoint, CGPoint, CGPoint?)] = [
            (CGRect(x: -band, y: far, width: band, height: h), CGPoint(x: 0, y: 0), CGPoint(x: -band, y: 0), nil),
            (CGRect(x: W, y: far, width: band, height: h), CGPoint(x: W, y: 0), CGPoint(x: W + band, y: 0), nil),
            (CGRect(x: 0, y: T, width: W, height: band), CGPoint(x: 0, y: T), CGPoint(x: 0, y: T + band), nil),
            (CGRect(x: -band, y: T, width: band, height: band), .zero, .zero, CGPoint(x: 0, y: T)),
            (CGRect(x: W, y: T, width: band, height: band), .zero, .zero, CGPoint(x: W, y: T)),
        ]
        return all.compactMap { b in
            let r = b.0.intersection(rect)
            return r.isNull || r.isEmpty ? nil : (r, b.1, b.2, b.3)
        }
    }

    // MARK: SVG

    /// The page as SVG: user units are page units with y measured down from the page's top, so the viewBox is the
    /// area; width and height are the output size. One <path> per stroke (circles as arcs and a quad per segment, all
    /// wound the same way, filled nonzero: the same shape as the PNG and PDF). Nothing external is referenced.
    func svg(title: String? = nil) -> String {
        let sz = size, sx = Double(sz.width) / rect.width
        var o = SVGOut(top: pageTop)
        let vb = CGRect(x: rect.minX, y: pageTop - rect.maxY, width: rect.width, height: rect.height)
        o.raw("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        o.raw("<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(sz.width)\" height=\"\(sz.height)\" preserveAspectRatio=\"none\" viewBox=\"")
        o.num(vb.minX); o.raw(" "); o.num(vb.minY); o.raw(" "); o.num(vb.width); o.raw(" "); o.num(vb.height); o.raw("\">\n")
        if let title { o.raw("<title>"); o.raw(title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")); o.raw("</title>\n") }
        func hex(_ c: (Double, Double, Double)) -> String { String(format: "#%02x%02x%02x", Int((c.0 * 255).rounded()), Int((c.1 * 255).rounded()), Int((c.2 * 255).rounded())) }
        func rectEl(_ r: CGRect, _ fill: String) {
            o.raw("<rect x=\""); o.num(r.minX); o.raw("\" y=\""); o.y(r.maxY); o.raw("\" width=\""); o.num(r.width)
            o.raw("\" height=\""); o.num(r.height); o.raw("\" fill=\"\(fill)\"/>\n")
        }
        switch options.background {
        case .transparent: break
        case .white: o.raw("<g id=\"background\">\n"); rectEl(rect, "#ffffff"); o.raw("</g>\n")
        case .paper:
            o.raw("<g id=\"paper\">\n")
            if reachesOffPage {
                rectEl(rect, hex(Self.desk))
                let band = Self.shadowStops.last! / sx
                var defs = "", n = 0
                func stops() -> String {
                    Self.shadowStops.map { "<stop offset=\"\(SVGOut.fmt($0 / Self.shadowStops.last!))\" stop-color=\"\(hex(Self.deskShadow))\" stop-opacity=\"\(SVGOut.fmt(Self.shadowAlpha($0), places: 4))\"/>" }.joined()
                }
                var rects: [(CGRect, Int)] = []
                for b in shadowBands(band) {
                    n += 1
                    if let c = b.corner {
                        defs += "<radialGradient id=\"shadow\(n)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(SVGOut.fmt(c.x))\" cy=\"\(SVGOut.fmt(pageTop - c.y))\" r=\"\(SVGOut.fmt(band))\">\(stops())</radialGradient>"
                    } else {
                        defs += "<linearGradient id=\"shadow\(n)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(SVGOut.fmt(b.from.x))\" y1=\"\(SVGOut.fmt(pageTop - b.from.y))\" x2=\"\(SVGOut.fmt(b.to.x))\" y2=\"\(SVGOut.fmt(pageTop - b.to.y))\">\(stops())</linearGradient>"
                    }
                    rects.append((b.rect, n))
                }
                if !defs.isEmpty { o.raw("<defs>\(defs)</defs>\n") }
                for (r, k) in rects { rectEl(r, "url(#shadow\(k))") }
            }
            let paper = pageInRect
            if paper.width > 0, paper.height > 0 {
                rectEl(paper, "#ffffff")
                if self.paper == 2 {
                    let r = Self.dotRadiusPx / sx
                    o.raw("<path id=\"dots\" fill=\"\(hex(Self.dot))\" d=\"")
                    forEachDot(in: paper) { o.circle($0, r) }
                    o.raw("\"/>\n")
                } else if self.paper == 1 || self.paper == 3 {
                    // Clipped to the page by construction: every line starts and ends on the paper.
                    o.raw("<path id=\"\(self.paper == 1 ? "grid" : "lines")\" fill=\"none\" stroke=\"\(hex(Self.gridLine))\" stroke-width=\"\(SVGOut.fmt(1 / sx, places: 4))\" d=\"")
                    for y in gridYs(in: paper) { o.raw("M"); o.num(paper.minX); o.raw(" "); o.y(y); o.raw("H"); o.num(paper.maxX) }
                    if self.paper == 1 { for x in gridXs(in: paper) { o.raw("M"); o.num(x); o.raw(" "); o.y(paper.maxY); o.raw("V"); o.y(paper.minY) } }
                    o.raw("\"/>\n")
                }
            }
            o.raw("</g>\n")
        }
        o.raw("<g id=\"ink\" fill-rule=\"nonzero\">\n")
        for (i, s) in visibleStrokes.enumerated() {
            let fill = hex((Double(s.color.x), Double(s.color.y), Double(s.color.z))), alpha = SVGOut.fmt(Double(s.color.w), places: 3)
            if s.points.count <= Self.svgOnePathMax {   // one path, filled once: fill-opacity is applied once
                o.raw("<path id=\"stroke-\(i + 1)\" class=\"stroke \(s.tool.rawValue)\" fill=\"\(fill)\"")
                if s.color.w < 1 { o.raw(" fill-opacity=\"\(alpha)\"") }
                o.raw(" d=\""); o.strokeOutline(s.points, radii: s.radii, 0, s.points.count); o.raw("\"/>\n")
            } else {   // a long stroke: opaque pieces in a group, the group's opacity composited once
                o.raw("<g id=\"stroke-\(i + 1)\" class=\"stroke \(s.tool.rawValue)\" fill=\"\(fill)\"")
                if s.color.w < 1 { o.raw(" opacity=\"\(alpha)\"") }
                o.raw(">")
                for a in stride(from: 0, to: s.points.count, by: Self.svgPiece) {
                    o.raw("<path d=\""); o.strokeOutline(s.points, radii: s.radii, a, min(a + Self.svgPiece, s.points.count)); o.raw("\"/>")
                }
                o.raw("</g>\n")
            }
        }
        o.raw("</g>\n</svg>\n")
        return String(decoding: o.bytes, as: UTF8.self)
    }
}

/// A fast SVG writer: numbers to 2 decimal places (0.01 page units), y flipped to SVG's downward axis.
struct SVGOut {
    let top: Double
    var bytes: [UInt8] = []
    init(top: Double) { self.top = top; bytes.reserveCapacity(1 << 16) }
    mutating func raw(_ s: String) { bytes.append(contentsOf: s.utf8) }
    mutating func num(_ v: Double) {
        var i = Int((v * 100).rounded())
        if i < 0 { bytes.append(UInt8(ascii: "-")); i = -i }
        bytes.append(contentsOf: String(i / 100).utf8)
        let f = i % 100
        if f != 0 {
            bytes.append(UInt8(ascii: "."))
            bytes.append(UInt8(48 + f / 10))
            if f % 10 != 0 { bytes.append(UInt8(48 + f % 10)) }
        }
    }
    mutating func y(_ v: Double) { num(top - v) }
    static func fmt(_ v: Double, places: Int = 2) -> String {
        var s = String(format: "%.\(places)f", v)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s == "-0" ? "0" : s
    }
    // Path data: each subpath starts absolute (M) and goes on relative (l, a), in hundredths rounded from the absolute
    // positions, so nothing accumulates and the numbers are short.
    private var at = (x: 0, y: 0)
    private mutating func int(_ i: Int) {
        var i = i
        if i < 0 { bytes.append(UInt8(ascii: "-")); i = -i }
        bytes.append(contentsOf: String(i / 100).utf8)
        let f = i % 100
        if f != 0 { bytes.append(UInt8(ascii: ".")); bytes.append(UInt8(48 + f / 10)); if f % 10 != 0 { bytes.append(UInt8(48 + f % 10)) } }
    }
    private func fixed(_ p: CGPoint) -> (x: Int, y: Int) { (Int((p.x * 100).rounded()), Int(((top - p.y) * 100).rounded())) }
    private mutating func moveTo(_ p: CGPoint) { let f = fixed(p); raw("M"); int(f.x); raw(" "); int(f.y); at = f }
    private mutating func lineTo(_ p: CGPoint) { let f = fixed(p); raw("l"); int(f.x - at.x); raw(" "); int(f.y - at.y); at = f }
    /// A circle as two half arcs, wound the same way as the quads (counterclockwise on screen; y-up counterclockwise
    /// in page units, like CGPath.addEllipse), so a nonzero fill is their union.
    mutating func circle(_ c: CGPoint, _ r: Double) {
        moveTo(CGPoint(x: c.x + r, y: c.y))
        let left = fixed(CGPoint(x: c.x - r, y: c.y)), ri = Int((r * 100).rounded())
        raw("a"); int(ri); raw(" "); int(ri); raw(" 0 1 0 "); int(left.x - at.x); raw(" 0")
        raw("a"); int(ri); raw(" "); int(ri); raw(" 0 1 0 "); int(at.x - left.x); raw(" 0z")
    }
    /// strokePath's outline (Ink.swift) for points `from..<to`: a circle at each point and the quad from the point before.
    mutating func strokeOutline(_ pts: [StrokePoint], radii r: [Double], _ from: Int, _ to: Int) {
        guard from < to else { return }
        for i in from..<to {
            guard i > 0 else { circle(pts[0].p, r[0]); continue }
            let a = pts[i - 1].p, b = pts[i].p, ra = r[i - 1], rb = r[i]
            let dx = b.x - a.x, dy = b.y - a.y, d = hypot(dx, dy)
            if d > 1e-6 {
                let nx = -dy / d, ny = dx / d
                moveTo(CGPoint(x: a.x - nx * ra, y: a.y - ny * ra))
                lineTo(CGPoint(x: b.x - nx * rb, y: b.y - ny * rb))
                lineTo(CGPoint(x: b.x + nx * rb, y: b.y + ny * rb))
                lineTo(CGPoint(x: a.x + nx * ra, y: a.y + ny * ra)); raw("z")
            }
            circle(b, rb)
        }
    }
}

extension CanvasView {
    /// The part of a page to export, in page units (y up): full width, top of the page to the lowest ink.
    func exportRect(_ d: Document) -> CGRect {
        let lowest = min(d.strokes.map(\.bounds.minY).min() ?? 0, 0) - 20
        return CGRect(x: 0, y: lowest, width: camera.page.width, height: camera.page.height - lowest)
    }

    /// The area an export of the current page covers.
    func exportArea(_ a: ExportOptions.Area) -> CGRect {
        switch a {
        case .page: return exportRect(doc)
        case .screen: return renderRect
        case .selection: return selection ?? renderRect
        }
    }

    /// The current page (or page `index`, whole page only) exported with `options`.
    func pageExport(_ options: ExportOptions, page index: Int? = nil) -> PageExport {
        let i = index ?? pageIndex
        let rect = i == pageIndex ? exportArea(options.area) : exportRect(pages[i])
        return PageExport(strokes: pages[i].strokes, rect: rect, pageWidth: camera.page.width, pageTop: camera.page.height,
                          paper: tools.background, options: options)
    }

    func export(_ options: ExportOptions, to url: URL, page index: Int? = nil) throws {
        let e = pageExport(options, page: index)
        let data: Data?
        switch options.format {
        case .png: data = e.pngData()
        case .svg: data = e.svg(title: "\(AppInfo.name) page \((index ?? pageIndex) + 1)").data(using: .utf8)
        }
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    /// What Copy puts on the pasteboard for the selection: PNG at 2x (marked 144 dpi, so it pastes at the page's size), and
    /// the same region as PDF (vector, in points) and SVG. The background is the export sheet's last choice, but never
    /// Transparent (pasted transparent ink can't be read on a dark background): Paper instead.
    static let copyScale = 2.0
    func selectionClip(_ remembered: ExportOptions) -> (png: Data, pdf: Data, svg: Data, options: ExportOptions)? {
        guard selection != nil else { return nil }
        var o = remembered
        o.format = .png; o.scale = Self.copyScale; o.area = .selection
        if o.background == .transparent { o.background = .paper }
        let e = pageExport(o)
        guard let png = e.pngData(dpi: 72 * o.scale), let pdf = e.pdfData(pixelsPerPoint: o.scale),
              let svg = e.svg(title: "\(AppInfo.name) selection").data(using: .utf8) else { return nil }
        return (png, pdf, svg, o)
    }

    /// The current page (or page `index`) as a PNG on white, `pxPerUnit` pixels per page unit (page is 1,600 units
    /// wide). Share, Copy Page and the test modes use it.
    func exportPNG(to url: URL, pxPerUnit: Double = 2, page index: Int? = nil) throws {
        try export(ExportOptions(format: .png, scale: pxPerUnit, area: .page, background: .white), to: url, page: index)
    }

    /// Every page, in order, as vector paths in one PDF (800 pt wide pages; long pages are tall).
    static let pdfPointsPerUnit = 0.5
    func exportPDF(to url: URL) throws {
        let k = Self.pdfPointsPerUnit
        var box = CGRect(x: 0, y: 0, width: camera.page.width * k, height: camera.page.height * k)
        let info = [kCGPDFContextCreator: AppInfo.name, kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent] as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info) else { throw CocoaError(.fileWriteUnknown) }
        for d in pages {
            let r = exportRect(d)
            var media = CGRect(x: 0, y: 0, width: r.width * k, height: r.height * k)
            ctx.beginPage(mediaBox: &media)
            ctx.setFillColor(.white); ctx.fill(media)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -r.minX, y: -r.minY)
            for s in d.strokes {
                ctx.setFillColor(CGColor(srgbRed: CGFloat(s.color.x), green: CGFloat(s.color.y), blue: CGFloat(s.color.z), alpha: CGFloat(s.color.w)))
                ctx.addPath(strokePath(s.points, size: s.size, brush: Brush.of(s.tool)))
                ctx.fillPath(using: .winding)   // one fill per stroke: the highlighter's alpha is applied once
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }
}
