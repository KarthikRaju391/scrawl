// Where things live, and the notebook file: every page, its strokes, its view and its undo/redo
// history, saved automatically (0.5 s after a change, atomically, and on quit).
import AppKit

/// How this process was launched. Test modes run in the background (never take focus) unless a test
/// explicitly asks for the foreground with --test-front.
enum Launch {
    static let args = CommandLine.arguments
    static let testing = args.contains { $0.hasPrefix("--test-") && $0 != "--test-front" && $0 != "--test-lock" }
    static let background = args.contains("--no-activate") || (testing && !args.contains("--test-front"))
}

enum AppPaths {
    /// The notebook is only read and written by the real app, or by tests given their own folder:
    /// a test must never load or overwrite Karthik's pages.
    static var persists: Bool { !Launch.testing || override != nil }

    /// Tests and development point everything at one folder with TRACKPAD_DRAW_DATA.
    static let override = ProcessInfo.processInfo.environment["TRACKPAD_DRAW_DATA"]

    /// The folder name under Application Support and Logs. Fixed here, not taken from the bundle, so a
    /// rename never strands anyone's pages (Migration moves the old "Trackpad Draw" folders).
    static let folderName = "Scrawl"

    /// ~/Library/Application Support/Scrawl: the notebook.
    static var dataDir: String {
        if let o = override { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        return base + "/" + folderName
    }
    /// ~/Library/Logs/Scrawl: watchdog log, crash notes, optional touch diagnostics. Local only.
    static var logsDir: String {
        if let o = override { return o }
        return NSHomeDirectory() + "/Library/Logs/" + folderName
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

// MARK: - File format (binary property list)

struct NotebookFile: Codable {
    var formatVersion = 1
    var appVersion = ""
    var pageIndex = 0
    var nextStrokeId = 1
    var pages: [PageFile] = []
    var strokes: [StrokeFile] = []   // every stroke referenced by a page or its undo/redo history

    struct PageFile: Codable {
        var strokes: [Int]           // current contents, in drawing order (stroke ids)
        var undo: [[Int]]
        var redo: [[Int]]
        var zoom: Double
        var centerX: Double
        var centerY: Double
        var created: Double?         // seconds since 1970; absent in notebooks saved before 0.1.0
        var edited: Double?
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
}

extension Document {
    /// Undo history, for saving (oldest first).
    var history: (undo: [[Stroke]], redo: [[Stroke]]) { (undoStackForSave, redoStackForSave) }
}

// MARK: - Saving and loading pages

extension CanvasView {
    func notebookFile() -> NotebookFile {
        var f = NotebookFile()
        f.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        f.pageIndex = pageIndex
        f.nextStrokeId = nextStrokeIdForSave
        var table: [Int: Stroke] = [:]
        for (i, doc) in pages.enumerated() {
            let cam = i == pageIndex ? camera : (i < pageCamerasForSave.count ? pageCamerasForSave[i] : camera)
            let h = doc.history
            for s in doc.strokes { table[s.id] = s }
            for list in h.undo + h.redo { for s in list { table[s.id] = s } }
            f.pages.append(.init(strokes: doc.strokes.map(\.id), undo: h.undo.map { $0.map(\.id) }, redo: h.redo.map { $0.map(\.id) },
                                 zoom: cam.zoom, centerX: cam.center.x, centerY: cam.center.y,
                                 created: doc.created?.timeIntervalSince1970, edited: doc.edited?.timeIntervalSince1970))
        }
        f.strokes = table.values.sorted { $0.id < $1.id }.map {
            .init(id: $0.id, tool: $0.tool.rawValue, color: [$0.color.x, $0.color.y, $0.color.z, $0.color.w], size: $0.size, points: NotebookFile.pack($0.points))
        }
        return f
    }

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
        var docs: [Document] = [], cams: [Camera] = []
        for p in f.pages {
            let d = Document()
            d.restore(strokes: list(p.strokes), undo: p.undo.map(list), redo: p.redo.map(list))
            d.created = p.created.map(Date.init(timeIntervalSince1970:))
            d.edited = p.edited.map(Date.init(timeIntervalSince1970:))
            docs.append(d)
            var c = camera; c.zoom = p.zoom; c.center = CGPoint(x: p.centerX, y: p.centerY); c.clamp()
            cams.append(c)
        }
        restorePages(docs.isEmpty ? [Document.new()] : docs, cameras: cams, index: min(max(f.pageIndex, 0), max(docs.count - 1, 0)),
                     nextStrokeId: max(f.nextStrokeId, (f.strokes.map(\.id).max() ?? 0) + 1))
    }

    /// Load the saved notebook at launch. A file that can't be read is kept aside, never overwritten.
    @discardableResult
    func loadNotebookFromDisk() -> String {
        let path = AppPaths.notebookPath
        guard AppPaths.persists else { return "not saved (test)" }
        guard let data = FileManager.default.contents(atPath: path) else { return "new" }
        do {
            load(try NotebookFile.decode(data))
            return "loaded \(pages.count) page(s)"
        } catch {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let aside = AppPaths.dataDir + "/Notebook-unreadable-\(f.string(from: Date())).tdnb"
            try? FileManager.default.moveItem(atPath: path, toPath: aside)
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
        guard AppPaths.persists, let c = canvas, let data = try? c.notebookFile().encoded() else { return }
        let path = AppPaths.notebookPath, through = changes
        let write = { [weak self] in
            AppPaths.ensure()
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                DispatchQueue.main.async { self?.saves += 1; self?.savedThrough = max(self?.savedThrough ?? 0, through) }
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
