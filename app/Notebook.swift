// Where things live, and the notebook file: every page, its strokes, its view and its undo/redo
// history, saved automatically (0.5 s after a change, atomically, and on quit).
import AppKit

/// How this process was launched. Test modes run in the background (never take focus) unless a test
/// explicitly asks for the foreground with --test-front.
enum Launch {
    static let args = CommandLine.arguments
    static let testing = args.contains { $0.hasPrefix("--test-") && $0 != "--test-front" && $0 != "--test-lock" }
    static let background = args.contains("--no-activate") || (testing && !args.contains("--test-front"))
    /// --offscreen or TRACKPAD_DRAW_OFFSCREEN (checks run while Karthik uses the Mac): no window of ours is ever put on screen.
    static let offscreen = background && (args.contains("--offscreen") || ProcessInfo.processInfo.environment["TRACKPAD_DRAW_OFFSCREEN"] != nil)
}

enum AppPaths {
    /// The notebook is only read and written by the real app, or by tests given their own folder:
    /// a test must never load or overwrite Karthik's pages.
    ///
    /// Only the app itself (a bundle) saves without TRACKPAD_DRAW_DATA: the bench and other command-line builds of these
    /// files never do, even if something makes them run the autosave's timer (an image bench check spinning the run loop
    /// wrote its canvas over the real notebook, 3 Nov).
    static var persists: Bool {
        if override != nil { return true }
        return !offline && !Launch.testing && Bundle.main.bundleIdentifier != nil
    }
    /// Set by the bench (and true for any process named "bench"): never touch the real notebook.
    nonisolated(unsafe) static var offline = ProcessInfo.processInfo.processName == "bench"

    /// Tests and development point everything at one folder with TRACKPAD_DRAW_DATA.
    static let override = ProcessInfo.processInfo.environment["TRACKPAD_DRAW_DATA"]

    /// The folder name under Application Support and Logs. Fixed here, not taken from the bundle, so a
    /// rename never strands anyone's pages (Migration moves the old "Trackpad Draw" folders).
    static let folderName = "Scrawl"
    /// Where this build keeps its notebook: the released app uses "Scrawl"; development builds use "Scrawl-dev", so a dev
    /// copy (or anything built from these files) can't write the real notebook (3 Nov).
    static var ownFolder: String {
        #if RELEASE
        return folderName
        #else
        return folderName + "-dev"
        #endif
    }

    /// ~/Library/Application Support/Scrawl: the notebook.
    static var dataDir: String {
        if let o = override { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        return base + "/" + ownFolder
    }
    /// ~/Library/Logs/Scrawl: watchdog log, crash notes, optional touch diagnostics. Local only.
    static var logsDir: String {
        if let o = override { return o }
        return NSHomeDirectory() + "/Library/Logs/" + ownFolder
    }
    static var notebookPath: String { dataDir + "/Notebook.tdnb" }

    static func ensure() {
        for d in [dataDir, logsDir] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
    }
}

/// Touch diagnostics (raw stroke log + session recording) are off unless turned on in Help >
/// Diagnostics. Development builds and tests turn them on.
enum Diagnostics {
    /// Development builds keep writing touch logs into the repo's data/ folder, as before.
    static var logsDir: String {
        if AppPaths.override != nil { return AppPaths.logsDir }
        #if RELEASE
        return AppPaths.logsDir
        #else
        return NSHomeDirectory() + "/code/trackpad-draw/data"
        #endif
    }
    /// The offline bench builds canvases but must not write logs.
    static var off = false
    static var enabled: Bool {
        if off { return false }
        if AppPaths.override != nil { return true }
        if let v = UserDefaults.standard.object(forKey: "diagnosticLogs") as? Bool { return v }
        #if RELEASE
        return false
        #else
        return true
        #endif
    }
}

/// Backups of the notebook, in its folder's Backups/ (3 Nov: a stray process wrote a 2-page canvas over 26 pages and
/// nothing could bring them back).
enum NotebookSafety {
    /// Pages and live strokes of the notebook on disk, as last written or read (nil: not known yet in this process).
    nonisolated(unsafe) static var onDisk: (path: String, pages: Int, strokes: Int)?

    static func counts(_ f: NotebookFile) -> (pages: Int, strokes: Int) { (f.pages.count, f.pages.reduce(0) { $0 + $1.strokes.count }) }

    /// Before a save: if it would leave under half the pages or half the strokes of the notebook on disk (and that
    /// notebook isn't tiny), copy the notebook to Backups/Notebook-YYYYMMDD-HHMM.tdnb first, keeping the newest `keep`.
    /// Returns the backup's path when one was made.
    @discardableResult
    static func backupIfShrinking(notebook: String, newPages: Int, newStrokes: Int, backupsDir: String, now: Date, keep: Int = 10) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: notebook) else { return nil }
        if onDisk?.path != notebook {
            guard let d = fm.contents(atPath: notebook), let f = try? NotebookFile.decode(d) else { return nil }
            let c = counts(f); onDisk = (notebook, c.pages, c.strokes)
        }
        guard let old = onDisk, old.pages + old.strokes >= 3 else { return nil }
        guard newPages * 2 < old.pages || newStrokes * 2 < old.strokes else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"; df.locale = Locale(identifier: "en_US_POSIX")
        var dest = backupsDir + "/Notebook-\(df.string(from: now)).tdnb"
        if fm.fileExists(atPath: dest) { df.dateFormat = "yyyyMMdd-HHmmss"; dest = backupsDir + "/Notebook-\(df.string(from: now)).tdnb" }
        do {
            try fm.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest) { try fm.copyItem(atPath: notebook, toPath: dest) }
        } catch { NSLog("Scrawl: shrink backup failed: \(error)"); return nil }
        prune(backupsDir, prefix: "Notebook-2", keep: keep)
        return dest
    }

    /// Once a day: copy the notebook to Backups/Notebook-daily-YYYYMMDD.tdnb, keeping the newest `keep` days.
    static func dailyBackup(notebook: String, backupsDir: String, now: Date, keep: Int = 7) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: notebook) else { return }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"; df.locale = Locale(identifier: "en_US_POSIX")
        let dest = backupsDir + "/Notebook-daily-\(df.string(from: now)).tdnb"
        guard !fm.fileExists(atPath: dest) else { return }
        do {
            try fm.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: notebook, toPath: dest)
        } catch { NSLog("Scrawl: daily backup failed: \(error)"); return }
        prune(backupsDir, prefix: "Notebook-daily-", keep: keep)
    }

    /// Keep the newest `keep` files with this prefix (names sort by date).
    private static func prune(_ dir: String, prefix: String, keep: Int) {
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".tdnb") }.sorted()
        for f in all.dropLast(keep) { try? fm.removeItem(atPath: dir + "/" + f) }
    }
}

// MARK: - File format (binary property list)

struct NotebookFile: Codable {
    var formatVersion = 1
    var appVersion = ""
    var pageIndex = 0
    var nextStrokeId = 1
    var pages: [PageFile] = []
    var strokes: [StrokeFile] = []   // every stroke referenced by a page or its undo/redo history
    // 0.1.6: image objects. Every field below is optional and left out when a notebook has no pictures, so such a
    // notebook is written exactly as before; older versions skip these keys (they show the ink, without the pictures).
    var images: [ImageFile]?         // every image object referenced by a page or its undo/redo history
    var nextImageId: Int?

    struct PageFile: Codable {
        var strokes: [Int]           // current contents, in drawing order (stroke ids)
        var undo: [[Int]]
        var redo: [[Int]]
        var zoom: Double
        var centerX: Double
        var centerY: Double
        var created: Double?         // seconds since 1970; absent in notebooks saved before 0.1.0
        var edited: Double?
        var kept: Bool?              // kept writing past a screen: no "filled a screen" note (absent = false)
        var images: [Int]?           // image object ids, bottom first (absent = none)
        var imageUndo: [[Int]]?      // the image objects of each undo / redo step, beside `undo` / `redo` (absent = none in any)
        var imageRedo: [[Int]]?
        var importId: String?        // the Inbox item the page was made from
    }
    /// An image object: a picture (a file in Images/, named by its hash) placed on a page.
    struct ImageFile: Codable {
        var id: Int
        var asset: String            // the picture's SHA-256 (32 hex characters): Images/<asset>.<type>
        var type: String             // file extension: png, jpeg, heic, tiff, pdf...
        var width: Int               // pixels as shown (orientation applied; a PDF's first page as drawn)
        var height: Int
        var frame: [Double]          // x, y, width, height in page units, y up (anywhere: may be outside the page's column)
        var sourceKind: String?      // file, paste, web
        var sourceName: String?
        var sourceURL: String?
        var sourceTitle: String?
        var added: Double?
    }
    struct StrokeFile: Codable {
        var id: Int
        var tool: String
        var color: [Float]           // straight RGBA
        var size: Double
        var points: Data             // Float32 x, y, pressure per point (little-endian)
    }

    static func pack(_ pts: [StrokePoint]) -> Data {
        var a: [Float32] = []; a.reserveCapacity(pts.count * 3)
        for p in pts { a.append(Float32(p.p.x)); a.append(Float32(p.p.y)); a.append(Float32(p.pressure)) }
        return a.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func unpack(_ d: Data) -> [StrokePoint] {
        let a: [Float32] = d.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        return stride(from: 0, to: a.count - 2, by: 3).map { StrokePoint(p: CGPoint(x: Double(a[$0]), y: Double(a[$0 + 1])), pressure: Double(a[$0 + 2])) }
    }

    func encoded() throws -> Data {
        let e = PropertyListEncoder(); e.outputFormat = .binary
        return try e.encode(self)
    }
    static func decode(_ d: Data) throws -> NotebookFile { try PropertyListDecoder().decode(NotebookFile.self, from: d) }
}

/// Page dates for display: the system's medium date style, local time zone ("Oct 25, 2026").
enum PageDate {
    static let formatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
    static func short(_ d: Date?) -> String { d.map { formatter.string(from: $0) } ?? "date unknown" }
    /// "Today at 14:02", "Yesterday at 09:10", else "Oct 25, 2026" (the overview's tiles).
    static let relative: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f }()
    static func recent(_ d: Date) -> String {
        let cal = Calendar.current
        return cal.isDateInToday(d) || cal.isDateInYesterday(d) ? relative.string(from: d) : formatter.string(from: d)
    }
}

extension Document {
    /// Undo history, for saving (oldest first).
    var history: (undo: [State], redo: [State]) { (undoStackForSave, redoStackForSave) }
}

// MARK: - Saving and loading pages

/// Everything a save needs, captured on the main thread in a few milliseconds: the page structure, views,
/// dates, and references to the strokes (immutable once committed). Building and encoding the file from it
/// can then happen on the save queue: doing that on the main thread blocked drawing for ~100 ms per save on
/// a 4.5 MB notebook (the ink froze, then jumped).
struct NotebookSnapshot {
    struct Page { var strokes: [Stroke]; var undo: [Document.State]; var redo: [Document.State]; var camera: Camera; var created: Date?; var edited: Date?; var kept = false
        var images: [ImageObject] = []; var importId: String? }
    var appVersion: String
    var pageIndex: Int
    var nextStrokeId: Int
    var pages: [Page]
    var nextImageId = 1
    /// Every picture the notebook refers to (pages and their undo history).
    var imageKeys: Set<String> { Set(pages.flatMap { p in (p.images + (p.undo + p.redo).flatMap(\.images)).map(\.asset.key) }) }
}

extension NotebookFile {
    init(_ snap: NotebookSnapshot) {
        self.init()
        appVersion = snap.appVersion; pageIndex = snap.pageIndex; nextStrokeId = snap.nextStrokeId
        var table: [Int: Stroke] = [:], imageTable: [Int: ImageObject] = [:]
        for p in snap.pages {
            for s in p.strokes { table[s.id] = s }
            for list in p.undo + p.redo { for s in list.strokes { table[s.id] = s } }
            for i in p.images + (p.undo + p.redo).flatMap(\.images) { imageTable[i.id] = i }
            let anyImages = !p.images.isEmpty || (p.undo + p.redo).contains { !$0.images.isEmpty }
            pages.append(.init(strokes: p.strokes.map(\.id), undo: p.undo.map { $0.strokes.map(\.id) }, redo: p.redo.map { $0.strokes.map(\.id) },
                               zoom: p.camera.zoom, centerX: p.camera.center.x, centerY: p.camera.center.y,
                               created: p.created?.timeIntervalSince1970, edited: p.edited?.timeIntervalSince1970, kept: p.kept ? true : nil,
                               images: p.images.isEmpty ? nil : p.images.map(\.id),
                               imageUndo: anyImages ? p.undo.map { $0.images.map(\.id) } : nil, imageRedo: anyImages ? p.redo.map { $0.images.map(\.id) } : nil,
                               importId: p.importId))
        }
        strokes = table.values.sorted { $0.id < $1.id }.map {
            .init(id: $0.id, tool: $0.tool.rawValue, color: [$0.color.x, $0.color.y, $0.color.z, $0.color.w], size: $0.size, points: NotebookFile.pack($0.points))
        }
        if !imageTable.isEmpty {
            images = imageTable.values.sorted { $0.id < $1.id }.map { i in
                .init(id: i.id, asset: i.asset.key, type: i.asset.ext, width: i.asset.pixelWidth, height: i.asset.pixelHeight,
                      frame: [i.frame.minX, i.frame.minY, i.frame.width, i.frame.height], sourceKind: i.source.kind.rawValue,
                      sourceName: i.source.fileName, sourceURL: i.source.url, sourceTitle: i.source.title, added: i.added?.timeIntervalSince1970)
            }
            nextImageId = max(snap.nextImageId, (imageTable.keys.max() ?? 0) + 1)
        }
    }
}

extension CanvasView {
    /// Cheap (main thread): arrays of references, copied on write.
    func notebookSnapshot() -> NotebookSnapshot {
        NotebookSnapshot(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                         pageIndex: pageIndex, nextStrokeId: nextStrokeIdForSave,
                         pages: pages.enumerated().map { i, doc in
                             let h = doc.history
                             return .init(strokes: doc.strokes, undo: h.undo, redo: h.redo,
                                          camera: i == pageIndex ? camera : (i < pageCamerasForSave.count ? pageCamerasForSave[i] : camera),
                                          created: doc.created, edited: doc.edited, kept: doc.keptWriting, images: doc.images, importId: doc.importId)
                         }, nextImageId: nextImageIdForSave)
    }
    func notebookFile() -> NotebookFile { NotebookFile(notebookSnapshot()) }

    /// Replace the notebook with a saved one.
    func load(_ f: NotebookFile) {
        var table: [Int: Stroke] = [:]
        for s in f.strokes {
            let c = s.color.count == 4 ? SIMD4<Float>(s.color[0], s.color[1], s.color[2], s.color[3]) : SIMD4<Float>(0, 0, 0, 1)
            let st = Stroke(tool: ToolKind(rawValue: s.tool) ?? .pen, color: c, size: s.size, points: NotebookFile.unpack(s.points), maxStep: 0)
            st.id = s.id
            table[s.id] = st
        }
        func list(_ ids: [Int]) -> [Stroke] { ids.compactMap { table[$0] } }
        var imageTable: [Int: ImageObject] = [:]
        for i in f.images ?? [] where i.frame.count == 4 && i.asset.count == 32 && i.frame.allSatisfy(\.isFinite) {
            let a = ImageStore.asset(key: i.asset, ext: i.type, width: i.width, height: i.height)
            let src = ImageSource(kind: ImageSource.Kind(rawValue: i.sourceKind ?? "") ?? .file, fileName: i.sourceName, url: i.sourceURL, title: i.sourceTitle)
            imageTable[i.id] = ImageObject(id: i.id, asset: a, frame: CGRect(x: i.frame[0], y: i.frame[1], width: i.frame[2], height: i.frame[3]),
                                           source: src, added: i.added.map(Date.init(timeIntervalSince1970:)))
        }
        func images(_ ids: [Int]?) -> [ImageObject] { (ids ?? []).compactMap { imageTable[$0] } }
        func states(_ s: [[Int]], _ im: [[Int]]?) -> [Document.State] {
            s.indices.map { k in Document.State(strokes: list(s[k]), images: images(im.flatMap { k < $0.count ? $0[k] : nil })) }
        }
        var docs: [Document] = [], cams: [Camera] = []
        for p in f.pages {
            let d = Document()
            d.restore(Document.State(strokes: list(p.strokes), images: images(p.images)), undo: states(p.undo, p.imageUndo), redo: states(p.redo, p.imageRedo))
            d.importId = p.importId
            d.created = p.created.map(Date.init(timeIntervalSince1970:))
            d.edited = p.edited.map(Date.init(timeIntervalSince1970:))
            d.keptWriting = p.kept ?? false
            docs.append(d)
            var c = camera; c.zoom = p.zoom; c.center = CGPoint(x: p.centerX, y: p.centerY); c.clamp()
            cams.append(c)
        }
        restorePages(docs.isEmpty ? [Document.new()] : docs, cameras: cams, index: min(max(f.pageIndex, 0), max(docs.count - 1, 0)),
                     nextStrokeId: max(f.nextStrokeId, (f.strokes.map(\.id).max() ?? 0) + 1),
                     nextImageId: max(f.nextImageId ?? 1, (f.images?.map(\.id).max() ?? 0) + 1))
    }

    /// Load the saved notebook at launch. A file that can't be read is kept aside, never overwritten.
    @discardableResult
    func loadNotebookFromDisk() -> String {
        let path = AppPaths.notebookPath
        guard AppPaths.persists else { return "not saved (test)" }
        guard let data = FileManager.default.contents(atPath: path) else { return "new" }
        do {
            let f = try NotebookFile.decode(data)
            load(f)
            let c = NotebookSafety.counts(f); NotebookSafety.onDisk = (path, c.pages, c.strokes)
            NotebookSafety.dailyBackup(notebook: path, backupsDir: AppPaths.dataDir + "/Backups", now: Date())
            return "loaded \(pages.count) page(s)"
        } catch {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let aside = AppPaths.dataDir + "/Notebook-unreadable-\(f.string(from: Date())).tdnb"
            try? FileManager.default.moveItem(atPath: path, toPath: aside)
            ImageStore.collects = false   // its pictures stay: the notebook kept aside still refers to them
            NSLog("Scrawl: notebook unreadable (\(error)); kept as \(aside)")
            return "unreadable, kept as \(aside)"
        }
    }
}

/// Autosave: 0.5 s after the last change, encode on the main thread (fast) and write atomically on a
/// background queue, so a crash or kill -9 can lose at most the last half second.
final class Autosaver {
    private weak var canvas: CanvasView?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "notebook.save")
    private(set) var saves = 0
    private(set) var changes = 0         // changes seen
    private(set) var savedThrough = 0    // changes covered by the last completed write
    var delay = 0.5
    /// Main-thread time of each save (test / diagnostics): what the app is blocked for while you write.
    private(set) var mainThreadMs: [Double] = []
    /// Pictures to keep besides those the saved notebook refers to (pages deleted, which ⌘Z can still bring back).
    var extraImageKeys: (() -> Set<String>)?
    /// After a write completes (main queue): the number of changes it covers.
    var onSaved: ((Int) -> Void)?
    private var collectedFor: (keep: Set<String>, known: Set<String>)?   // save queue only
    /// The save queue: an image file written here (before the page that shows it is saved) is on disk before any
    /// notebook that refers to it.
    var saveQueue: DispatchQueue { queue }

    init(canvas: CanvasView) { self.canvas = canvas }

    func changed() {
        changes += 1
        guard pending == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.pending = nil; self?.saveNow(sync: false) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func saveNow(sync: Bool) {
        pending?.cancel(); pending = nil
        let m0 = CACurrentMediaTime()
        defer { mainThreadMs.append((CACurrentMediaTime() - m0) * 1000) }
        guard AppPaths.persists, let c = canvas else { return }
        // Main thread: only the snapshot. Building, encoding and writing happen on the save queue (in order).
        let snap = c.notebookSnapshot()
        let keep = snap.imageKeys.union(extraImageKeys?() ?? [])
        let path = AppPaths.notebookPath, through = changes
        let write = { [weak self] in
            AppPaths.ensure()
            do {
                let file = NotebookFile(snap), backups = AppPaths.dataDir + "/Backups", c = NotebookSafety.counts(file)
                NotebookSafety.dailyBackup(notebook: path, backupsDir: backups, now: Date())
                NotebookSafety.backupIfShrinking(notebook: path, newPages: c.pages, newStrokes: c.strokes, backupsDir: backups, now: Date())
                let data = try file.encoded()
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                NotebookSafety.onDisk = (path, c.pages, c.strokes)
                // Pictures nothing refers to any more go, once this notebook (which doesn't need them) is on disk.
                // Backups keep theirs (they're made above, before this write, from the notebook that was on disk).
                // Also when a picture came and went between two saves (imported, then undone): the set in use is the same, but
                // the run knows a picture more.
                let known = ImageStore.knownKeys
                if let self, ImageStore.collects, self.collectedFor?.keep != keep || self.collectedFor?.known != known {
                    self.collectedFor = (keep, known); ImageStore.collectGarbage(keep: keep.union(ImageStore.keysInBackups(backups)))
                }
                DispatchQueue.main.async {
                    self?.saves += 1; self?.savedThrough = max(self?.savedThrough ?? 0, through); self?.onSaved?(through)
                }
            }
            catch { NSLog("Scrawl: autosave failed: \(error)") }
        }
        if sync { queue.sync(execute: write) } else { queue.async(execute: write) }
    }
}

/// The app was called Trackpad Draw. On the first launch as Scrawl: move the old pages and logs folders to
/// the new names (only if the new ones don't exist yet; never merged or overwritten) and copy the old
/// settings into this app's defaults. "welcomed" is not copied, so the welcome window introduces the new
/// name once. Real app only: tests never call it (they'd move Karthik's pages).
enum Migration {
    static let oldFolder = "Trackpad Draw"
    static let oldDomains = ["local.trackpad-draw", "io.github.karthikraju391.trackpad-draw"]
    static let doneKey = "migratedFromTrackpadDraw"

    @discardableResult
    static func run(supportBase: String = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path,
                    logsBase: String = NSHomeDirectory() + "/Library/Logs",
                    newFolder: String = AppPaths.folderName,
                    defaults: UserDefaults = .standard, ownDomain: String? = Bundle.main.bundleIdentifier,
                    readDomain: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) }) -> [String] {
        var notes: [String] = []
        let fm = FileManager.default
        for base in [supportBase, logsBase] {
            let old = base + "/" + oldFolder, new = base + "/" + newFolder
            guard fm.fileExists(atPath: old), !fm.fileExists(atPath: new) else { continue }
            do { try fm.moveItem(atPath: old, toPath: new); notes.append("moved \(old) -> \(new)") }
            catch { notes.append("could not move \(old): \(error.localizedDescription)") }
        }
        if !defaults.bool(forKey: doneKey) {
            for d in oldDomains where d != ownDomain {
                guard let old = readDomain(d), !old.isEmpty else { continue }
                var n = 0
                for (k, v) in old where k != "welcomed" && !k.hasPrefix("NS") && !k.hasPrefix("Apple") && defaults.object(forKey: k) == nil {
                    defaults.set(v, forKey: k); n += 1
                }
                notes.append("copied \(n) settings from \(d)")
                break   // the first old domain found wins
            }
            defaults.set(true, forKey: doneKey)
        }
        return notes
    }
}
