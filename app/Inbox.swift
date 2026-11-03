// The Inbox: how another program (the browser extension's native-messaging host) adds an image page.
//
// A writer puts a folder `<id>.scrawlpage` into `<data folder>/Inbox/`, written first under a name starting with a dot
// and then renamed (so it is never seen half-written). Inside: `page.json` and the picture it names.
//
//   {"version": 1, "image": "page.png",
//    "source": {"url": "https://…", "title": "…", "fileName": null, "capturedAt": "2026-11-03T19:40:00Z"},
//    "coordinateScale": 2,
//    "strokes": [{"tool": "pen", "color": "#1a73e8", "size": 3, "points": [[x, y, pressure], …]}]}
//
// Stroke points are in the picture's own coordinates (x right, y down from its top-left), in units of `coordinateScale`
// pixels (a web page's CSS pixels with the device pixel ratio); `size` is the diameter at full pressure in those units.
// The running app sees a new item at once (it watches the folder; the distributed notification "<bundle id>.inbox"
// also works); otherwise it is taken at the next launch. The page is made after the last page; the open page changes to
// it unless you're drawing. When the notebook with the page is saved, the app writes `<id>.done.json`
// ({"ok": true, "page": N, "pages": M}, or {"ok": false, "error": "…"}) and removes the item. A page records its item's
// id, so an item is never made into two pages (a crash between the save and the removal).
import Foundation

enum InboxError: LocalizedError {
    case bad(String)
    var errorDescription: String? { if case .bad(let s) = self { return s }; return nil }
}

final class Inbox {
    static let suffix = ".scrawlpage"
    let dir: String
    /// A new item, read and checked (main queue). Call `finish` when it's done.
    var onItem: ((_ id: String, _ request: Result<ImagePageRequest, Error>) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var taken = Set<String>()
    private var observer: NSObjectProtocol?

    init(dir: String = AppPaths.dataDir + "/Inbox") { self.dir = dir }

    func start(notificationName: String? = Bundle.main.bundleIdentifier.map { $0 + ".inbox" }) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        removeOldResults()
        let fd = open(dir, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
            s.setEventHandler { [weak self] in self?.scan() }
            s.setCancelHandler { close(fd) }
            s.resume(); source = s
        }
        if let n = notificationName {
            observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(n), object: nil, queue: .main) { [weak self] _ in self?.scan() }
        }
        scan()
    }
    func stop() { source?.cancel(); source = nil; observer.map(DistributedNotificationCenter.default().removeObserver); observer = nil }

    /// Items waiting (not started yet).
    func scan() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for n in names.sorted() where n.hasSuffix(Self.suffix) && !n.hasPrefix(".") {
            let id = String(n.dropLast(Self.suffix.count))
            guard !taken.contains(id) else { continue }
            taken.insert(id)
            let r = Result { try Self.parse(dir + "/" + n, id: id) }
            onItem?(id, r)
        }
    }

    /// The item's result for its writer, then the item goes (a failed one is kept as `<id>.failed` to look at).
    func finish(_ id: String, page: Int?, pages: Int, error: String?) {
        var d: [String: Any] = ["ok": error == nil, "pages": pages]
        if let page { d["page"] = page + 1 }
        if let error { d["error"] = error }
        let item = dir + "/" + id + Self.suffix
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/" + id + ".done.json"), options: .atomic)
        }
        if error == nil { try? FileManager.default.removeItem(atPath: item) }
        else { try? FileManager.default.moveItem(atPath: item, toPath: dir + "/" + id + ".failed") }
        taken.remove(id)
    }

    /// Results nobody collected within a day.
    private func removeOldResults() {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".done.json") || n.hasSuffix(".failed") || n.hasPrefix(".tmp-") {
            let p = dir + "/" + n
            if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, Date().timeIntervalSince(m) > 86_400 { try? fm.removeItem(atPath: p) }
        }
    }

    /// Read an item folder into a request (no decoding yet).
    static func parse(_ path: String, id: String) throws -> ImagePageRequest {
        guard let j = FileManager.default.contents(atPath: path + "/page.json") else { throw InboxError.bad("no page.json") }
        guard let o = try JSONSerialization.jsonObject(with: j) as? [String: Any] else { throw InboxError.bad("page.json is not an object") }
        guard (o["version"] as? Int ?? 1) == 1 else { throw InboxError.bad("unsupported version \(o["version"] ?? "")") }
        guard let name = o["image"] as? String, !name.contains("/"), !name.hasPrefix(".") else { throw InboxError.bad("no image named") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/" + name), options: .alwaysMapped) else { throw InboxError.bad("can't read \(name)") }
        let src = o["source"] as? [String: Any] ?? [:]
        var r = ImagePageRequest(data: data, source: ImageSource(kind: src["url"] != nil ? .web : .file, fileName: src["fileName"] as? String,
                                                                 url: src["url"] as? String, title: src["title"] as? String))
        r.importId = id
        if let k = o["coordinateScale"] as? Double, k > 0, k.isFinite { r.coordinateScale = k }
        for (n, s) in ((o["strokes"] as? [[String: Any]]) ?? []).enumerated() {
            guard let t = ToolKind(rawValue: s["tool"] as? String ?? "pen"), t == .pen || t == .marker || t == .highlighter else { throw InboxError.bad("stroke \(n + 1): unknown tool") }
            guard let rgb = Self.color(s["color"] as? String ?? "#000000") else { throw InboxError.bad("stroke \(n + 1): color must be #rrggbb") }
            guard let size = (s["size"] as? Double) ?? (s["size"] as? Int).map(Double.init), size > 0, size.isFinite else { throw InboxError.bad("stroke \(n + 1): size") }
            var pts: [(x: Double, y: Double, pressure: Double)] = []
            for p in (s["points"] as? [[Double]]) ?? [] where p.count >= 2 && p.allSatisfy(\.isFinite) { pts.append((p[0], p[1], p.count > 2 ? p[2] : 0.5)) }
            guard !pts.isEmpty else { throw InboxError.bad("stroke \(n + 1): no points") }
            r.strokes.append(ImportedStroke(tool: t, rgb: rgb, size: size, points: pts))
        }
        return r
    }
    static func color(_ s: String) -> SIMD3<Float>? {
        guard s.hasPrefix("#"), s.count == 7, let v = Int(s.dropFirst(), radix: 16) else { return nil }
        return SIMD3(Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255, Float(v & 255) / 255)
    }
}
