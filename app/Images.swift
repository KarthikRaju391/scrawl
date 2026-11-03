// Image objects: pictures placed on a page under the ink (dragged in, pasted, File › New Page from Image…, or a web
// snapshot from the browser extension through the Inbox). An image object is an id, an asset (the picture's bytes) and a
// frame in page units (y up, anywhere: nothing assumes it lies inside the page's column). A page has any number of them,
// in z-order, all under its ink.
//
// Storage: the original file, byte for byte (no resampling or re-encoding), lives next to the notebook in Images/, named
// by its SHA-256 (a picture imported twice is stored once). The notebook file only refers to it, so an autosave writes
// the same few kilobytes as before, however large the pictures. An image file is written (atomically) before any
// notebook that refers to it can be saved; one no notebook refers to any more is removed after a save.
//
// Drawing: the decoded pixels (premultiplied RGBA, sRGB) are cached as a raw file in the caches folder and memory-mapped:
// reclaimable by the system, never decoded twice, and the GPU tiles (ImageRender.swift) are filled straight from it. A
// reduced copy (the preview, at most 8,192 px on its long side) is drawn when zoomed out, under tiles not loaded yet, in
// thumbnails, and the page map.
import AppKit
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Where an image came from: shown in the page header ("from Screenshot.png", "from “Title” · example.com").
struct ImageSource: Equatable {
    enum Kind: String { case file, paste, web }
    var kind: Kind
    var fileName: String?
    var url: String?
    var title: String?

    /// A short label for the page header.
    var label: String {
        var host: String? { url.flatMap { URL(string: $0)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } }
        func clip(_ s: String, _ n: Int = 48) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        switch kind {
        case .web:
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return "“\(clip(t))”" + (host.map { " · \($0)" } ?? "") }
            return host ?? url.map { clip($0) } ?? "a web page"
        case .file: return fileName.map { clip($0) } ?? "an image file"
        case .paste: return fileName.map { clip($0) } ?? "a pasted image"
        }
    }
}

/// A decoded picture: premultiplied RGBA, 8 bits, sRGB, rows top to bottom, memory-mapped from the caches folder.
final class Raster: @unchecked Sendable {
    let width: Int, height: Int, bytesPerRow: Int
    let base: UnsafeRawPointer
    private let length: Int
    init?(path: String, width: Int, height: Int) {
        let bpr = width * 4, len = bpr * height
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, Int(st.st_size) == len, len > 0 else { return nil }
        guard let p = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        self.width = width; self.height = height; bytesPerRow = bpr; length = len; base = UnsafeRawPointer(p)
        _ = utimes(path, nil)   // last use: the cache trim keeps recently used pictures
    }
    deinit { munmap(UnsafeMutableRawPointer(mutating: base), length) }
    /// The pixels as a CGImage (no copy: it reads the mapping, and keeps it mapped while the image lives).
    var cgImage: CGImage? {
        let len = length
        let data = Unmanaged.passRetained(self)
        guard let provider = CGDataProvider(dataInfo: data.toOpaque(), data: base, size: len, releaseData: { info, _, _ in
            if let info { Unmanaged<Raster>.fromOpaque(info).release() }
        }) else { data.release(); return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draw into a new raster file at `path` (atomically: a temporary name, then renamed). `draw` gets a context of
    /// width x height pixels, y up, cleared to transparent.
    static func write(path: String, width: Int, height: Int, draw: (CGContext) -> Void) -> Bool {
        let bpr = width * 4, len = bpr * height
        let tmp = path + ".tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        guard ftruncate(fd, off_t(len)) == 0, let p = mmap(nil, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED else {
            close(fd); unlink(tmp); return false
        }
        var ok = false
        if let ctx = CGContext(data: p, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .high
            draw(ctx); ctx.flush(); ok = true
        }
        msync(p, len, MS_ASYNC); munmap(p, len); close(fd)
        guard ok, rename(tmp, path) == 0 else { unlink(tmp); return false }
        return true
    }
}

/// One picture's bytes, shared by every image object showing it.
final class ImageAsset: @unchecked Sendable {
    /// SHA-256 of the bytes (hex, 32 characters): the file's name in Images/.
    let key: String
    /// The file's extension ("png", "jpeg", "heic", "tiff", "pdf", ...).
    let ext: String
    /// Pixels as shown (EXIF orientation applied; a PDF's first page as rasterised for the screen).
    let pixelWidth: Int, pixelHeight: Int
    var isPDF: Bool { ext == "pdf" }
    var fileName: String { "\(key).\(ext)" }
    var path: String { ImageStore.root + "/" + fileName }

    init(key: String, ext: String, pixelWidth: Int, pixelHeight: Int) {
        self.key = key; self.ext = ext; self.pixelWidth = max(pixelWidth, 1); self.pixelHeight = max(pixelHeight, 1)
    }

    /// The original bytes (memory-mapped), or nil if the file is gone.
    func data() -> Data? { try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }

    // MARK: rasters

    /// The preview's size: the whole picture when it is at most 2,048 px on its long side, else at least a quarter of its
    /// size (tiles take over when zoomed in further) and at least 2,048 px, at most 8,192 px on its long side.
    var previewSize: (width: Int, height: Int) {
        let long = max(pixelWidth, pixelHeight)
        let target = long <= 2048 ? long : min(8192, max(2048, (long + 3) / 4))
        let s = Double(target) / Double(long)
        return (max(Int((Double(pixelWidth) * s).rounded()), 1), max(Int((Double(pixelHeight) * s).rounded()), 1))
    }
    /// Whether the full-resolution picture is drawn from tiles (when the preview is smaller than it).
    var tiled: Bool { previewSize.width < pixelWidth }

    private let lock = NSLock()
    private var fullRaster: Raster?, previewRaster: Raster?
    private var failed = false
    private var fullPath: String { ImageStore.cacheRoot + "/\(key)-\(pixelWidth)x\(pixelHeight).rgba" }
    private var previewPath: String { let p = previewSize; return ImageStore.cacheRoot + "/\(key)-\(p.width)x\(p.height).preview.rgba" }

    /// The decoded picture, from the cache (fast) or decoded now (`build`, slow: hundreds of ms for a large screenshot).
    func full(build: Bool = true) -> Raster? {
        lock.lock(); defer { lock.unlock() }
        if let r = fullRaster { return r }
        if let r = Raster(path: fullPath, width: pixelWidth, height: pixelHeight) { fullRaster = r; return r }
        guard build, !failed else { return nil }
        ImageStore.ensureCacheDir()
        let ok = Raster.write(path: fullPath, width: pixelWidth, height: pixelHeight) { ctx in self.drawDecoded(in: ctx, width: pixelWidth, height: pixelHeight) }
        fullRaster = ok ? Raster(path: fullPath, width: pixelWidth, height: pixelHeight) : nil
        if fullRaster == nil { failed = true }
        return fullRaster
    }
    /// The reduced picture (the full one when it is small).
    func preview(build: Bool = true) -> Raster? {
        guard tiled else { return full(build: build) }
        lock.lock()
        if let r = previewRaster { lock.unlock(); return r }
        let p = previewSize
        if let r = Raster(path: previewPath, width: p.width, height: p.height) { previewRaster = r; lock.unlock(); return r }
        lock.unlock()
        guard build, let src = full(build: true)?.cgImage else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let r = previewRaster { return r }
        _ = Raster.write(path: previewPath, width: p.width, height: p.height) { ctx in ctx.draw(src, in: CGRect(x: 0, y: 0, width: p.width, height: p.height)) }
        previewRaster = Raster(path: previewPath, width: p.width, height: p.height)
        return previewRaster
    }
    /// The preview's pixels are mapped (making its texture needs no decode).
    var previewMapped: Bool { lock.lock(); defer { lock.unlock() }; return tiled ? previewRaster != nil : fullRaster != nil }
    /// Both rasters are ready without decoding.
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return fullRaster != nil && (!tiled || previewRaster != nil) }
    /// Decode (if needed) on the background queue, then `done` on the main queue.
    func prepare(_ done: (() -> Void)? = nil) {
        ImageStore.decodeQueue.async { _ = self.preview(); DispatchQueue.main.async { done?() } }
    }
    /// Unmap the rasters (they map again on the next use).
    func dropRasters() { lock.lock(); fullRaster = nil; previewRaster = nil; lock.unlock() }

    /// The original decoded into `ctx` (width x height pixels): orientation applied, colour converted to sRGB; a PDF's
    /// first page on white.
    private func drawDecoded(in ctx: CGContext, width: Int, height: Int) {
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let data = data() else { return }
        if isPDF {
            guard let page = ImageStore.pdfFirstPage(data) else { return }
            ctx.setFillColor(.white); ctx.fill(box)
            ImageStore.drawPDFPage(page, in: box, ctx: ctx)
            return
        }
        guard let img = ImageStore.decodedImage(data, maxSide: max(width, height)) else { return }
        ctx.draw(img, in: box)
    }

    // MARK: drawing into exports

    /// Draw the picture into `rect` (page units, y up) of a CoreGraphics context (exports, Copy, thumbnails).
    /// `vector`: a PDF context; a JPEG goes in as its own compressed data, a PDF page as vectors.
    /// `preview`: a thumbnail-sized drawing (the reduced picture).
    func draw(in ctx: CGContext, rect: CGRect, vector: Bool = false, preview usePreview: Bool = false) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.interpolationQuality = .high
        if vector, isPDF, let d = data(), let page = ImageStore.pdfFirstPage(d) {
            ctx.clip(to: rect); ctx.setFillColor(.white); ctx.fill(rect)
            ImageStore.drawPDFPage(page, in: rect, ctx: ctx); return
        }
        if vector, ext == "jpeg" || ext == "jpg", let d = data(), ImageStore.orientation(d) == 1,
           let provider = CGDataProvider(data: d as CFData), let img = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            ctx.draw(img, in: rect); return
        }
        if let img = (usePreview ? preview() : full())?.cgImage { ctx.draw(img, in: rect) }
    }

    /// The bytes an SVG embeds, and their MIME type: the original for PNG, JPEG and GIF (what browsers show); a PNG of
    /// the decoded picture for TIFF and PDF, a JPEG (quality 0.92) for HEIC photos.
    func svgEmbed() -> (mime: String, data: Data)? {
        switch ext {
        case "png": return data().map { ("image/png", $0) }
        case "jpeg", "jpg": if let d = data(), ImageStore.orientation(d) == 1 { return ("image/jpeg", d) }
        case "gif": return data().map { ("image/gif", $0) }
        default: break
        }
        guard let img = full()?.cgImage else { return nil }
        let photo = ext == "heic" || ext == "heif" || ext == "jpeg" || ext == "jpg"
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, (photo ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, photo ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (photo ? "image/jpeg" : "image/png", out as Data)
    }
}

/// An image placed on a page: immutable (a move or resize will be a new object with a new id, like a stroke).
final class ImageObject {
    let id: Int
    let asset: ImageAsset
    /// Page units, y up. May lie anywhere (outside the page's column too).
    let frame: CGRect
    let source: ImageSource
    let added: Date?
    init(id: Int, asset: ImageAsset, frame: CGRect, source: ImageSource, added: Date?) {
        self.id = id; self.asset = asset; self.frame = frame; self.source = source; self.added = added
    }
    /// The default placement on a page `pageWidth` wide with its top at `pageTop`: the page's width, at its top.
    static func defaultFrame(for a: ImageAsset, pageWidth: Double, pageTop: Double) -> CGRect {
        let h = pageWidth * Double(a.pixelHeight) / Double(a.pixelWidth)
        return CGRect(x: 0, y: pageTop - h, width: pageWidth, height: h)
    }
    /// Page units per image pixel (horizontal).
    var unitsPerPixel: Double { frame.width / Double(asset.pixelWidth) }
}

enum ImageImportError: LocalizedError {
    case unreadable, unsupported(String), tooLarge(String), storage(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: return "The image couldn't be read."
        case .unsupported(let t): return "\(t) isn't an image Scrawl can open."
        case .tooLarge(let s): return "The image is too large (\(s))."
        case .storage(let s): return "The image couldn't be saved (\(s))."
        }
    }
}

enum ImageStore {
    /// Largest picture: 65,536 px on a side, 120 megapixels, 200 MB of file. Larger ones are refused with a message
    /// (a 2,880 x 36,000 full-page screenshot is 104 MP: fine).
    static let maxSide = 65_536, maxPixels = 120_000_000, maxBytes = 200_000_000
    /// A PDF's first page is drawn at this many pixels across (2.5 per page unit at the page's width), and as vectors in
    /// PDF exports.
    static let pdfPixelWidth = 4000

    /// Images/ next to the notebook; a folder of its own for runs that don't save (tests, the bench).
    nonisolated(unsafe) static var root: String = AppPaths.persists ? AppPaths.dataDir + "/Images"
        : NSTemporaryDirectory() + "Scrawl-images-\(getpid())"
    /// Decoded pixels: the caches folder (TRACKPAD_DRAW_DATA: a folder inside it).
    nonisolated(unsafe) static var cacheRoot: String = {
        if let o = AppPaths.override { return o + "/ImageCache" }
        if !AppPaths.persists { return NSTemporaryDirectory() + "Scrawl-imagecache-\(getpid())" }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.path
        return base + "/" + AppPaths.folderName + "/Images"
    }()
    static let decodeQueue = DispatchQueue(label: "scrawl.images.decode", qos: .userInitiated, attributes: .concurrent)
    static func ensureCacheDir() { try? FileManager.default.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var assets: [String: ImageAsset] = [:]

    /// The one asset for a stored file (loading a notebook).
    static func asset(key: String, ext: String, width: Int, height: Int) -> ImageAsset {
        lock.lock(); defer { lock.unlock() }
        if let a = assets[key] { return a }
        let a = ImageAsset(key: key, ext: ext, pixelWidth: width, pixelHeight: height)
        assets[key] = a
        return a
    }

    /// Check, store and decode a picture (any queue but the main one: hashing and decoding a large picture takes a
    /// while). The bytes are written to Images/ unchanged before this returns.
    static func importImage(_ data: Data) throws -> ImageAsset {
        guard !data.isEmpty else { throw ImageImportError.unreadable }
        guard data.count <= maxBytes else { throw ImageImportError.tooLarge("\(data.count / 1_000_000) MB; at most \(maxBytes / 1_000_000) MB") }
        let (ext, w, h) = try inspect(data)
        guard w <= maxSide, h <= maxSide, w * h <= maxPixels else {
            throw ImageImportError.tooLarge("\(w) × \(h) px; at most \(maxSide) px on a side and \(maxPixels / 1_000_000) megapixels")
        }
        let key = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = asset(key: key, ext: ext, width: w, height: h)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: a.path) {
            do { try data.write(to: URL(fileURLWithPath: a.path), options: .atomic) }
            catch { throw ImageImportError.storage(error.localizedDescription) }
        } else {
            _ = utimes(a.path, nil)   // fresh again: the garbage collector's grace period starts now
        }
        guard a.preview() != nil else { throw ImageImportError.unreadable }
        return a
    }

    /// The file type and the size shown (orientation applied; a PDF's first page at `pdfPixelWidth`).
    static func inspect(_ data: Data) throws -> (ext: String, width: Int, height: Int) {
        if data.starts(with: Array("%PDF".utf8)) {
            guard let page = pdfFirstPage(data) else { throw ImageImportError.unreadable }
            let b = page.getBoxRect(.cropBox), rot = (page.rotationAngle % 360 + 360) % 360
            let (bw, bh) = rot == 90 || rot == 270 ? (b.height, b.width) : (b.width, b.height)
            guard bw > 0, bh > 0 else { throw ImageImportError.unreadable }
            return ("pdf", pdfPixelWidth, max(Int((Double(pdfPixelWidth) * bh / bw).rounded()), 1))
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0, let type = CGImageSourceGetType(src) as String? else { throw ImageImportError.unreadable }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else {
            throw ImageImportError.unsupported(UTType(type)?.localizedDescription ?? type)
        }
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        let ext = UTType(type)?.preferredFilenameExtension ?? "img"
        return (ext, o >= 5 ? h : w, o >= 5 ? w : h)
    }
    static func orientation(_ data: Data) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 1 }
        return props[kCGImagePropertyOrientation] as? Int ?? 1
    }
    /// The first frame, full size, upright.
    static func decodedImage(_ data: Data, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if orientation(data) == 1 { return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: maxSide, kCGImageSourceShouldCacheImmediately: false] as CFDictionary)
    }
    static func pdfFirstPage(_ data: Data) -> CGPDFPage? {
        guard let p = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(p), !doc.isEncrypted || doc.unlockWithPassword(""), doc.numberOfPages > 0 else { return nil }
        return doc.page(at: 1)
    }
    /// The page's crop box (its rotation applied) stretched onto `rect`.
    static func drawPDFPage(_ page: CGPDFPage, in rect: CGRect, ctx: CGContext) {
        let b = page.getBoxRect(.cropBox), rot = (page.rotationAngle % 360 + 360) % 360
        let (bw, bh) = rot == 90 || rot == 270 ? (b.height, b.width) : (b.width, b.height)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / bw, y: rect.height / bh)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: bw, height: bh), rotate: 0, preserveAspectRatio: false))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    /// A minute; TRACKPAD_DRAW_IMAGE_GRACE (seconds) for tests.
    static let grace = ProcessInfo.processInfo.environment["TRACKPAD_DRAW_IMAGE_GRACE"].flatMap(Double.init) ?? 60
    /// Off when the notebook on disk couldn't be read (kept aside: its pictures must stay).
    nonisolated(unsafe) static var collects = true
    /// Remove stored pictures no notebook refers to any more: after a save, `keep` = every picture the saved notebook and
    /// the undo of page deletes still refer to. Files changed in the last `grace` seconds stay (a picture being imported is
    /// written before the page that shows it exists).
    @discardableResult
    static func collectGarbage(keep: Set<String>, grace: TimeInterval = ImageStore.grace) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        lock.lock(); let known = Set(assets.keys); lock.unlock()
        var removed: [String] = []
        for n in names where !n.hasPrefix(".") {
            let key = String(n.split(separator: ".").first ?? "")
            // Only pictures this run has seen in use: a file no page referred to when the notebook was opened (an older
            // version saved it without its pictures; a notebook restored from a backup may still want it) stays.
            guard !keep.contains(key), known.contains(key) else { continue }
            let p = root + "/" + n
            if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < grace { continue }
            if (try? fm.removeItem(atPath: p)) != nil { removed.append(n) }
        }
        if !removed.isEmpty {   // their decoded copies too
            let gone = Set(removed.compactMap { $0.split(separator: ".").first.map(String.init) })
            for n in (try? fm.contentsOfDirectory(atPath: cacheRoot)) ?? [] where gone.contains(String(n.prefix(32))) { try? fm.removeItem(atPath: cacheRoot + "/" + n) }
            lock.lock(); for k in gone { assets[k] = nil }; lock.unlock()
        }
        return removed
    }

    /// Keep the decoded-pixels cache under `limit` bytes: the least recently used files go first (they are decoded
    /// again when needed). Also removes leftovers of interrupted writes.
    static func trimCache(limit: Int = 3_000_000_000) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheRoot) else { return }
        var files: [(path: String, size: Int, used: Date)] = []
        for n in names {
            let p = cacheRoot + "/" + n
            if n.contains(".tmp-") { try? fm.removeItem(atPath: p); continue }
            guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
            files.append((p, (a[.size] as? Int) ?? 0, (a[.modificationDate] as? Date) ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files.sorted(by: { $0.used < $1.used }) where total > limit { try? fm.removeItem(atPath: f.path); total -= f.size }
    }
}

// MARK: - Bringing a picture in

/// A stroke given in the picture's own coordinates: x right, y down from its top-left corner, in units of
/// `coordinateScale` pixels (the extension's CSS pixels with scale = devicePixelRatio).
struct ImportedStroke {
    var tool: ToolKind
    var rgb: SIMD3<Float>
    var size: Double                       // diameter at full pressure, in coordinate units
    var points: [(x: Double, y: Double, pressure: Double)]
}

/// Everything a new image page is made from: the picture's bytes, where it came from, ink to put on it.
struct ImagePageRequest {
    var data: Data
    var source: ImageSource
    var strokes: [ImportedStroke] = []
    var coordinateScale = 1.0
    /// Set by the Inbox: a page already made from this item isn't made again.
    var importId: String?
}

/// A request whose picture is stored and decoded: making the page from it is instant (main thread).
struct PreparedImagePage {
    let asset: ImageAsset
    let request: ImagePageRequest
}

enum ImagePages {
    /// Store and decode the picture (call off the main thread).
    static func prepare(_ r: ImagePageRequest) throws -> PreparedImagePage {
        PreparedImagePage(asset: try ImageStore.importImage(r.data), request: r)
    }
    /// The strokes of `r`, in page units, on an image placed at `frame`.
    static func strokes(_ r: ImagePageRequest, asset: ImageAsset, frame: CGRect, maxStep: Double) -> [Stroke] {
        let k = frame.width / Double(asset.pixelWidth) * r.coordinateScale   // page units per coordinate unit
        return r.strokes.compactMap { s in
            guard !s.points.isEmpty, s.tool != .eraser, s.tool != .select else { return nil }
            let pts = s.points.map { StrokePoint(p: CGPoint(x: frame.minX + $0.x * k, y: frame.maxY - $0.y * k), pressure: min(max($0.pressure, 0), 1)) }
            let color = SIMD4<Float>(s.rgb.x, s.rgb.y, s.rgb.z, Float(Brush.of(s.tool).alpha))
            return Stroke(tool: s.tool, color: color, size: max(s.size * k, 0.05), points: pts, maxStep: maxStep)
        }
    }

    // MARK: the pasteboard and dropped files

    /// The image types read from a pasteboard or a drop, best first.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.png, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), .pdf, .tiff]
    static let fileTypes: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .pdf, .gif, .bmp, .webP, .image]

    /// Image files on the pasteboard (a copied or dragged file), else image data (a screenshot, an image copied from
    /// another app).
    static func requests(from pb: NSPasteboard, kind: ImageSource.Kind) -> [ImagePageRequest] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let files = urls.filter { u in fileTypes.contains { t in (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: t) ?? false } }
            if !files.isEmpty {
                return files.compactMap { u in (try? Data(contentsOf: u, options: .alwaysMapped)).map { ImagePageRequest(data: $0, source: ImageSource(kind: .file, fileName: u.lastPathComponent)) } }
            }
            if !urls.isEmpty { return [] }   // other files: not images
        }
        for t in pasteboardTypes { if let d = pb.data(forType: t), !d.isEmpty { return [ImagePageRequest(data: d, source: ImageSource(kind: kind))] } }
        return []
    }
    static func pasteboardHasImage(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: fileTypes.map(\.identifier)]) { return true }
        return pb.availableType(from: pasteboardTypes) != nil
    }
}
