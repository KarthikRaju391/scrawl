// Page titles and search for the overview: each page's handwriting read on-device with Vision, on a
// background queue, once per page version (only while the overview is open). The first line becomes the
// tile's title; all of it is what ⌘F searches. Nothing leaves the Mac.
import AppKit
import Vision

final class PageTitles {
    struct Entry { var version: Int; var title: String; var text: String }
    private var cache: [Int: Entry] = [:]   // by Document.uid
    private var pending = Set<Int>()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "scrawl.pagetitles", qos: .background)   // after the thumbnails
    private(set) var reads = 0

    func entry(_ doc: Document) -> Entry? { lock.lock(); defer { lock.unlock() }; return cache[doc.uid] }
    func title(_ doc: Document) -> String { entry(doc)?.title ?? "" }
    func matches(_ doc: Document, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return (entry(doc)?.text.lowercased() ?? "").contains(q)
    }

    /// Read any page whose title is out of date; `ready` runs on the main queue after each one.
    func refresh(_ docs: [Document], page: CGSize, ready: @escaping () -> Void) {
        for doc in docs {
            let key = doc.uid
            lock.lock()
            let fresh = cache[key]?.version == doc.version, busy = pending.contains(key)
            if !fresh && !busy { pending.insert(key) }
            lock.unlock()
            guard !fresh && !busy else { continue }
            if doc.strokes.isEmpty { lock.lock(); cache[key] = Entry(version: doc.version, title: "", text: ""); pending.remove(key); lock.unlock(); continue }
            let strokes = doc.strokes, v = doc.version
            queue.async { [weak self] in
                let (title, text) = Self.read(strokes, page: page)
                guard let self else { return }
                self.lock.lock(); self.cache[key] = Entry(version: v, title: title, text: text); self.pending.remove(key); self.reads += 1; self.lock.unlock()
                DispatchQueue.main.async(execute: ready)
            }
        }
    }

    /// Reading resolution: as before (the crop 900-1800 px wide), never under 0.75 px per page unit (handwriting written
    /// at 100% is ~40 units tall: ~30 px), and a large crop is read in tiles of at most 3,000 px, overlapping by 15% so a word
    /// on a seam is whole in one of them.
    static let minPxPerUnit = 0.75, maxTilePx = 3000.0

    /// The page's ink, wherever it is on the infinite canvas (0.1.7.1: it was cut to the page's column, so writing beside or
    /// above it was missed), as images, then Vision's text: the topmost line (the title) and everything, top to bottom,
    /// left to right, in page coordinates (not Vision's result order).
    static func read(_ strokes: [Stroke], page: CGSize) -> (String, String) {
        // The ink with plenty of paper round it (Vision misread "world" as "SIUM" cropped tight).
        guard var ink = strokes.first?.bounds else { return ("", "") }
        for st in strokes.dropFirst() { ink = ink.union(st.bounds) }
        let m = min(max(ink.width, ink.height) * 0.35 + 20, 400)
        let r = ink.insetBy(dx: -m, dy: -m)
        let scale = max(min(1800.0, max(900.0, r.width * 1.2)) / r.width, minPxPerUnit)
        let tile = maxTilePx / scale
        func starts(_ lo: Double, _ hi: Double) -> [Double] {
            guard hi - lo > tile else { return [lo] }
            var a: [Double] = [], x = lo
            while x + tile < hi { a.append(x); x += tile * 0.85 }
            return a + [hi - tile]
        }
        var found: [(rect: CGRect, text: String)] = []
        for ty in starts(r.minY, r.maxY) {
            for tx in starts(r.minX, r.maxX) {
                let t = CGRect(x: tx, y: ty, width: min(tile, r.maxX - tx), height: min(tile, r.maxY - ty))
                guard let img = PageImage.render(strokes, rect: t, pageWidth: page.width, pageTop: page.height,
                                                 px: CGSize(width: (t.width * scale).rounded(), height: (t.height * scale).rounded()), fast: true) else { continue }
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.recognitionLanguages = ["en-US"]
                req.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: img).perform([req])
                for o in req.results ?? [] {
                    guard let c = o.topCandidates(1).first, c.confidence > 0.3 else { continue }
                    let b = o.boundingBox   // normalised, origin bottom-left, like the page (y up)
                    found.append((CGRect(x: t.minX + b.minX * t.width, y: t.minY + b.minY * t.height, width: b.width * t.width, height: b.height * t.height), c.string))
                }
            }
        }
        // Tiles overlap: keep the larger of two readings of the same place (a word cut by a seam is the smaller one).
        var kept: [(rect: CGRect, text: String)] = []
        for f in found.sorted(by: { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }) {
            let area = f.rect.width * f.rect.height
            if kept.contains(where: { let i = $0.rect.intersection(f.rect); return !i.isNull && i.width * i.height > 0.6 * area }) { continue }
            kept.append(f)
        }
        // Lines: readings whose heights overlap by half the smaller one are one line; lines top to bottom, words left to right.
        var lines: [[(rect: CGRect, text: String)]] = []
        for f in kept.sorted(by: { $0.rect.maxY > $1.rect.maxY }) {
            if let k = lines.firstIndex(where: { line in line.contains { g in
                min(g.rect.maxY, f.rect.maxY) - max(g.rect.minY, f.rect.minY) > 0.5 * min(g.rect.height, f.rect.height) } }) { lines[k].append(f) }
            else { lines.append([f]) }
        }
        let text = lines.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }
        return (String((text.first ?? "").prefix(40)), text.joined(separator: " "))
    }
}
