// Export Page… (PNG / SVG): pixel size = scale x area; "What's on screen" is the view (compared with the canvas's own
// Metal render of it); backgrounds' transparency; the SVG parses, has one path per stroke and the area as its viewBox,
// and renders back (CoreSVG, through NSImage) like the PNG; a self-crossing highlighter isn't darker where it crosses;
// a huge scale is capped.
import AppKit

private struct RGBA { let w: Int, h: Int; let px: [UInt8]
    subscript(x: Int, y: Int) -> (Int, Int, Int, Int) {   // y from the top
        let i = (y * w + x) * 4; return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
    }
}
/// Any image drawn into a w x h premultiplied RGBA bitmap, starting transparent.
private func pixels(_ draw: (CGContext) -> Void, _ w: Int, _ h: Int) -> RGBA {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    draw(ctx)
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return RGBA(w: w, h: h, px: Array(UnsafeBufferPointer(start: p, count: w * h * 4)))
}
private func pixels(_ img: CGImage) -> RGBA { pixels({ $0.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height)) }, img.width, img.height) }
private func pngImage(_ data: Data) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
/// Pixels whose largest channel difference is over `tol`, as a fraction; and the mean difference.
private func diff(_ a: RGBA, _ b: RGBA, tol: Int) -> (over: Double, mean: Double) {
    var over = 0, sum = 0
    for i in stride(from: 0, to: a.px.count, by: 4) {
        var m = 0
        for k in 0..<4 { m = max(m, abs(Int(a.px[i + k]) - Int(b.px[i + k]))) }
        if m > tol { over += 1 }; sum += m
    }
    let n = Double(a.px.count / 4)
    return (Double(over) / n, Double(sum) / n)
}

/// The SVG's root attributes and its paths, read with XMLParser.
private final class SVGRead: NSObject, XMLParserDelegate {
    var root: [String: String] = [:], paths: [[String: String]] = [], ok = false
    init(_ data: Data) { super.init(); let p = XMLParser(data: data); p.delegate = self; ok = p.parse() }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if e == "svg" { root = a }
        if e == "path" { paths.append(a) }
    }
    var strokePaths: [[String: String]] { paths.filter { ($0["class"] ?? "").hasPrefix("stroke") } }
    var viewBox: [Double] { (root["viewBox"] ?? "").split(separator: " ").compactMap { Double($0) } }
}

func exportPageChecks(_ check: (Bool, String) -> Void) {
    let dir = NSTemporaryDirectory() + "td-exportpage-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    // A wide view (1400 x 700): at zoom 1 the desk shows left and right of the page, as in a wide window.
    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 700), device: nil)
    func wave(_ x: Double, _ y: Double, _ n: Int = 60) -> [StrokePoint] {
        (0..<n).map { StrokePoint(p: CGPoint(x: x + Double($0) * 8, y: y + sin(Double($0) / 5) * 30), pressure: 0.3 + 0.4 * abs(sin(Double($0) / 7))) }
    }
    let blue = SIMD4<Float>(0x1A / 255, 0x73 / 255, 0xE8 / 255, 1), yellow = SIMD4<Float>(0xFD / 255, 0xD6 / 255, 0x63 / 255, 0.35)
    for k in 0..<4 { c.testAddStroke(wave(100, 850 - Double(k) * 110)) }
    c.testAddStroke(wave(150, 400), tool: .marker, color: blue)
    c.testAddStroke(wave(120, 520, 70), tool: .highlighter, color: yellow, sizePt: 20)
    c.testAddStroke(wave(300, -700))                       // below the first screen
    c.testAddStroke(wave(1450, 600, 30))                   // runs off the page's right edge
    let top = c.camera.page.height
    // The page area, worked out independently: full width, from the top to 20 below the lowest ink.
    let lowest = c.doc.strokes.map(\.bounds.minY).min()!
    let pageRect = CGRect(x: 0, y: lowest - 20, width: 1600, height: top - (lowest - 20))

    func export(_ o: ExportOptions, _ name: String) -> Data? {
        let url = URL(fileURLWithPath: dir + "/" + name)
        do { try c.export(o, to: url) } catch { return nil }
        return try? Data(contentsOf: url)
    }

    // 1. PNG pixel size = scale x area, for presets and custom scales, both areas.
    do {
        var bad: [String] = []
        c.setVisibleForReplay(x: 500, y: 300, w: 0, z: 3.7)
        let screen = c.renderRect
        for (area, r) in [(ExportOptions.Area.page, pageRect), (.screen, screen)] {
            for s in [1.0, 2, 3, 4, 0.5, 2.37, 8] where r.width * s * r.height * s <= Double(ExportOptions.maxPixels) {   // larger is capped (7.)
                guard let d = export(ExportOptions(format: .png, scale: s, area: area, background: .white), "size.png"), let img = pngImage(d) else { bad.append("\(area) \(s): no PNG"); continue }
                let ww = (r.width * s).rounded(), wh = (r.height * s).rounded()
                if abs(Double(img.width) - ww) > 0.5 || abs(Double(img.height) - wh) > 0.5 { bad.append("\(area) \(s)x: \(img.width)x\(img.height), want \(Int(ww))x\(Int(wh))") }
            }
        }
        check(bad.isEmpty, "PNG pixel size = scale x area (page \(Int(pageRect.width))x\(Int(pageRect.height)) units and the view at 370%, at 1-4x, 50%, 237%, and 800% for the view; the page at 800% is over the cap) \(bad)")
    }

    // 2. What's on screen = the view: the PNG at the screen's pixel density matches the canvas's own Metal render of the
    //    view (the same code the window draws with), paper pattern, desk and ink included.
    for (z, x, y) in [(1.0, 0.0, 0.0), (3.7, 0.0, 250.0), (2.5, 600.0, -400.0)] {
        c.setVisibleForReplay(x: x, y: y, w: 0, z: z)
        for paper in [0, 1, 2, 3] {
            c.tools.background = paper
            let scale = c.ptPerUnit * c.camera.zoom * 2   // device pixels per page unit on a 2x screen
            guard let snap = c.snapshot(scale: 2),
                  let d = export(ExportOptions(format: .png, scale: scale, area: .screen, background: .paper), "screen.png"), let img = pngImage(d) else {
                check(false, "screen export and snapshot render"); continue
            }
            let sizeOK = img.width == snap.width && img.height == snap.height
            let dd = sizeOK ? diff(pixels(img), pixels(snap), tol: 40) : (over: 1.0, mean: 255.0)
            if paper == 2, z == 3.7 { try? d.write(to: URL(fileURLWithPath: dir + "/../exportpage-screen.png")) }
            check(sizeOK && dd.over < 0.004 && dd.mean < 1.5,
                  String(format: "zoom %.1f, paper %d: \"What's on screen\" is the view: %dx%d px = the canvas's render (%dx%d); %.2f%% of pixels differ by > 40/255, mean %.2f",
                         z, paper, img.width, img.height, snap.width, snap.height, dd.over * 100, dd.mean))
        }
    }
    c.tools.background = 1

    // 3. Transparent: alpha 0 away from the ink (and ink still drawn); White and Paper: no transparency at all.
    do {
        let o = ExportOptions(format: .png, scale: 1, area: .page, background: .transparent)
        guard let d = export(o, "t.png"), let img = pngImage(d) else { check(false, "transparent PNG"); return }
        let p = pixels(img)
        // Ink mask from the same export on white, grown by 2 px: everything else must be fully transparent.
        let w = pixels(pngImage(export(ExportOptions(format: .png, scale: 1, area: .page, background: .white), "w.png")!)!)
        var inkMask = [Bool](repeating: false, count: p.w * p.h)
        for y in 0..<p.h { for x in 0..<p.w where w[x, y].0 < 250 || w[x, y].1 < 250 || w[x, y].2 < 250 {
            for dy in -2...2 { for dx in -2...2 { let xx = x + dx, yy = y + dy; if xx >= 0, yy >= 0, xx < p.w, yy < p.h { inkMask[yy * p.w + xx] = true } } } } }
        var offInk = 0, offInkClear = 0, onInk = 0
        for y in 0..<p.h { for x in 0..<p.w { if inkMask[y * p.w + x] { if p[x, y].3 > 0 { onInk += 1 } } else { offInk += 1; if p[x, y].3 == 0 { offInkClear += 1 } } } }
        check(offInk > 100_000 && offInkClear == offInk && onInk > 2000 && img.alphaInfo != .none && img.alphaInfo != .noneSkipLast,
              "Transparent: alpha 0 on all \(offInk) pixels off the ink (\(offInk - offInkClear) not), \(onInk) ink pixels drawn")
        for bg in [ExportOptions.Background.white, .paper] {
            guard let d = export(ExportOptions(format: .png, scale: 1, area: .page, background: bg), "o.png"), let img = pngImage(d) else { check(false, "\(bg) PNG"); continue }
            let q = pixels(img)
            var notOpaque = 0
            for i in stride(from: 3, to: q.px.count, by: 4) where q.px[i] != 255 { notOpaque += 1 }
            check(notOpaque == 0, "\(bg.rawValue.capitalized): no transparency (\(notOpaque) pixels with alpha < 255 of \(q.w * q.h); PNG alpha info \(img.alphaInfo.rawValue))")
        }
    }

    // 4. SVG: parses, one path per stroke in the area, viewBox = the area (page units, y down from the page's top), size =
    //    the PNG's.
    for (area, zoom) in [(ExportOptions.Area.page, 1.0), (.screen, 3.7)] {
        c.setVisibleForReplay(x: 450, y: 350, w: 0, z: zoom)
        let r = area == .page ? pageRect : c.renderRect
        let o = ExportOptions(format: .svg, scale: 2, area: area, background: .paper)
        guard let d = export(o, "p.svg") else { check(false, "SVG written"); continue }
        let svg = SVGRead(d)
        let want = c.doc.strokes.filter { $0.bounds.intersects(r) }.count
        let vb = svg.viewBox, wantVB = [r.minX, top - r.maxY, r.width, r.height]
        let vbOK = vb.count == 4 && zip(vb, wantVB).allSatisfy { abs($0 - $1) < 0.01 }
        let sz = ExportOptions.size(of: r, scale: 2)
        let external = String(decoding: d, as: UTF8.self).range(of: "(href|url\\((?!#)|@import|<image|<script)", options: .regularExpression) != nil
        check(svg.ok && svg.strokePaths.count == want && want >= (area == .page ? 8 : 2) && vbOK && svg.root["width"] == "\(sz.width)" && svg.root["height"] == "\(sz.height)" && !external,
              "SVG (\(area.rawValue)) parses (\(svg.ok)), \(svg.strokePaths.count) stroke paths for \(want) strokes in the area, viewBox \(vb.map { String(format: "%.2f", $0) }) = area \(wantVB.map { String(format: "%.2f", $0) }), \(svg.root["width"] ?? "?") x \(svg.root["height"] ?? "?") px, no external references, \(d.count / 1024) KB")
    }

    // 5. The SVG rendered back (CoreSVG, as Preview and Quick Look draw it) matches the PNG at the same scale.
    c.setVisibleForReplay(x: 0, y: 0, w: 0, z: 1)
    for (area, bg, paper, s) in [(ExportOptions.Area.page, ExportOptions.Background.white, 0, 1.0), (.page, .paper, 1, 1.0), (.page, .paper, 2, 2.0),
                                 (.page, .transparent, 0, 1.0), (.screen, .paper, 3, 1.5), (.screen, .paper, 1, 1)] {
        c.tools.background = paper
        let o = ExportOptions(format: .svg, scale: s, area: area, background: bg)
        guard let sd = export(o, "r.svg"), let pd = export(ExportOptions(format: .png, scale: s, area: area, background: bg), "r.png"),
              let png = pngImage(pd), let svgImg = NSImage(data: sd) else { check(false, "SVG renders with NSImage"); continue }
        let a = pixels(png)
        let b = pixels({ ctx in
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            svgImg.draw(in: NSRect(x: 0, y: 0, width: png.width, height: png.height)); NSGraphicsContext.restoreGraphicsState()
        }, png.width, png.height)
        let dd = diff(a, b, tol: 40)
        check(dd.over < 0.004 && dd.mean < 1.5, String(format: "SVG rendered back = PNG (%@, %@, paper %d, %.1fx, %dx%d): %.3f%% of pixels differ by > 40/255, mean %.2f",
                                                     area.rawValue, bg.rawValue, paper, s, png.width, png.height, dd.over * 100, dd.mean))
    }

    // 6. A highlighter crossing itself (a figure eight) isn't darker where it crosses, in the PNG and the SVG.
    do {
        let h = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
        let cx = 800.0, cy = 500.0
        let eight = (0...240).map { i -> StrokePoint in
            let t = Double(i) / 240 * 2 * .pi
            return StrokePoint(p: CGPoint(x: cx + 300 * sin(t), y: cy + 150 * sin(2 * t)), pressure: 0.5)
        }
        h.testAddStroke(eight, tool: .highlighter, color: yellow, sizePt: 36)
        let o = ExportOptions(format: .png, scale: 1, area: .page, background: .white)
        let r = h.exportArea(.page)
        func at(_ img: RGBA, _ x: Double, _ y: Double) -> (Int, Int, Int, Int) { img[Int(x - r.minX), Int(r.maxY - y)] }
        let png = pixels(pngImage({ try? h.export(o, to: URL(fileURLWithPath: dir + "/h.png")); return try! Data(contentsOf: URL(fileURLWithPath: dir + "/h.png")) }())!)
        try? h.export(ExportOptions(format: .svg, scale: 1, area: .page, background: .white), to: URL(fileURLWithPath: dir + "/h.svg"))
        let svgImg = NSImage(contentsOf: URL(fileURLWithPath: dir + "/h.svg"))!
        let svg = pixels({ ctx in
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            svgImg.draw(in: NSRect(x: 0, y: 0, width: png.w, height: png.h)); NSGraphicsContext.restoreGraphicsState()
        }, png.w, png.h)
        // Expected: yellow at 35% over white once. The crossing is the centre; a single pass is the top of a lobe.
        let want = [0xFD, 0xD6, 0x63].map { Int((255 * 0.65 + Double($0) * 0.35).rounded()) }
        for (name, img) in [("PNG", png), ("SVG", svg)] {
            let cross = at(img, cx, cy), single = at(img, cx + 300 * sin(Double.pi / 4), cy + 150)
            let same = abs(cross.0 - single.0) <= 2 && abs(cross.1 - single.1) <= 2 && abs(cross.2 - single.2) <= 2
            let once = abs(single.2 - want[2]) <= 3
            check(same && once, "self-crossing highlighter, \(name): crossing \(cross.0),\(cross.1),\(cross.2) = single pass \(single.0),\(single.1),\(single.2) (35% once: \(want))")
        }
    }

    // 7. A huge scale is capped (16,384 px a side, 64 MP) and still exports, quickly.
    do {
        let big = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
        big.testAddStroke(wave(100, 800)); big.testAddStroke(wave(100, -14_000))   // a page ~15,800 units long
        let r = big.exportArea(.page)
        let sz = ExportOptions.size(of: r, scale: 8)
        let t0 = CFAbsoluteTimeGetCurrent()
        let url = URL(fileURLWithPath: dir + "/huge.png")
        let ok = (try? big.export(ExportOptions(format: .png, scale: 8, area: .page, background: .paper), to: url)) != nil
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let img = ok ? CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } : nil
        let w = img?.width ?? 0, h = img?.height ?? 0
        check(sz.capped && w == sz.width && h == sz.height && w <= ExportOptions.maxSide && h <= ExportOptions.maxSide && w * h <= ExportOptions.maxPixels && dt < 15,
              String(format: "800%% of a %.0f x %.0f-unit page (uncapped %.0f x %.0f px) is capped to %d x %d px (%.0f%%, %.1f MP), exported in %.1f s",
                     r.width, r.height, r.width * 8, r.height * 8, w, h, sz.scale * 100, Double(w * h) / 1e6, dt))
        let svg = SVGRead((try? { try big.export(ExportOptions(format: .svg, scale: 8, area: .page, background: .paper), to: URL(fileURLWithPath: dir + "/huge.svg")); return try Data(contentsOf: URL(fileURLWithPath: dir + "/huge.svg")) }()) ?? Data())
        check(svg.root["width"] == "\(sz.width)" && svg.root["height"] == "\(sz.height)", "SVG at 800% gets the same capped size (\(svg.root["width"] ?? "?") x \(svg.root["height"] ?? "?"))")
        let small = ExportOptions.size(of: CGRect(x: 0, y: 0, width: 1600, height: 1000), scale: 4)
        check(!small.capped && small.width == 6400 && small.height == 4000, "a normal page at 4x isn't capped (\(small.width) x \(small.height))")
    }
}
