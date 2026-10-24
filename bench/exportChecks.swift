// Export: PNG of a page and a multi-page vector PDF. The PDF is read back with PDFKit, rendered, and
// compared with the PNG of the same page (the ink must land in the same places).
import AppKit
import PDFKit

func exportChecks(_ check: (Bool, String) -> Void) {
    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    func wave(_ x: Double, _ y: Double) -> [StrokePoint] {
        (0..<60).map { StrokePoint(p: CGPoint(x: x + Double($0) * 8, y: y + sin(Double($0) / 5) * 30), pressure: 0.6) }
    }
    for k in 0..<4 { c.testAddStroke(wave(100, 800 - Double(k) * 120)) }
    c.testAddStroke(wave(200, 500), tool: .highlighter)
    c.testAddStroke(wave(100, -900))            // below the first screen: pages are infinite downward
    c.newPage()
    c.testAddStroke(wave(300, 400))
    c.newPage()                                  // an empty third page
    c.goToPage(0)
    let dir = NSTemporaryDirectory() + "td-export-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let pdfURL = URL(fileURLWithPath: dir + "/all.pdf"), pngURL = URL(fileURLWithPath: dir + "/p1.png")
    do { try c.exportPDF(to: pdfURL); try c.exportPNG(to: pngURL, pxPerUnit: 1, page: 0) } catch { check(false, "export writes files: \(error)"); return }
    guard let pdf = PDFDocument(url: pdfURL), let png = NSImage(contentsOf: pngURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        check(false, "exported PDF and PNG open"); return
    }
    let b0 = pdf.page(at: 0)!.bounds(for: .mediaBox)
    let wantH = (c.camera.page.height + 930 + 20) * CanvasView.pdfPointsPerUnit
    check(pdf.pageCount == 3 && b0.width == 800 && abs(b0.height - wantH) < 20,
          "PDF has every page (\(pdf.pageCount)/3); page 1 is \(Int(b0.width)) x \(Int(b0.height)) pt, down to the ink 900 units below the first screen (want ~\(Int(wantH)))")
    let raw = (try? Data(contentsOf: pdfURL)) ?? Data()
    let text = String(decoding: raw, as: UTF8.self)
    check(!text.contains("/Image"), "PDF is vector (no images), \(raw.count / 1024) KB for 7 strokes")
    // Render PDF page 1 at the PNG's size and compare where the ink is.
    let w = png.width, h = png.height
    func ink(_ draw: (CGContext) -> Void) -> [Bool] {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(ctx)
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(w * h)).map { p[$0 * 4] < 200 || p[$0 * 4 + 2] < 200 }
    }
    let a = ink { $0.draw(png, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    let bb = ink { ctx in
        ctx.scaleBy(x: Double(w) / b0.width, y: Double(h) / b0.height)
        pdf.page(at: 0)!.draw(with: .mediaBox, to: ctx)
    }
    // Ink in one with ink within 1 px in the other (anti-aliased edges differ between the two renderers).
    func near(_ m: [Bool], _ i: Int) -> Bool {
        let x = i % w, y = i / w
        for dy in -1...1 { for dx in -1...1 { let xx = x + dx, yy = y + dy; if xx >= 0, yy >= 0, xx < w, yy < h, m[yy * w + xx] { return true } } }
        return false
    }
    let aN = a.filter { $0 }.count, bN = bb.filter { $0 }.count
    let aIn = a.indices.filter { a[$0] && near(bb, $0) }.count, bIn = bb.indices.filter { bb[$0] && near(a, $0) }.count
    let fa = Double(aIn) / Double(max(aN, 1)), fb = Double(bIn) / Double(max(bN, 1))
    check(fa > 0.99 && fb > 0.99 && aN > 2000, String(format: "PDF page 1 draws the same ink as the PNG export (%.1f%% / %.1f%% of ink pixels match within 1 px; %d px)", fa * 100, fb * 100, aN))
    let p2 = pdf.page(at: 1)!.bounds(for: .mediaBox), p3 = pdf.page(at: 2)!.bounds(for: .mediaBox)
    check(p2.height < b0.height && p3.width == 800, "each page keeps its own length (page 2 \(Int(p2.height)) pt, empty page 3 \(Int(p3.height)) pt)")
    // A full notebook: 2,000 handwriting-sized strokes.
    let big = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    for k in 0..<2000 { big.testAddStroke((0..<40).map { StrokePoint(p: CGPoint(x: Double(k % 50) * 30 + Double($0) * 0.6, y: 900 - Double(k / 50) * 25 + sin(Double($0) / 4) * 6), pressure: 0.5) }) }
    let t0 = CFAbsoluteTimeGetCurrent()
    try? big.exportPDF(to: URL(fileURLWithPath: dir + "/big.pdf"))
    let dt = CFAbsoluteTimeGetCurrent() - t0
    let size = (try? FileManager.default.attributesOfItem(atPath: dir + "/big.pdf")[.size] as? Int) ?? 0
    check(dt < 5 && size > 0, String(format: "2,000-stroke page exports to PDF in %.2f s, %.1f MB", dt, Double(size) / 1e6))
    try? FileManager.default.removeItem(atPath: dir)
}
