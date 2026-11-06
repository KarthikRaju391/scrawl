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

    /// The page's ink as an image (cropped to it), then Vision's text: the first line and everything.
    static func read(_ strokes: [Stroke], page: CGSize) -> (String, String) {
        // The ink with plenty of paper round it (Vision misread "world" as "SIUM" cropped tight).
        guard var ink = strokes.first?.bounds else { return ("", "") }
        for st in strokes.dropFirst() { ink = ink.union(st.bounds) }
        let m = max(ink.width, ink.height) * 0.35 + 20
        var r = ink.insetBy(dx: -m, dy: -m)
        r = CGRect(x: max(r.minX, 0), y: r.minY, width: min(r.maxX, page.width) - max(r.minX, 0), height: min(r.maxY, page.height) - r.minY)   // on the page
        let w = min(1800.0, max(900.0, r.width * 1.2))
        guard r.width > 0, r.height > 0, let img = PageImage.render(strokes, rect: r, pageWidth: page.width, pageTop: page.height,
                                         px: CGSize(width: w, height: w * r.height / r.width), fast: true) else { return ("", "") }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["en-US"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        let obs = (req.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.3 }
            .sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.03 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
        let lines = obs.compactMap { $0.topCandidates(1).first?.string }
        let title = String((lines.first ?? "").prefix(40))
        return (title, lines.joined(separator: " "))
    }
}
