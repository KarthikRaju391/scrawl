// The overview's tile for a long page (ink about 3 screens tall: lines of writing at the top, a drawing further down)
// shows the page from its top, as it reads and as it opens, not a middle slice (Karthik, 2 Nov, page 22: the tile showed
// "I want to work on something useful…" from the middle; the page opened at "Lol, I hope…"). A short page keeps the
// tight crop. A long page's tile fades at the bottom (more below).
import AppKit

func thumbnailRegionChecks(_ check: (Bool, String) -> Void) {
    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1286, height: 795), device: nil)
    let page = c.camera.page, W = page.width, top = page.height
    // Writing: 8 lines from the top of the page down, like handwriting (waves of short "words").
    for line in 0..<8 {
        for word in 0..<6 {
            let x0 = 80 + Double(word) * 240, y0 = top - 70 - Double(line) * 95
            c.testAddStroke((0..<40).map { StrokePoint(p: CGPoint(x: x0 + Double($0) * 4.5, y: y0 + sin(Double($0) / 3) * 18), pressure: 0.5) })
        }
    }
    // A last line near the bottom of the first screen (where the tile ends and fades).
    for word in 0..<6 { let x0 = 80 + Double(word) * 240; c.testAddStroke((0..<40).map { StrokePoint(p: CGPoint(x: x0 + Double($0) * 4.5, y: 40 + sin(Double($0) / 3) * 18), pressure: 0.5) }) }
    // A house and a blob, two screens further down.
    let houseY = top - 2.2 * top
    for (a, b) in [(CGPoint(x: 500, y: houseY), CGPoint(x: 900, y: houseY)), (CGPoint(x: 900, y: houseY), CGPoint(x: 900, y: houseY + 300)),
                   (CGPoint(x: 900, y: houseY + 300), CGPoint(x: 700, y: houseY + 480)), (CGPoint(x: 700, y: houseY + 480), CGPoint(x: 500, y: houseY + 300)),
                   (CGPoint(x: 500, y: houseY + 300), CGPoint(x: 500, y: houseY))] {
        c.testAddStroke((0...40).map { k in let f = Double(k) / 40; return StrokePoint(p: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), pressure: 0.6) })
    }
    c.testAddStroke((0...80).map { k in let t = Double(k) / 80 * 2 * .pi; return StrokePoint(p: CGPoint(x: 1200 + 90 * cos(t), y: houseY - 300 + 70 * sin(t)), pressure: 0.7) },
                    tool: .marker, color: SIMD4(0x1E / 255, 0x8E / 255, 0x3E / 255, 1))
    var ink = c.doc.strokes[0].bounds; for s in c.doc.strokes { ink = ink.union(s.bounds) }
    let textBounds = c.doc.strokes.prefix(54).reduce(c.doc.strokes[0].bounds) { $0.union($1.bounds) }
    let r = ThumbnailCache.region(c.doc.strokes, page: page)
    check(ink.height > 2.5 * top && r.width == W && r.maxY >= ink.maxY && r.maxY - ink.maxY <= 0.03 * W && r.contains(textBounds) && r.minY > houseY + 480,
          String(format: "a long page (ink %.1f screens): the tile shows it from the top of the ink (region top %.0f, ink top %.0f, page top %.0f), full width, with all the writing and not the drawing below",
                 ink.height / top, r.maxY, ink.maxY, top))
    // The tile's picture against the page as it opens (at its top, 100%: the canvas's own render of that view).
    guard let tile = ThumbnailCache.shared.image(for: c.doc, page: page), let opened = c.snapshot(scale: 1) else { check(false, "tile and page renders"); return }
    // Ink density in a coarse grid over the part both show (the view's pad area, page top down one screen; the top 85%,
    // above the tile's fade).
    let gx = 16, gy = 10
    func grid(_ img: CGImage, crop: CGRect?) -> [Double] {
        let w = 320, h = 197
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let full = crop ?? CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let src = img.cropping(to: CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height * 0.85)) ?? img   // above the fade
        ctx.interpolationQuality = .high; ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var g = [Double](repeating: 0, count: gx * gy)
        for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4] < 150 { g[(y * gy / h) * gx + x * gx / w] += 1 } }
        return g
    }
    func corr(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var n = 0.0, da = 0.0, db = 0.0
        for i in a.indices { n += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
        return n / max((da * db).squareRoot(), 1e-9)
    }
    // The opened view at zoom 1 (home: the page's top) shows the page top down `top` units over the pad's rect.
    let pr = c.padRect, k = Double(opened.height) / Double(c.bounds.height)
    let padCrop = CGRect(x: pr.minX * k, y: (Double(c.bounds.height) - pr.maxY) * k, width: pr.width * k, height: pr.height * k)
    // The tile's region is the page top down r.height (= one screen at full width): the same part of the page.
    let cr = corr(grid(tile, crop: nil), grid(opened, crop: padCrop))
    check(abs(c.camera.zoom - 1) < 1e-9 && c.camera.visible.maxY == top && cr > 0.8,
          String(format: "the tile matches the page as it opens (its top, 100%%): ink layout correlation %.2f (a middle slice scores near 0)", cr))
    // It fades at the bottom (there's more below): the last line, in the bottom 14%, is much lighter than in the same
    // region rendered without the fade.
    func bottomInk(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)); ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var n = 0
        for y in Int(Double(h) * 0.9)..<h { for x in 0..<w where p[(y * w + x) * 4] < 120 { n += 1 } }   // memory rows run top-down
        return n
    }
    let plain = PageImage.render(c.doc.strokes, rect: r, pageWidth: W, pageTop: top, px: CGSize(width: tile.width, height: tile.height), fast: true)!
    let faded = bottomInk(tile), unfaded = bottomInk(plain)
    check(ThumbnailCache.continuesBelow(c.doc.strokes, r) && unfaded > 100 && Double(faded) < Double(unfaded) * 0.3,
          "it fades at the bottom (more below): dark ink pixels in the bottom tenth \(faded), \(unfaded) without the fade")
    // A short page keeps the tight crop (a few lines don't make a near-blank card), with no fade.
    let s = CanvasView(frame: NSRect(x: 0, y: 0, width: 1286, height: 795), device: nil)
    for word in 0..<3 { s.testAddStroke((0..<40).map { StrokePoint(p: CGPoint(x: 300 + Double(word) * 200 + Double($0) * 4, y: 600 + sin(Double($0) / 3) * 18), pressure: 0.5) }) }
    let sr = ThumbnailCache.region(s.doc.strokes, page: page)
    check(sr.width < W * 0.7 && !ThumbnailCache.continuesBelow(s.doc.strokes, sr), String(format: "a short page keeps the tight crop (%.0f of %.0f wide), no fade", sr.width, W))
}
