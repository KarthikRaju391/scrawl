// Karthik's notebook is never written by anything but the app he runs (3 Nov: a bench run wrote a test canvas over
// it). Saving: only a release app, or a process given its own folder (TRACKPAD_DRAW_DATA). A save that would shrink
// the notebook to under half keeps a timestamped backup first, and the app keeps a daily backup (newest 7).
import AppKit

func dataSafetyChecks(_ check: (Bool, String) -> Void) {
    let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path + "/Scrawl"
    check(!AppPaths.persists, "the bench can't save (persists \(AppPaths.persists))")
    check(AppPaths.override != nil || AppPaths.dataDir != real, "a development build's notebook isn't the real one (\(AppPaths.dataDir))")
    // A dirty canvas with the run loop running (what the image checks did) saves nothing. Only tried once saving is
    // provably off: before that, this would be the very write we guard against.
    if !AppPaths.persists && AppPaths.dataDir != real {
        let attrs = { (try? FileManager.default.attributesOfItem(atPath: real + "/Notebook.tdnb")) as NSDictionary? }
        let before = attrs()?.fileModificationDate()
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), device: nil)
        c.restorePages([Document.new()], cameras: [c.camera], index: 0, nextStrokeId: 1)
        c.doc.add(Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 2, points: (0..<20).map { StrokePoint(p: CGPoint(x: 100 + Double($0), y: 100), pressure: 0.5) }, maxStep: 1))
        c.markDirty()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        check(attrs()?.fileModificationDate() == before, "a dirty bench canvas with the run loop running for 1.5 s leaves the real notebook alone")
    } else {
        check(false, "a dirty bench canvas with the run loop running: not tried, saving isn't off")
    }

    // Shrink guard and daily backups, on temp folders.
    let tmp = NSTemporaryDirectory() + "scrawl-safety-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: tmp + "/Backups", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), device: nil)
    var docs: [Document] = []
    for p in 0..<10 {
        let d = Document.new()
        for k in 0..<20 { d.add(Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 2, points: (0..<5).map { StrokePoint(p: CGPoint(x: Double(k * 10 + $0), y: Double(p * 10)), pressure: 0.5) }, maxStep: 1)) }
        docs.append(d)
    }
    c.restorePages(docs, cameras: Array(repeating: c.camera, count: 10), index: 0, nextStrokeId: 1000)
    let nb = tmp + "/Notebook.tdnb"
    try? (try? c.notebookFile().encoded())?.write(to: URL(fileURLWithPath: nb))
    let backups = { (try? FileManager.default.contentsOfDirectory(atPath: tmp + "/Backups")) ?? [] }
    let now = Date(timeIntervalSince1970: 1_793_700_000)
    let stamp = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: now) }()
    var made = NotebookSafety.backupIfShrinking(notebook: nb, newPages: 9, newStrokes: 190, backupsDir: tmp + "/Backups", now: now)
    check(made == nil && backups().isEmpty, "a save that keeps 9 of 10 pages and 190 of 200 strokes keeps no backup (\(backups()))")
    made = NotebookSafety.backupIfShrinking(notebook: nb, newPages: 2, newStrokes: 0, backupsDir: tmp + "/Backups", now: now)
    let kept = made.flatMap { FileManager.default.contents(atPath: $0) }
    check(kept != nil && kept == FileManager.default.contents(atPath: nb) && (made ?? "").hasSuffix("Notebook-\(stamp).tdnb"),
          "a save that would leave 2 pages and 0 strokes of 10 / 200 first copies the notebook to Backups/Notebook-YYYYMMDD-HHMM.tdnb (\(made ?? "none"))")
    for i in 0..<12 { _ = NotebookSafety.backupIfShrinking(notebook: nb, newPages: 0, newStrokes: 0, backupsDir: tmp + "/Backups", now: now.addingTimeInterval(Double(i + 1) * 60)) }
    check(backups().filter { $0.hasPrefix("Notebook-2") }.count == 10, "shrink backups keep the newest 10 (\(backups().filter { $0.hasPrefix("Notebook-2") }.count))")
    // Daily: one per day, newest 7.
    for day in 0..<9 { NotebookSafety.dailyBackup(notebook: nb, backupsDir: tmp + "/Backups", now: now.addingTimeInterval(Double(day) * 86400), keep: 7) }
    NotebookSafety.dailyBackup(notebook: nb, backupsDir: tmp + "/Backups", now: now.addingTimeInterval(8 * 86400 + 3600), keep: 7)
    let daily = backups().filter { $0.hasPrefix("Notebook-daily-") }.sorted()
    check(daily.count == 7 && daily.last == "Notebook-daily-20261111.tdnb" && daily.first == "Notebook-daily-20261105.tdnb",
          "daily backups: one per day, the newest 7 kept (\(daily.first ?? "-") ... \(daily.last ?? "-"), \(daily.count))")
}
