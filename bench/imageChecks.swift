// Image objects (0.1.6): pictures under the ink.
//   - every format imports with its bytes stored unchanged, its size and orientation right;
//   - the GPU draws a picture exactly where it is on the page, pixel for pixel at 1:1 (whole and tiled), and close to a
//     reference when zoomed out;
//   - PNG / SVG / PDF exports and Copy as Image contain the picture under the ink;
//   - the notebook round trip keeps pictures (same bytes on disk); a notebook without pictures is written exactly as
//     before; a 0.1.5 reader opens a notebook with pictures; scratch-out, the eraser and Clear Page never remove a picture;
//   - thumbnails show the picture from its top; the Inbox's page.json; unused picture files are removed;
//   - a 4000 x 12000 screenshot: import, memory, frame times.
import AppKit
import Metal
import PDFKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: fixtures

/// A test card: a gradient, coloured blocks, 1 px checkers and lines (any resampling or shift shows), opaque.
private func testCard(_ w: Int, _ h: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, alpha: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    let g = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.95, green: 0.9, blue: 0.7, alpha: 1), CGColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    var seed: UInt64 = 7
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
    for _ in 0..<60 {
        ctx.setFillColor(CGColor(srgbRed: rnd(), green: rnd(), blue: rnd(), alpha: 1))
        ctx.fill(CGRect(x: Int(rnd() * Double(w)), y: Int(rnd() * Double(h)), width: 8 + Int(rnd() * Double(w) / 8), height: 8 + Int(rnd() * Double(h) / 8)))
    }
    ctx.setFillColor(.black)
    for y in stride(from: 0, to: h, by: 97) { ctx.fill(CGRect(x: 0, y: y, width: w, height: 1)) }
    for x in stride(from: 0, to: w, by: 89) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: h)) }
    for y in 0..<min(64, h) { for x in 0..<min(64, w) where (x + y) % 2 == 0 { ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1)) } }   // top-left
    if alpha { ctx.clear(CGRect(x: w / 2, y: h / 2, width: w / 4, height: h / 4)) }
    return ctx.makeImage()!
}
private func encode(_ img: CGImage, _ t: UTType, props: [CFString: Any] = [:]) -> Data {
    let d = NSMutableData()
    let dest = CGImageDestinationCreateWithData(d, t.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "encode \(t)")
    return d as Data
}
/// A two-page PDF: page 1 is the test card's blocks as vectors (and a line of text), 612 x 792 pt.
private func testPDF() -> Data {
    let d = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: d as CFMutableData)!, mediaBox: &box, nil)!
    for page in 0..<2 {
        ctx.beginPage(mediaBox: &box)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 72, y: 600, width: 200, height: 120))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.15, alpha: 1)); ctx.fill(CGRect(x: 300, y: 100, width: 240, height: 60 + page * 300))
        ctx.setFillColor(.black); ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 2))
        ctx.endPage()
    }
    ctx.closePDF()
    return d as Data
}
private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// Premultiplied RGBA pixels of an image, rows from the top.
private func rgba(_ img: CGImage, _ w: Int? = nil, _ h: Int? = nil) -> [UInt8] {
    let w = w ?? img.width, h = h ?? img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
}
private func rasterBytes(_ r: Raster, x: Int = 0, y: Int = 0, w: Int? = nil, h: Int? = nil) -> [UInt8] {
    let w = w ?? r.width, h = h ?? r.height
    var out = [UInt8](); out.reserveCapacity(w * h * 4)
    for row in y..<(y + h) { out += UnsafeBufferPointer(start: (r.base + row * r.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self), count: w * 4) }
    return out
}
/// Largest channel difference, and the mean of each pixel's largest difference.
private func diff(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, mean: Double) {
    var m = 0, sum = 0
    for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
        var p = 0; for k in 0..<3 { p = max(p, abs(Int(a[i + k]) - Int(b[i + k]))) }
        m = max(m, p); sum += p
    }
    return (a.count == b.count ? m : 999, Double(sum) / Double(max(a.count / 4, 1)))
}

/// The canvas renderer drawing `visible` (page units) into w x h pixels, 4x MSAA as on screen; RGBA rows from the top.
private func gpuRender(_ r: Renderer, visible: CGRect, w: Int, h: Int, background: Int = 0, images: Renderer.ImageDraws, items: [Renderer.DrawItem] = []) -> [UInt8] {
    let dev = r.device
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = .renderTarget; d.storageMode = .shared
    let out = dev.makeTexture(descriptor: d)!
    let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    md.usage = .renderTarget; md.storageMode = .private; md.textureType = .type2DMultisample; md.sampleCount = Renderer.sampleCount
    let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: w, height: h, mipmapped: false)
    sd.usage = .renderTarget; sd.storageMode = .private; sd.textureType = .type2DMultisample; sd.sampleCount = Renderer.sampleCount
    let p = MTLRenderPassDescriptor()
    p.colorAttachments[0].texture = dev.makeTexture(descriptor: md); p.colorAttachments[0].resolveTexture = out
    p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .multisampleResolve
    p.stencilAttachment.texture = dev.makeTexture(descriptor: sd); p.stencilAttachment.loadAction = .clear
    let cb = r.queue.makeCommandBuffer()!
    r.encode(cb, p, visible: visible, background: background, spacing: 48, pxPerUnit: Double(w) / visible.width,
             page: CGRect(x: 0, y: -1e9, width: 1600, height: CanvasView.pageUnits.height + 1e9), images: images, items: items)
    cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: w * h * 4)
    out.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }   // BGRA -> RGBA
    return px
}

private func footprintMB() -> Double {
    var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// A request for `data` as a file.
private func req(_ d: Data, _ name: String) -> ImagePageRequest { ImagePageRequest(data: d, source: ImageSource(kind: .file, fileName: name)) }

func imageChecks(_ check: (Bool, String) -> Void) {
    // These checks spin the run loop (tiles load in the background): an autosave queued by any canvas here would run. The
    // bench never saves (AppPaths.offline); check it before anything is drawn.
    // Saving may only ever reach a throwaway TRACKPAD_DRAW_DATA folder, never the real one.
    let real = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path + "/" + AppPaths.folderName)
    let safe = !AppPaths.persists || (AppPaths.override.map { URL(fileURLWithPath: $0).standardized.path != URL(fileURLWithPath: real).standardized.path } ?? false)
    guard safe else { check(false, "the bench would save to \(AppPaths.notebookPath): stopping"); return }
    check(safe, "the image checks can't reach the real notebook (saving \(AppPaths.persists ? "only to " + AppPaths.dataDir : "off"); they spin the run loop)")
    let tmp = NSTemporaryDirectory() + "scrawl-image-bench-\(getpid())"
    try? FileManager.default.removeItem(atPath: tmp)
    ImageStore.root = tmp + "/Images"; ImageStore.cacheRoot = tmp + "/ImageCache"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let card = testCard(1600, 1000)
    let pngData = encode(card, .png)

    // MARK: 1. every format
    do {
        let rotated = testCard(600, 400)
        let formats: [(String, Data, String, Int, Int)] = [
            ("PNG", pngData, "png", 1600, 1000),
            ("JPEG", encode(card, .jpeg, props: [kCGImageDestinationLossyCompressionQuality: 0.9]), "jpeg", 1600, 1000),
            ("HEIC", encode(card, .heic), "heic", 1600, 1000),
            ("TIFF", encode(card, .tiff), "tiff", 1600, 1000),
            ("GIF", encode(testCard(300, 200), .gif), "gif", 300, 200),
            ("PDF (first of 2 pages)", testPDF(), "pdf", ImageStore.pdfPixelWidth, Int((Double(ImageStore.pdfPixelWidth) * 792 / 612).rounded())),
            ("screenshot (Display P3 PNG, 144 dpi)", encode(testCard(1512, 982, space: CGColorSpace(name: CGColorSpace.displayP3)!), .png, props: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]), "png", 1512, 982),
            ("JPEG, EXIF orientation 6 (rotated 90°)", encode(rotated, .jpeg, props: [kCGImagePropertyOrientation: 6]), "jpeg", 400, 600),
            ("PNG with transparency", encode(testCard(500, 300, alpha: true), .png), "png", 500, 300),
        ]
        for (name, data, ext, w, h) in formats {
            do {
                let a = try ImageStore.importImage(data)
                let stored = FileManager.default.contents(atPath: a.path) ?? Data()
                let r = a.full(build: false)
                check(a.ext == ext && a.pixelWidth == w && a.pixelHeight == h && sha(stored) == sha(data) && r != nil && r!.width == w,
                      "import \(name): stored byte for byte (\(stored.count) B, sha \(sha(stored).prefix(8)) = original), \(a.pixelWidth) x \(a.pixelHeight) px (want \(w) x \(h)), .\(a.ext), decoded")
            } catch { check(false, "import \(name): \(error)") }
        }
        // The rotated JPEG is upright: its top-left 64 px checker (drawn in the unrotated picture's top-left) ends up at the
        // top-right after a 90° clockwise turn (orientation 6).
        let a = try! ImageStore.importImage(encode(rotated, .jpeg, props: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1]))
        let r = a.full()!
        func dark(_ x: Int, _ y: Int) -> Int { let p = (r.base + y * r.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self); return Int(p[0]) + Int(p[1]) + Int(p[2]) }
        var tr = 0, tl = 0
        for y in 0..<60 { for x in 0..<60 { tr += dark(r.width - 1 - x, y); tl += dark(x, y) } }
        check(tr < tl, "orientation 6: the picture is drawn upright (its corner checker at the top right: \(tr / 3600) vs top left \(tl / 3600))")
        let refusals: [(String, Data)] = [("text file", Data("hello".utf8)), ("empty", Data()), ("truncated PNG", pngData.prefix(40))]
        for (n, d) in refusals {
            var e: Error?; do { _ = try ImageStore.importImage(d) } catch let x { e = x }
            check(e != nil, "import refuses a \(n) (\(e?.localizedDescription ?? "accepted"))")
        }
        do {
            let big = encode(CGContext(data: nil, width: 12000, height: 11000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.makeImage()!, .png)
            var e: Error?; do { _ = try ImageStore.importImage(big) } catch let x { e = x }
            check(e != nil && (e!.localizedDescription.contains("too large")), "a 132-megapixel picture is refused with a message (\(e?.localizedDescription ?? "accepted"))")
        }
    }

    // MARK: 2. the page: placement, GPU pixels
    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 860), device: nil)
    let top = c.camera.page.height
    let asset = try! ImageStore.importImage(pngData)
    let page = c.newImagePage(PreparedImagePage(asset: asset, request: req(pngData, "card.png")))
    let obj = c.doc.images.first!
    check(page == 1 && c.pageIndex == 1 && c.pages.count == 2 && obj.frame == CGRect(x: 0, y: top - 1000, width: 1600, height: 1000) && c.doc.strokes.isEmpty,
          "a new page from a picture: after the last page and opened, the picture at the page's width at its top (frame \(obj.frame), page top \(String(format: "%.1f", top)))")
    check(c.camera.zoom == 1 && abs(c.camera.visible.maxY - top) < 1e-9 && c.camera.visible.minX == 0, "the new page is viewed from its top at zoom 1 (visible \(c.camera.visible))")
    check(c.doc.keptWriting && c.doc.created != nil, "an image page never shows the 'filled a screen' note, and has its date")
    do {
        let r = c.renderer!
        // 1:1 (1 page unit = 1 picture pixel): every pixel the picture's own.
        let vis = obj.frame
        let d = r.images.draws(c.doc.images, visible: vis, pxPerUnit: 1, sync: true)
        let gpu = gpuRender(r, visible: vis, w: 1600, h: 1000, background: 1, images: d)
        let ref = rasterBytes(asset.full()!)
        let pd = diff(gpu, ref)
        check(pd.max <= 1, "GPU, 1:1: the picture lands pixel for pixel on its frame (largest difference \(pd.max)/255, mean \(String(format: "%.4f", pd.mean)); a 1 px shift would be ~\(diff(Array(gpu.dropFirst(4)) + [0, 0, 0, 0], ref).max))")
        let original = rgba(card)
        check(diff(ref, original).max == 0, "the decoded copy is the PNG's pixels exactly")
        // Part of the page around the picture's corner, at 2 px per unit: the paper's grid outside, the picture inside.
        let around = CGRect(x: 1500, y: top - 1050, width: 150, height: 100)
        let d2 = r.images.draws(c.doc.images, visible: around, pxPerUnit: 2, sync: true)
        let g2 = gpuRender(r, visible: around, w: 300, h: 200, background: 0, images: d2)
        func at(_ px: [UInt8], _ x: Int, _ y: Int, _ w: Int) -> [UInt8] { Array(px[(y * w + x) * 4..<(y * w + x) * 4 + 3]) }
        // Picture pixel (1550, 990) from the top-left -> page (1550.25, top-990.25): view px (100.5, 120.5)-ish from the top.
        let inside = at(g2, 20, 20, 300), want = at(ref, 1510, 990 - 950 + 0, 1600)   // rough: only colour class checked
        let outsideRight = at(g2, 250, 20, 300), below = at(g2, 20, 180, 300)
        check(outsideRight == [204, 209, 217] || outsideRight.allSatisfy { $0 > 150 }, "outside the page's right edge: the desk (\(outsideRight))")
        check(below == [255, 255, 255], "below the picture: plain paper (\(below))")
        _ = inside; _ = want
        // Tiled: a 5000 x 3000 picture at 1:1 over a region crossing tile edges (1,024 px tiles): still exact.
        let wide = testCard(5000, 3000), wideData = encode(wide, .png)
        let wa = try! ImageStore.importImage(wideData)
        let tiled = c.newImagePage(PreparedImagePage(asset: wa, request: req(wideData, "wide.png")))
        let wo = c.pages[tiled].images[0]
        let k = wo.frame.width / 5000   // page units per picture pixel
        let region = CGRect(x: wo.frame.minX + 900 * k, y: wo.frame.maxY - 2200 * k, width: 1300 * k, height: 1300 * k)
        ImageTextures.maxSyncTiles = 100   // all of them now (the app makes 6 at most and lets the preview stand in)
        let dt = r.images.draws(c.pages[tiled].images, visible: region, pxPerUnit: 1 / k, sync: true)
        ImageTextures.maxSyncTiles = 6
        let gt = gpuRender(r, visible: region, w: 1300, h: 1300, images: dt)
        let rt = rasterBytes(wa.full()!, x: 900, y: 900, w: 1300, h: 1300)
        let td = diff(gt, rt)
        check(wa.tiled && r.images.stats.tiles == 9 && td.max <= 1, "GPU, tiled 5000 x 3000 at 1:1 across 9 tiles' edges: exact (largest difference \(td.max), \(r.images.stats.tiles) tiles drawn, \(r.images.stats.previews) previews)")
        // The app's own synchronous draw (a snapshot): 6 tiles now, the preview for the other 3, the same picture.
        r.images.dropAll()
        let d6 = r.images.draws(c.pages[tiled].images, visible: region, pxPerUnit: 1 / k, sync: true)
        let g6 = gpuRender(r, visible: region, w: 1300, h: 1300, images: d6)
        let s6 = r.images.stats, m6 = diff(g6, rt)
        check(s6.tiles == 6 && s6.previews == 3 && m6.mean < 8, "a snapshot makes at most 6 tiles synchronously, the preview stands in for the rest (\(s6.tiles) tiles, \(s6.previews) previews; mean difference from the full picture \(String(format: "%.2f", m6.mean)))")
        // Zoomed out to a quarter: the preview, close to a CoreGraphics reduction of the picture.
        let whole = wo.frame, ow = 1250, oh = 750
        let dz = r.images.draws(c.pages[tiled].images, visible: whole, pxPerUnit: Double(ow) / whole.width, sync: true)
        let gz = gpuRender(r, visible: whole, w: ow, h: oh, images: dz)
        let zd = diff(gz, rgba(wide, ow, oh))
        check(r.images.stats.previews == 1 && r.images.stats.tiles == 0 && zd.mean < 6, "GPU, zoomed out to 25%: one preview quad, mean difference from a CoreGraphics reduction \(String(format: "%.2f", zd.mean))/255 (largest \(zd.max), at the 1 px lines)")
        // Tiles not loaded yet: the preview stands in for them (no hole), then they load in the background.
        r.images.dropAll()
        let da = r.images.draws(c.pages[tiled].images, visible: region, pxPerUnit: 1 / k, sync: false)
        check(da.quads.isEmpty || r.images.stats.tiles == 0, "async: the first frame draws no tile before it's loaded (\(r.images.stats))")
        let t0 = Date()
        while r.images.loadingCount > 0 && Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        let db = r.images.draws(c.pages[tiled].images, visible: region, pxPerUnit: 1 / k, sync: false)
        let dc = r.images.draws(c.pages[tiled].images, visible: region, pxPerUnit: 1 / k, sync: false)
        _ = db
        check(r.images.stats.tiles == 9 && dc.quads.count == 9, String(format: "async: the preview and tiles load off the main thread in %.0f ms, then the 9 tiles are drawn", Date().timeIntervalSince(t0) * 1000))
        c.goToPage(1)
    }

    // MARK: 3. exports and Copy: the picture under the ink
    let wave = (0..<80).map { StrokePoint(p: CGPoint(x: 200 + Double($0) * 10, y: top - 400 + sin(Double($0) / 6) * 60), pressure: 0.6) }
    c.testAddStroke(wave, sizePt: 6)
    let inkBounds = c.doc.strokes[0].bounds
    do {
        let e = c.pageExport(ExportOptions(format: .png, scale: 1, area: .page, background: .paper))
        check(e.rect == CGRect(x: 0, y: top - 1000, width: 1600, height: 1000), "Export Page's area on an image page is the picture (\(e.rect))")
        let png = rgba(e.image()!)
        let ref = rasterBytes(asset.full()!)
        // Away from the ink, the PNG is the picture exactly; on the ink, it's dark.
        var off = 0, maxd = 0
        for y in 0..<1000 { for x in 0..<1600 {
            let p = CGPoint(x: Double(x) + 0.5, y: top - Double(y) - 0.5)
            guard !inkBounds.insetBy(dx: -3, dy: -3).contains(p) else { continue }
            let i = (y * 1600 + x) * 4; let d = max(abs(Int(png[i]) - Int(ref[i])), abs(Int(png[i + 1]) - Int(ref[i + 1])), abs(Int(png[i + 2]) - Int(ref[i + 2])))
            maxd = max(maxd, d); if d > 2 { off += 1 }
        } }
        let mid = wave[40].p, mi = (Int(top - mid.y) * 1600 + Int(mid.x)) * 4
        check(maxd <= 2 && png[mi] < 40 && png[mi + 1] < 40, "PNG export (1 px per unit): the picture's pixels exactly off the ink (largest difference \(maxd), \(off) off), the ink on top (\(png[mi]),\(png[mi + 1]),\(png[mi + 2]))")
        // SVG: the picture embedded as its own PNG bytes, under the ink; renders back like the PNG.
        let svg = c.pageExport(ExportOptions(format: .svg, scale: 1, area: .page, background: .paper)).svg()
        let b64 = svg.range(of: "base64,").map { r -> String in let rest = svg[r.upperBound...]; return String(rest.prefix { $0 != "\"" }) } ?? ""
        let embedded = Data(base64Encoded: b64) ?? Data()
        let order = (svg.range(of: "<g id=\"images\">")?.lowerBound ?? svg.endIndex) < (svg.range(of: "<g id=\"ink\"")?.lowerBound ?? svg.startIndex)
        check(sha(embedded) == sha(pngData) && order && svg.contains("xmlns:xlink"), "SVG: the picture embedded as base64 of its original PNG bytes (\(embedded.count) B, same sha), drawn before the ink")
        if let svgImg = NSImage(data: Data(svg.utf8)) {
            let ctx = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 1600 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            svgImg.draw(in: NSRect(x: 0, y: 0, width: 1600, height: 1000)); NSGraphicsContext.restoreGraphicsState()
            let back = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 1600 * 1000 * 4))
            let sd = diff(back, png)
            check(sd.mean < 3, "SVG renders back (CoreSVG) like the PNG: mean difference \(String(format: "%.2f", sd.mean)), largest \(sd.max)")
        } else { check(false, "SVG with a picture loads in NSImage") }
        // PDF (Export All Pages as PDF and Copy's PDF): the picture inside.
        let pdfURL = URL(fileURLWithPath: tmp + "/all.pdf")
        try? c.exportPDF(to: pdfURL)
        let doc = PDFDocument(url: pdfURL)
        if let p = doc?.page(at: 1) {
            let b = p.bounds(for: .mediaBox)
            let thumb = p.thumbnail(of: NSSize(width: 400, height: 250), for: .mediaBox)
            let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let got = rgba(cg, 400, 250), want = rgba(e.image()!, 400, 250)
            let pdfd = diff(got, want)
            check(doc!.pageCount == 3 && abs(b.width - 800) < 0.5 && abs(b.height - 500) < 0.5 && pdfd.mean < 8,
                  "PDF export: \(doc!.pageCount) pages; the image page is \(Int(b.width)) x \(Int(b.height)) pt (the picture) and looks like the PNG (mean difference \(String(format: "%.2f", pdfd.mean)))")
        } else { check(false, "PDF export readable") }
        // A JPEG picture goes into a PDF as its own JPEG data (no re-encoding): DCTDecode in the file.
        let jd = encode(card, .jpeg, props: [kCGImageDestinationLossyCompressionQuality: 0.8])
        let ja = try! ImageStore.importImage(jd)
        let jpg = PageExport(strokes: [], rect: CGRect(x: 0, y: 0, width: 1600, height: 1000), pageWidth: 1600, pageTop: 1000, paper: 0,
                             options: ExportOptions(), images: [ImageObject(id: 1, asset: ja, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), source: ImageSource(kind: .file), added: nil)])
        let pdf = jpg.pdfData() ?? Data()
        check(pdf.range(of: Data("DCTDecode".utf8)) != nil && pdf.count < jd.count * 2 + 20_000, "a JPEG picture goes into a PDF as its own JPEG data (DCTDecode; PDF \(pdf.count / 1024) KB for a \(jd.count / 1024) KB JPEG)")
        // Transparent background: the picture's own transparency stays; no paper under it.
        let ta = try! ImageStore.importImage(encode(testCard(500, 300, alpha: true), .png))
        let tp = PageExport(strokes: [], rect: CGRect(x: 0, y: 0, width: 500, height: 300), pageWidth: 1600, pageTop: 1000, paper: 1,
                            options: ExportOptions(format: .png, scale: 1, area: .page, background: .transparent),
                            images: [ImageObject(id: 2, asset: ta, frame: CGRect(x: 0, y: 0, width: 500, height: 300), source: ImageSource(kind: .file), added: nil)])
        let tpx = rgba(tp.image()!), hole = ((300 / 4 + 300 / 8) * 500 + 500 / 2 + 500 / 8) * 4   // the cleared block (rows from the top)
        let pp = PageExport(strokes: [], rect: tp.rect, pageWidth: 1600, pageTop: 1000, paper: 1, options: ExportOptions(format: .png, scale: 1, area: .page, background: .paper), images: tp.images)
        let ppx = rgba(pp.image()!)
        check(tpx[hole + 3] == 0 && ppx[hole] == 255 && ppx[hole + 1] == 255 && ppx[hole + 2] == 255,
              "a transparent picture: clear with the Transparent background (alpha \(tpx[hole + 3])), plain white (no grid) under it with Paper (\(ppx[hole]),\(ppx[hole + 1]),\(ppx[hole + 2]))")
    }
    do {   // Copy as Image of a selection over the picture and the ink.
        let sel = CGRect(x: 150, y: top - 520, width: 500, height: 240)
        c.setSelectionForTest(sel)
        guard let clip = c.selectionClip(ExportOptions(format: .png, scale: 2, area: .page, background: .paper)), let img = NSBitmapImageRep(data: clip.png)?.cgImage else { check(false, "Copy as Image"); return }
        let got = rgba(img)
        let r = c.renderer!
        let gpu = gpuRender(r, visible: sel, w: img.width, h: img.height, background: c.tools.background,
                            images: r.images.draws(c.doc.images, visible: sel, pxPerUnit: 2, sync: true),
                            items: c.doc.strokes.map { s in .init(mesh: r.makeMesh(strokeMesh(s.points, radii: s.radii, pxPerUnit: 4)), verts: nil, color: SIMD4(s.color.x, s.color.y, s.color.z, 1) * s.color.w) })
        let cd = diff(got, gpu)
        let ref = rgba(card.cropping(to: CGRect(x: 150, y: 520 - 240, width: 500, height: 240))!, img.width, img.height)
        let picd = diff(got, ref)
        check(img.width == 1000 && img.height == 480 && cd.mean < 4 && picd.mean < 25 && picd.mean > 0.5,
              "Copy as Image over a picture: \(img.width) x \(img.height) px; like the canvas's render of the selection (mean difference \(String(format: "%.2f", cd.mean))), the picture under the ink (vs the picture alone \(String(format: "%.1f", picd.mean)): ink adds a little)")
        c.setSelectionForTest(nil)
    }

    // MARK: 4. scratch-out, the eraser, Clear Page: never the picture
    do {
        let before = c.doc.images.map(\.id)
        c.drawMode = true
        // A word-sized squiggle on the picture, to scratch out.
        c.testAddStroke((0..<40).map { StrokePoint(p: CGPoint(x: 1100 + Double($0) * 4, y: top - 600 + sin(Double($0) / 3) * 25), pressure: 0.6) }, sizePt: 4)
        let w = c.doc.strokes.last!
        // A word-sized stroke, and a scratch over it (a fast zig-zag through the canvas's own input path).
        let pad = Multitouch.padMM
        var t = 100.0
        func frame(_ p: CGPoint?) {   // one finger at canvas point p
            t += 0.008
            let cs: [Contact] = p.map { q in
                let v = c.camera.visible, n = CGPoint(x: (q.x - v.minX) / v.width, y: (q.y - v.minY) / v.height)
                return [Contact(id: 9, state: 4, norm: n, mm: CGPoint(x: n.x * pad.width, y: n.y * pad.height), pressure: 60, size: 0.6, major: 7.5)]
            } ?? []
            c.handle(cs, arrival: t + 1000, sensorT: t)
        }
        func zigzag(over r: CGRect, id: Int32) {   // back and forth along the word, 8 legs of 40 ms, drifting down it
            for leg in 0..<8 { for j in 0..<5 {
                let f = Double(j) / 5, y = r.maxY - r.height * (Double(leg) + f) / 8
                frame(CGPoint(x: leg % 2 == 0 ? r.minX + r.width * f : r.maxX - r.width * f, y: y))
            } }
            for _ in 0..<4 { frame(nil) }
        }
        ScratchOut.enabled = true
        zigzag(over: w.bounds, id: 9)
        let erased = !c.doc.strokes.contains { $0 === w }
        check(erased && c.doc.images.map(\.id) == before && c.doc.images.count == 1, "scratch-out over ink on a picture: the ink goes (\(erased)), the picture stays (\(c.doc.strokes.count) strokes left)")
        c.undo()
        check(c.doc.strokes.contains { $0 === w } && c.doc.images.map(\.id) == before, "undo after the scratch-out: the word is back, the same picture")
        // Over the picture alone (no ink under it): nothing to scratch out; the picture stays.
        let n0 = c.doc.strokes.count
        zigzag(over: CGRect(x: 1100, y: top - 900, width: 220, height: 60), id: 10)
        check(c.doc.images.map(\.id) == before, "a scratch over the picture alone never touches it (strokes \(n0) -> \(c.doc.strokes.count): the zig-zag stays as ink)")
        if c.doc.strokes.count > n0 { c.undo() }
        c.doc.dropEmptyUndo()
        var tools = c.tools; tools.tool = .eraser; c.tools = tools
        for k in 0...40 { frame(CGPoint(x: 100 + Double(k) * 30, y: top - 300 - Double(k % 5) * 40)) }
        frame(nil); frame(nil)
        tools.tool = .pen; c.tools = tools
        check(c.doc.images.map(\.id) == before, "the eraser dragged across the picture leaves it (\(c.doc.strokes.count) strokes left)")
        c.clearPage()
        c.testAddStroke(wave)
        let inkBefore = c.doc.strokes.count
        c.clearPage()
        check(c.doc.strokes.isEmpty && c.doc.images.map(\.id) == before, "Clear Page clears the ink, not the picture")
        c.undo()
        check(c.doc.strokes.count == inkBefore && inkBefore > 0 && c.doc.images.map(\.id) == before, "undo after Clear Page: the ink is back (\(c.doc.strokes.count)), the picture the same object")
        c.drawMode = false
    }

    // MARK: 5. the notebook
    do {
        let f = c.notebookFile()
        let data = try! f.encoded()
        let d = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 860), device: nil)
        d.load(try! NotebookFile.decode(data))
        guard let a = c.pages[1].images.first, let b = d.pages[1].images.first else { check(false, "notebook round trip: page 2 lost its picture"); return }
        let onDisk = FileManager.default.contents(atPath: b.asset.path) ?? Data()
        check(d.pages.count == c.pages.count && b.id == a.id && b.frame == a.frame && b.asset.key == a.asset.key && b.source == a.source && sha(onDisk) == sha(pngData)
              && d.pages[1].strokes.count == c.pages[1].strokes.count && d.pages[2].images.count == 1,
              "notebook round trip: pages, image objects (id, frame, source \(b.source.label)), the ink; the picture file's bytes identical (\(data.count) B notebook, picture not inside it)")
        check(data.count < 60_000, "the notebook refers to pictures, it doesn't hold them: \(data.count) B for 2 pictures of \(pngData.count / 1024) KB+")
        // Undo history with pictures survives: undo on the reopened page puts back what undo did before.
        d.goToPage(1); let n = d.doc.strokes.count; d.clearPage(); d.undo()
        check(d.doc.images.first?.id == a.id && d.doc.strokes.count == n && n > 0, "undo on a reopened image page keeps the picture (\(n) strokes back)")
        // Notebooks without pictures are written exactly as before (no new keys): the same bytes as 0.1.5's file format.
        let plain = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 860), device: nil)
        plain.testAddStroke(wave); plain.newPage(); plain.testAddStroke(wave, tool: .highlighter)
        let mine = try! plain.notebookFile().encoded()
        let old = try! PropertyListDecoder().decode(Notebook015.self, from: mine)
        let e = PropertyListEncoder(); e.outputFormat = .binary
        let theirs = try! e.encode(old)
        check(mine == theirs, "a notebook without pictures is byte-identical to the 0.1.5 format (\(mine.count) B, re-encoded by the 0.1.5 structure: \(theirs.count) B)")
        // 0.1.5 reading a notebook with pictures: it opens (the pictures' keys are skipped), every page and stroke there.
        do {
            let o = try PropertyListDecoder().decode(Notebook015.self, from: data)
            check(o.pages.count == c.pages.count && o.strokes.count == f.strokes.count, "0.1.5's reader opens a notebook with pictures: \(o.pages.count) pages, \(o.strokes.count) strokes (pictures skipped)")
        } catch { check(false, "0.1.5's reader opens a notebook with pictures: \(error)") }
        // Unused picture files go after a save; used ones and recent ones stay.
        let keep = d.notebookSnapshot().imageKeys
        let stray = try! ImageStore.importImage(encode(testCard(64, 64), .png))
        let recent = ImageStore.collectGarbage(keep: keep)
        let removed = ImageStore.collectGarbage(keep: keep, grace: 0)
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: ImageStore.root)) ?? [])
        check(recent.isEmpty && removed.contains(stray.fileName) && keep.allSatisfy { k in left.contains { $0.hasPrefix(k) } },
              "garbage collection: a picture no page refers to is removed (\(removed)), never within a minute of being written, never one in use (\(left.count) left)")
    }

    // MARK: 6. thumbnails
    do {
        let tall = testCard(1000, 3000), tallData = encode(tall, .png)
        let ta = try! ImageStore.importImage(tallData)
        let i = c.newImagePage(PreparedImagePage(asset: ta, request: req(tallData, "tall.png")))
        let page = c.camera.page
        let region = ThumbnailCache.region(c.pages[i].strokes, images: c.pages[i].images, page: page)
        check(abs(region.maxY - page.height) < 0.5 && abs(region.width - page.width) < 0.5, "a tall picture's tile shows it from the top, full width (region \(region))")
        let img = ThumbnailCache.shared.image(for: c.pages[i], page: page)!
        let thumb = rgba(img)
        let want = rgba(tall.cropping(to: CGRect(x: 0, y: 0, width: 1000, height: Int(1000 * page.height / page.width)))!, img.width, img.height)
        let upper = img.width * img.height * 4 * 6 / 10   // above the fade
        let td = diff(Array(thumb[0..<upper]), Array(want[0..<upper]))
        // A small picture low on a page with no ink: the tile frames the picture (not the page's empty top).
        let sp = c.newImagePage(PreparedImagePage(asset: try! ImageStore.importImage(encode(testCard(300, 200), .png)), request: req(Data(), "small.png")))
        let so = c.pages[sp].images[0], low = so.with(frame: CGRect(x: 1000, y: -400, width: 300, height: 200), id: 9999)
        c.pages[sp].setImages([low], undoable: false)
        let sr = ThumbnailCache.region(c.pages[sp].strokes, images: c.pages[sp].images, page: page)
        check(sr.contains(low.frame) && sr.maxY < page.height - 100, "a small picture low on an empty page: its tile frames the picture (region \(sr))")
        check(td.mean < 12 && ThumbnailCache.continuesBelow(c.pages[i].strokes, images: c.pages[i].images, region), "the tile is the picture's top (mean difference \(String(format: "%.1f", td.mean)) above the fade), fading out below (more picture under it)")
    }

    // MARK: 7. the Inbox's page.json
    do {
        let dir = tmp + "/Inbox/abc.scrawlpage"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try! pngData.write(to: URL(fileURLWithPath: dir + "/page.png"))
        let json = """
        {"version": 1, "image": "page.png", "coordinateScale": 2,
         "source": {"url": "https://www.example.com/a", "title": "An example page", "capturedAt": "2026-11-03T19:40:00Z"},
         "strokes": [{"tool": "highlighter", "color": "#fdd663", "size": 10, "points": [[100, 50, 0.5], [400, 50, 0.5], [700, 250, 0.7]]}]}
        """
        try! Data(json.utf8).write(to: URL(fileURLWithPath: dir + "/page.json"))
        let r = try! Inbox.parse(dir, id: "abc")
        let p = c.newImagePage(PreparedImagePage(asset: try! ImageStore.importImage(r.data), request: r))
        let s = c.pages[p].strokes.first!, f = c.pages[p].images[0].frame
        // CSS (400, 50) x dpr 2 = picture px (800, 100) on a 1600 px picture placed 1600 units wide: page (800, top - 100).
        let hit = s.points.contains { abs($0.p.x - 800) < 0.01 && abs($0.p.y - (top - 100)) < 0.01 }
        check(r.importId == "abc" && c.pages[p].importId == "abc" && r.source.kind == .web && r.source.label == "“An example page” · example.com" && hit && s.tool == .highlighter && abs(s.color.w - 0.35) < 1e-6
              && abs(s.size - 20) < 1e-9 && f.minY == top - 1000,
              "Inbox page.json: picture + a highlighter stroke in CSS px (dpr 2) lands on the picture where it was drawn (size \(s.size) units), source “\(r.source.label)”")
        for (bad, why) in [("{\"version\": 2, \"image\": \"page.png\"}", "a newer version"), ("{\"image\": \"../x.png\"}", "a path outside the item"), ("{\"image\": \"page.png\", \"strokes\": [{\"tool\": \"pen\", \"color\": \"red\", \"size\": 2, \"points\": [[1,2]]}]}", "a bad colour")] {
            try! Data(bad.utf8).write(to: URL(fileURLWithPath: dir + "/page.json"))
            var e: Error?; do { _ = try Inbox.parse(dir, id: "abc") } catch let x { e = x }
            check(e != nil, "Inbox refuses \(why) (\(e?.localizedDescription ?? "accepted"))")
        }
    }

    // MARK: 8. a 4000 x 12000 screenshot: import, memory, frames
    do {
        let shotData = autoreleasepool { encode(testCard(4000, 12000), .png) }
        let m0 = footprintMB()
        let t0 = Date()
        let a = try! ImageStore.importImage(shotData)
        let tImport = Date().timeIntervalSince(t0)
        let m1 = footprintMB()
        let big = CanvasView(frame: NSRect(x: 0, y: 0, width: 1512, height: 945), device: nil)
        let i = big.newImagePage(PreparedImagePage(asset: a, request: req(shotData, "long.png")))
        let r = big.renderer!
        // Live-like frames: scroll down the whole picture at zoom 1 and 3, 2x backing, ink on top (200 strokes, a live one).
        var items: [Renderer.DrawItem] = []
        for k in 0..<200 {
            let pts = (0..<120).map { StrokePoint(p: CGPoint(x: Double(k % 20) * 78 + Double($0) / 3, y: top - Double(k / 20) * 95 - 60 + sin(Double($0) / 10) * 20), pressure: 0.5) }
            items.append(.init(mesh: r.makeMesh(strokeMesh(pts, radii: strokeRadii(pts, size: 3, brush: .of(.pen)))), verts: nil, color: SIMD4(0, 0, 0, 1)))
        }
        let w = 3024, h = 1890
        let dev = r.device
        func tex(_ f: MTLPixelFormat, ms: Bool) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = .renderTarget; d.storageMode = .private
            if ms { d.textureType = .type2DMultisample; d.sampleCount = Renderer.sampleCount }
            return dev.makeTexture(descriptor: d)!
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex(.bgra8Unorm, ms: true); rpd.colorAttachments[0].resolveTexture = tex(.bgra8Unorm, ms: false)
        rpd.colorAttachments[0].loadAction = .clear; rpd.colorAttachments[0].storeAction = .multisampleResolve
        rpd.stencilAttachment.texture = tex(.stencil8, ms: true); rpd.stencilAttachment.loadAction = .clear
        var cpu: [Double] = [], gpu: [Double] = [], cpuNo: [Double] = [], gpuNo: [Double] = [], maxLoading = 0
        let frameH = big.pages[i].images[0].frame.height
        var mBase = 0.0
        // Without the picture first (the baseline's memory includes the render targets), then with it.
        for withImage in [false, true] {
            if withImage { mBase = footprintMB() }
            for zoom in [1.0, 3.0, 0.999] {   // 0.999: back up the page at zoom 1 (tiles evicted on the way down load again)
            for f0 in 0..<240 {
                let f = zoom == 0.999 ? 239 - f0 : f0
                let vw = 1600 / zoom, vh = vw * Double(h) / Double(w)
                let y = top - (frameH - vh) * Double(f) / 239 - vh
                let vis = CGRect(x: zoom == 3 ? 400 : 0, y: y, width: vw, height: vh)
                do {
                    let c0 = CACurrentMediaTime()
                    let d = withImage ? big.imageDraws(big.pages[i], vis: vis, pxPerUnit: Double(w) / vw, sync: false) : Renderer.ImageDraws()
                    let cb = r.queue.makeCommandBuffer()!
                    r.encode(cb, rpd, visible: vis, background: 1, spacing: 48, pxPerUnit: Double(w) / vw, images: d, items: items)
                    cb.commit()
                    let cms = (CACurrentMediaTime() - c0) * 1000
                    cb.waitUntilCompleted()
                    let gms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    if withImage { cpu.append(cms); gpu.append(gms); maxLoading = max(maxLoading, r.images.stats.loading) } else { cpuNo.append(cms); gpuNo.append(gms) }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))   // let finished tiles arrive, as between display ticks
            }
            }
        }
        func p(_ v: [Double], _ q: Double) -> Double { let s = v.sorted(); return s[Int(q * Double(s.count - 1))] }
        let m2 = footprintMB()
        print(String(format: "4000 x 12000 PNG (%.1f MB): import (hash, store, decode, preview) %.0f ms; footprint %.0f MB before, %.0f after import, %.0f with render targets (no picture drawn), %.0f after scrolling it at zoom 1, 3, 1; GPU textures %.0f MB",
                     Double(shotData.count) / 1e6, tImport * 1000, m0, m1, mBase, m2, Double(r.images.residentBytes) / 1_048_576))
        check(tImport < 3, String(format: "  import in %.2f s (off the main thread)", tImport))
        check(p(cpu, 0.95) - p(cpuNo, 0.95) < 0.5, String(format: "  CPU per frame scrolling it (zoom 1 and 3): p50 %.2f / p95 %.2f ms with the picture, %.2f / %.2f without (+%.2f ms at p95; budget +0.5)",
                                                         p(cpu, 0.5), p(cpu, 0.95), p(cpuNo, 0.5), p(cpuNo, 0.95), p(cpu, 0.95) - p(cpuNo, 0.95)))
        check(p(gpu, 0.5) - p(gpuNo, 0.5) < 1.0 && p(gpu, 0.5) < 4, String(format: "  GPU per frame: p50 %.2f / p95 %.2f ms with the picture, %.2f / %.2f without (+%.2f ms at p50; budget +1 ms, 4 ms)",
                                                                       p(gpu, 0.5), p(gpu, 0.95), p(gpuNo, 0.5), p(gpuNo, 0.95), p(gpu, 0.5) - p(gpuNo, 0.5)))
        check(Double(r.images.residentBytes) <= Double(ImageTextures.budget) && m2 - mBase < Double(ImageTextures.budget >> 20) + 64 && m1 - m0 < 64,
              String(format: "  memory: import +%.0f MB; drawing it +%.0f MB = GPU textures %.0f MB (budget %d MB; the decoded copy is memory-mapped from the cache file, not counted)",
                     m1 - m0, m2 - mBase, Double(r.images.residentBytes) / 1_048_576, ImageTextures.budget >> 20))
        _ = maxLoading
    }
}

/// The notebook file's structure in 0.1.5 (what an older Scrawl decodes and writes).
private struct Notebook015: Codable {
    var formatVersion = 1
    var appVersion = ""
    var pageIndex = 0
    var nextStrokeId = 1
    var pages: [Page] = []
    var strokes: [NotebookFile.StrokeFile] = []
    struct Page: Codable {
        var strokes: [Int]; var undo: [[Int]]; var redo: [[Int]]; var zoom: Double; var centerX: Double; var centerY: Double
        var created: Double?; var edited: Double?; var kept: Bool?
    }
}
