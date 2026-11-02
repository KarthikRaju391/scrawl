// The Select tool: a one-finger drag in draw mode (the real input path) makes a rectangle in page units at the ink's
// absolute mapping, under pan and zoom; a second finger turns it into a pan/pinch and the old selection stays; a tap
// clears it; another tool or page clears it; nothing is an edit. Copy's pasteboard data (PNG at 2x, PDF, SVG) is exactly
// the region, matching the canvas's own render of it; Export with Area = Selection writes the region.
import AppKit
import PDFKit

private func rgba(_ img: CGImage, _ w: Int? = nil, _ h: Int? = nil, background: CGColor? = nil) -> [UInt8] {
    let w = w ?? img.width, h = h ?? img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background { ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
}
private func viewBox(_ svg: String) -> [Double] {
    guard let r = svg.range(of: #"viewBox="[^"]+""#, options: .regularExpression) else { return [] }
    return String(svg[r]).split(separator: "\"")[1].split(separator: " ").compactMap { Double($0) }
}
private func compare(_ a: [UInt8], _ b: [UInt8]) -> (over: Double, mean: Double) {
    var over = 0, sum = 0
    for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
        var m = 0; for k in 0..<3 { m = max(m, abs(Int(a[i + k]) - Int(b[i + k]))) }
        if m > 40 { over += 1 }; sum += m
    }
    let n = Double(a.count / 4); return (Double(over) / n, Double(sum) / n)
}

func selectionChecks(_ check: (Bool, String) -> Void) {
    CanvasView.clickToDraw = false
    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 700), device: nil)
    let pad = Multitouch.padMM
    func wave(_ x: Double, _ y: Double, _ n: Int = 60) -> [StrokePoint] {
        (0..<n).map { StrokePoint(p: CGPoint(x: x + Double($0) * 8, y: y + sin(Double($0) / 5) * 30), pressure: 0.3 + 0.4 * abs(sin(Double($0) / 7))) }
    }
    for k in 0..<5 { c.testAddStroke(wave(80, 880 - Double(k) * 110, 150)) }
    c.testAddStroke(wave(200, 420, 90), tool: .highlighter, color: SIMD4(0xFD / 255, 0xD6 / 255, 0x63 / 255, 0.35), sizePt: 24)
    var tools = c.tools; tools.background = 1; tools.tool = .select; c.tools = tools
    c.drawMode = true
    var t = 0.0, nextId: Int32 = 1
    func frame(_ cs: [(Int32, CGPoint)]) {   // pad positions as fractions of the pad
        t += 0.008
        c.handle(cs.map { Contact(id: $0.0, state: 4, norm: $0.1, mm: CGPoint(x: $0.1.x * pad.width, y: $0.1.y * pad.height), pressure: 30, size: 0.5, major: 7.5) },
                 arrival: t + 1000, sensorT: t)
    }
    func lift() { for _ in 0..<3 { frame([]) } }
    /// One finger from `a` to `b` (fractions of the pad), in `n` frames, then up.
    func drag(_ a: CGPoint, _ b: CGPoint, n: Int = 30) {
        nextId += 1; let id = nextId
        for k in 0...n { let f = Double(k) / Double(n); frame([(id, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))]) }
        lift()
    }
    /// Where a pad position lands on the page, worked out from the view alone: the pad inside the edge guard's band
    /// (Camera.margin of each side) maps onto camera.visible, as for ink.
    func expected(_ p: CGPoint) -> CGPoint {
        let v = c.camera.visible, m = Camera.margin, k = 1 / (1 - 2 * m)
        return CGPoint(x: v.minX + (p.x - m) * k * v.width, y: v.minY + (p.y - m) * k * v.height)
    }
    func near(_ a: CGRect?, _ b: CGRect, _ tol: Double = 0.01) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }
    let doc = c.doc, strokes0 = doc.strokes.count, version0 = doc.version, undo0 = doc.canUndo

    // 1. The rectangle is where the finger went, at three views (home; 250% panned; 370% near the page's edge).
    var geo: [String] = []
    for (z, x, y, a, b) in [(1.0, 0.0, 0.0, CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.7, y: 0.8)),
                            (2.5, 300.0, 200.0, CGPoint(x: 0.8, y: 0.75), CGPoint(x: 0.15, y: 0.1)),   // dragged up-left
                            (3.7, 1150.0, 500.0, CGPoint(x: 0.05, y: 0.5), CGPoint(x: 0.95, y: 0.55))] {
        c.setVisibleForReplay(x: x, y: y, w: 0, z: z)
        drag(a, b)
        let pa = expected(a), pb = expected(b)
        let want = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pb.x - pa.x), height: abs(pb.y - pa.y))
        if !near(c.selection, want) { geo.append("zoom \(z): got \(String(describing: c.selection)), want \(want)") }
    }
    check(geo.isEmpty && c.doc.strokes.count == strokes0,
          "a one-finger drag with Select makes the rectangle where the finger went (the ink's absolute mapping) at 100%, 250% panned and 370% near the edge, and draws no ink \(geo)")

    // 2. It stays on the page when the view moves: same page rect after a pan and a zoom; on screen it moves with the page.
    c.setVisibleForReplay(x: 400, y: 300, w: 0, z: 2)
    drag(CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.6, y: 0.7))
    guard let sel = c.selection else { check(false, "a drag with Select makes a selection (none: the rest of the selection checks can't run)"); return }
    let v0 = c.viewPoint(fromCanvas: CGPoint(x: sel.minX, y: sel.minY))
    c.setVisibleForReplay(x: 450, y: 250, w: 0, z: 2)                          // pan 50 right, 50 down
    let afterPan = c.selection, v1 = c.viewPoint(fromCanvas: CGPoint(x: sel.minX, y: sel.minY))
    let k = c.ptPerUnit * c.camera.zoom
    c.setVisibleForReplay(x: 450, y: 250, w: 0, z: 3)
    check(afterPan == sel && c.selection == sel && abs((v0.x - v1.x) - 50 * k) < 0.01 && abs((v1.y - v0.y) - 50 * k) < 0.01,
          String(format: "the selection stays on the page through a pan and a zoom (page rect unchanged); on screen it moved %.1f, %.1f pt with the page (want %.1f, %.1f)",
                 v0.x - v1.x, v1.y - v0.y, 50 * k, 50 * k))

    // 3. A second finger during a selection drag pans/pinches: the view moves, and the previous selection stays.
    let before = c.selection, zoom0 = c.camera.zoom
    nextId += 2; let f1 = nextId - 1, f2 = nextId
    for k in 0...6 { frame([(f1, CGPoint(x: 0.5 + Double(k) * 0.004, y: 0.5))]) }   // the first finger starts a drag
    for k in 0...30 {                                                             // a second finger lands; both spread
        let d = Double(k) * 0.004
        frame([(f1, CGPoint(x: 0.45 - d, y: 0.5)), (f2, CGPoint(x: 0.6 + d, y: 0.5))])
    }
    lift()
    check(c.selection == before && abs(c.camera.zoom - zoom0) > 0.05 && c.doc.strokes.count == strokes0,
          String(format: "a second finger turns a selection drag into a pinch (zoom %.2f -> %.2f); the selection is the one before, no ink", zoom0, c.camera.zoom))

    // 4. A tap (no drag) clears it.
    drag(CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.4005, y: 0.4), n: 4)
    check(c.selection == nil, "a tap with Select clears the selection")

    // 5. Copy's data: exactly the region, matching the canvas's Metal render of it; partial strokes cut at the edges.
    c.setVisibleForReplay(x: 100, y: 450, w: 0, z: 2.5)
    // On the render's pixel grid (whole pixels from the view's corner), cutting through the waves and the highlighter.
    let rr = c.renderRect
    let r = CGRect(x: rr.minX + 100, y: rr.maxY - 80 - 180, width: 260, height: 180)
    c.setSelectionForTest(r)
    var remembered = ExportOptions(); remembered.background = .paper
    guard let clip = c.selectionClip(remembered), let src = CGImageSourceCreateWithData(clip.png as CFData, nil),
          let png = CGImageSourceCreateImageAtIndex(src, 0, nil) else { check(false, "Copy makes PNG, PDF and SVG data"); return }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    let dpi = props[kCGImagePropertyDPIWidth] as? Double ?? 0
    check(png.width == Int((r.width * 2).rounded()) && png.height == Int((r.height * 2).rounded()) && abs(dpi - 144) < 0.5,
          "Copy's PNG is the rectangle at 2x: \(png.width) x \(png.height) px for \(Int(r.width)) x \(Int(r.height)) page units, \(Int(dpi)) dpi (pastes at the page's size)")
    // The canvas draws the same region: its render of the view at 2 px per page unit, cropped to the rectangle.
    let s = 2 / (c.ptPerUnit * c.camera.zoom)
    if let snap = c.snapshot(scale: s) {
        // 2 px per page unit in the render: the rectangle starts 200 px right and 160 px down from its top-left.
        if let cut = snap.cropping(to: CGRect(x: 200, y: 160, width: png.width, height: png.height)) {
            let a = rgba(png), b = rgba(cut, png.width, png.height), w = png.width, h = png.height
            let d = compare(a, b)
            // Where the ink is: every ink pixel of one has ink within 1 px in the other (anti-aliasing differs between
            // Metal's 4x multisampling and CoreGraphics at thin pen edges; an offset or missing ink doesn't pass).
            func ink(_ p: [UInt8]) -> [Bool] { (0..<(w * h)).map { p[$0 * 4] < 120 && p[$0 * 4 + 2] < 120 } }
            let ia = ink(a), ib = ink(b)
            func matched(_ m: [Bool], _ o: [Bool]) -> Double {
                var n = 0, ok = 0
                for i in m.indices where m[i] {
                    n += 1; let x = i % w, y = i / w
                    if (-1...1).contains(where: { dy in (-1...1).contains { dx in let xx = x + dx, yy = y + dy; return xx >= 0 && yy >= 0 && xx < w && yy < h && o[yy * w + xx] } }) { ok += 1 }
                }
                return n == 0 ? 0 : Double(ok) / Double(n)
            }
            let fa = matched(ia, ib), fb = matched(ib, ia)
            check(fa > 0.99 && fb > 0.99 && d.mean < 1.5 && ia.filter { $0 }.count > 2000,
                  String(format: "Copy's PNG = the canvas's render of that region (paper grid and ink): ink matches within 1 px %.1f%% / %.1f%% (%d ink px), mean difference %.2f/255",
                         fa * 100, fb * 100, ia.filter { $0 }.count, d.mean))
        } else { check(false, "crop the canvas render") }
    } else { check(false, "canvas render") }
    // Strokes cut at the edges: ink reaches the left and right edges of the image.
    let p = rgba(png)
    func inkInColumn(_ x: Int) -> Int { (0..<png.height).filter { y in let i = (y * png.width + x) * 4; return p[i] < 90 && p[i + 1] < 90 && p[i + 2] < 90 }.count }
    check(inkInColumn(0) > 0 && inkInColumn(png.width - 1) > 0, "strokes crossing the rectangle are cut at its edges (ink in the first and last columns: \(inkInColumn(0)), \(inkInColumn(png.width - 1)) px)")
    // PDF: one page, the PNG's size in points at 2x, drawing the same picture.
    if let pdf = PDFDocument(data: clip.pdf), let page = pdf.page(at: 0) {
        let b = page.bounds(for: .mediaBox)
        let ctx = CGContext(data: nil, width: png.width, height: png.height, bitsPerComponent: 8, bytesPerRow: png.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: png.width, height: png.height))
        ctx.scaleBy(x: Double(png.width) / b.width, y: Double(png.height) / b.height); page.draw(with: .mediaBox, to: ctx)
        let d = compare(p, Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: png.width * png.height * 4)))
        let vector = !String(decoding: clip.pdf, as: UTF8.self).contains("/Image")
        check(pdf.pageCount == 1 && abs(b.width - r.width) < 0.5 && abs(b.height - r.height) < 0.5 && vector && d.over < 0.01,
              String(format: "Copy's PDF: 1 vector page, %.0f x %.0f pt, draws the same picture (%.2f%% of pixels apart)", b.width, b.height, d.over * 100))
    } else { check(false, "Copy's PDF opens") }
    // SVG: parses, its viewBox is the rectangle, and it draws the same picture.
    let svgText = String(decoding: clip.svg, as: UTF8.self)
    let vb = viewBox(svgText)
    let wantVB = [r.minX, c.camera.page.height - r.maxY, r.width, r.height]
    if let img = NSImage(data: clip.svg), vb.count == 4 {
        let q = { () -> [UInt8] in
            let ctx = CGContext(data: nil, width: png.width, height: png.height, bitsPerComponent: 8, bytesPerRow: png.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            img.draw(in: NSRect(x: 0, y: 0, width: png.width, height: png.height)); NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: png.width * png.height * 4))
        }()
        let d = compare(p, q)
        check(zip(vb, wantVB).allSatisfy { abs($0 - $1) < 0.01 } && d.over < 0.01,
              String(format: "Copy's SVG: viewBox = the rectangle (%@), draws the same picture (%.2f%% of pixels apart)", vb.map { String(format: "%.1f", $0) }.joined(separator: " "), d.over * 100))
    } else { check(false, "Copy's SVG parses (viewBox \(vb))") }
    // The sheet's last background Transparent is copied as Paper (opaque); White stays White.
    var tr = ExportOptions(); tr.background = .transparent
    var wh = ExportOptions(); wh.background = .white
    let opaque = { (o: ExportOptions) -> Bool in
        guard let d = c.selectionClip(o)?.png, let i = CGImageSourceCreateWithData(d as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return false }
        return i.alphaInfo == .none || i.alphaInfo == .noneSkipLast
    }
    check(c.selectionClip(tr)?.options.background == .paper && opaque(tr) && c.selectionClip(wh)?.options.background == .white && opaque(wh),
          "Copy never pastes transparent: the sheet's Transparent is copied as Paper (White stays White), opaque PNG")
    // A selection with no ink copies the paper.
    c.setSelectionForTest(CGRect(x: 1300, y: -300, width: 120, height: 80))
    let empty = c.selectionClip(remembered).flatMap { CGImageSourceCreateWithData($0.png as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    let ep = empty.map { rgba($0) } ?? []
    let inkPx = stride(from: 0, to: ep.count, by: 4).filter { ep[$0] < 150 }.count
    check(empty?.width == 240 && inkPx == 0, "a selection with no ink copies just the paper (\(empty?.width ?? 0) x \(empty?.height ?? 0) px, \(inkPx) ink pixels)")

    // 6. Export with Area = Selection writes the region (PNG at 3x, SVG with the rectangle as viewBox).
    c.setSelectionForTest(r)
    let dir = NSTemporaryDirectory() + "td-selection-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? c.export(ExportOptions(format: .png, scale: 3, area: .selection, background: .white), to: URL(fileURLWithPath: dir + "/s.png"))
    try? c.export(ExportOptions(format: .svg, scale: 3, area: .selection, background: .white), to: URL(fileURLWithPath: dir + "/s.svg"))
    let ex = CGImageSourceCreateWithURL(URL(fileURLWithPath: dir + "/s.png") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    let exSVG = (try? String(contentsOfFile: dir + "/s.svg", encoding: .utf8)) ?? ""
    let exVB = viewBox(exSVG), wantVB3 = [r.minX, c.camera.page.height - r.maxY, r.width, r.height]
    check(ex?.width == Int((r.width * 3).rounded()) && ex?.height == Int((r.height * 3).rounded()) && exVB.count == 4 && zip(exVB, wantVB3).allSatisfy { abs($0 - $1) < 0.01 },
          "Export with Area = Selection writes the rectangle: PNG \(ex?.width ?? 0) x \(ex?.height ?? 0) at 3x, SVG viewBox \(exVB)")

    // 7. Another tool or another page clears it; none of this was an edit.
    var t2 = c.tools; t2.tool = .pen; c.tools = t2
    let clearedByTool = c.selection == nil
    t2.tool = .select; c.tools = t2; c.setSelectionForTest(r)
    c.newPage(); let clearedByPage = c.selection == nil
    c.goToPage(0)
    check(clearedByTool && clearedByPage, "switching tool clears the selection (\(clearedByTool)); so does another page (\(clearedByPage))")
    check(c.doc === doc && doc.strokes.count == strokes0 && doc.version == version0 && doc.canUndo == undo0,
          "selecting is never an edit: same strokes (\(doc.strokes.count)), page version \(doc.version) (was \(version0)), undo unchanged")
}
