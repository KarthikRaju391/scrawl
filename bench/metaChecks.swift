// Page dates: created when a page is made, edited on every change, both saved; old notebooks load
// without them ("date unknown").
import AppKit

/// A notebook as saved before 0.1.0's page dates (PageFile without created/edited).
private struct OldNotebookFile: Codable {
    var formatVersion = 1, appVersion = "0.1.0-pre", pageIndex = 0, nextStrokeId = 1
    var pages: [Page] = []
    var strokes: [NotebookFile.StrokeFile] = []
    struct Page: Codable { var strokes: [Int]; var undo: [[Int]]; var redo: [[Int]]; var zoom: Double; var centerX: Double; var centerY: Double }
}

func metaChecks(_ check: (Bool, String) -> Void) {
    let saved = Document.clock
    var now = Date(timeIntervalSince1970: 1_792_900_000)   // Oct 2026
    Document.clock = { now }
    defer { Document.clock = saved }
    let d = Document.new()
    let c0 = d.created
    now += 3600
    d.add(Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 2, points: [StrokePoint(p: .zero, pressure: 0.5), StrokePoint(p: CGPoint(x: 10, y: 0), pressure: 0.5)], maxStep: 1))
    let e1 = d.edited
    now += 60; d.undo(); let e2 = d.edited
    now += 60; d.redo(); _ = d.remove { _ in true }; let e3 = d.edited
    check(c0 == Date(timeIntervalSince1970: 1_792_900_000) && d.created == c0 && e1 == c0! + 3600 && e2 == c0! + 3660 && e3 == c0! + 3720,
          "a new page gets created = edited = now; a stroke, undo and erase move edited, never created")
    // Save and load: dates survive.
    let a = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    a.testAddStroke([StrokePoint(p: CGPoint(x: 100, y: 800), pressure: 0.5), StrokePoint(p: CGPoint(x: 300, y: 800), pressure: 0.5)])
    now += 86400; a.newPage()
    let f = try! NotebookFile.decode(a.notebookFile().encoded())
    let b = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    b.load(f)
    let same = zip(a.pages, b.pages).allSatisfy { abs(($0.created?.timeIntervalSince1970 ?? -1) - ($1.created?.timeIntervalSince1970 ?? -2)) < 1e-6
        && abs(($0.edited?.timeIntervalSince1970 ?? -1) - ($1.edited?.timeIntervalSince1970 ?? -2)) < 1e-6 }
    check(b.pages.count == 2 && same && b.pages[1].created == now, "created and edited dates survive save + load (and loading doesn't change edited)")
    // A notebook saved before page dates: every page and stroke loads, dates unknown.
    var old = OldNotebookFile()
    old.strokes = (1...3).map { NotebookFile.StrokeFile(id: $0, tool: "pen", color: [0, 0, 0, 1], size: 2,
                                                        points: NotebookFile.pack([StrokePoint(p: CGPoint(x: 10, y: Double($0) * 10), pressure: 0.5), StrokePoint(p: CGPoint(x: 90, y: Double($0) * 10), pressure: 0.5)])) }
    old.pages = [.init(strokes: [1, 2], undo: [[1]], redo: [], zoom: 1, centerX: 800, centerY: 492), .init(strokes: [3], undo: [], redo: [], zoom: 2, centerX: 400, centerY: 700)]
    old.nextStrokeId = 4
    let e = PropertyListEncoder(); e.outputFormat = .binary
    let oldData = try! e.encode(old)
    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    if let nf = try? NotebookFile.decode(oldData) { c.load(nf) }
    check(c.pages.count == 2 && c.pages[0].strokes.count == 2 && c.pages[1].strokes.count == 1 && c.pages.allSatisfy { $0.created == nil && $0.edited == nil }
          && PageDate.short(c.pages[0].created) == "date unknown",
          "a notebook saved before page dates loads every page and stroke; the dates show as \"date unknown\" (none invented)")
    // Display: the system's medium date style in the local time zone.
    let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .none; fmt.timeZone = .current; fmt.locale = .current
    let day = Date(timeIntervalSince1970: 1_792_900_000)
    check(PageDate.short(day) == fmt.string(from: day), "dates use the system's medium date style, local time zone (\(PageDate.short(day)))")
}
