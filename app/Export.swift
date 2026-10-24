// Export: the current page as PNG, every page as one vector PDF. Pages are infinite downward, so each
// export runs from the top of the page to just below the lowest ink.
import AppKit

extension CanvasView {
    /// The part of a page to export, in page units (y up): full width, top of the page to the lowest ink.
    func exportRect(_ d: Document) -> CGRect {
        let lowest = min(d.strokes.map(\.bounds.minY).min() ?? 0, 0) - 20
        return CGRect(x: 0, y: lowest, width: camera.page.width, height: camera.page.height - lowest)
    }

    private func drawInk(_ d: Document, in ctx: CGContext) {
        for s in d.strokes {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(s.color.x), green: CGFloat(s.color.y), blue: CGFloat(s.color.z), alpha: CGFloat(s.color.w)))
            ctx.addPath(strokePath(s.points, size: s.size, brush: Brush.of(s.tool)))
            ctx.fillPath(using: .winding)   // one fill per stroke: the highlighter's alpha is applied once
        }
    }

    /// The current page (or page `index`) as a PNG, `pxPerUnit` pixels per page unit (page is 1,600 units wide).
    func exportPNG(to url: URL, pxPerUnit: Double = 2, page index: Int? = nil) throws {
        let d = pages[index ?? pageIndex], r = exportRect(d)
        let w = Int(r.width * pxPerUnit), h = Int(r.height * pxPerUnit)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: pxPerUnit, y: pxPerUnit)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        drawInk(d, in: ctx)
        guard let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }

    /// Every page, in order, as vector paths in one PDF (800 pt wide pages; long pages are tall).
    static let pdfPointsPerUnit = 0.5
    func exportPDF(to url: URL) throws {
        let k = Self.pdfPointsPerUnit
        var box = CGRect(x: 0, y: 0, width: camera.page.width * k, height: camera.page.height * k)
        let info = [kCGPDFContextCreator: "Trackpad Draw", kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent] as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info) else { throw CocoaError(.fileWriteUnknown) }
        for d in pages {
            let r = exportRect(d)
            var media = CGRect(x: 0, y: 0, width: r.width * k, height: r.height * k)
            ctx.beginPage(mediaBox: &media)
            ctx.setFillColor(.white); ctx.fill(media)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -r.minX, y: -r.minY)
            drawInk(d, in: ctx)
            ctx.endPage()
        }
        ctx.closePDF()
    }
}
