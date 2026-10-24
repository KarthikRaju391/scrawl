// Notebook file: everything survives save + load (pages, strokes, views, undo/redo history).
import AppKit
import Foundation

func notebookChecks(_ check: (Bool, String) -> Void) {
    let a = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    func stroke(_ x: Double, _ y: Double, _ n: Int = 40) -> [StrokePoint] {
        (0..<n).map { StrokePoint(p: CGPoint(x: x + Double($0) * 3, y: y + sin(Double($0) / 4) * 20), pressure: 0.3 + 0.4 * Double($0) / Double(n)) }
    }
    for k in 0..<5 { a.testAddStroke(stroke(100, 800 - Double(k) * 60)) }
    a.undo()                                   // page 1: 4 strokes, 1 redo step
    a.newPage()
    for k in 0..<3 { a.testAddStroke(stroke(300, 700 - Double(k) * 50), tool: k == 1 ? .highlighter : .pen) }
    a.setVisibleForReplay(x: 200, y: 300, w: 400, z: 4)
    a.goToPage(0)
    let f = a.notebookFile()
    guard let data = try? f.encoded(), let g = try? NotebookFile.decode(data) else { check(false, "notebook encodes and decodes"); return }
    let b = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    b.load(g)
    let pagesOK = b.pages.count == 2 && b.pageIndex == 0 && b.pages[0].strokes.count == 4 && b.pages[1].strokes.count == 3
    func same(_ x: Document, _ y: Document) -> Bool {
        x.strokes.count == y.strokes.count && zip(x.strokes, y.strokes).allSatisfy { s, t in
            s.id == t.id && s.tool == t.tool && s.points.count == t.points.count &&
            zip(s.points, t.points).allSatisfy { abs($0.p.x - $1.p.x) < 1e-3 && abs($0.p.y - $1.p.y) < 1e-3 && abs($0.pressure - $1.pressure) < 1e-4 }
        }
    }
    check(pagesOK && same(a.pages[0], b.pages[0]) && same(a.pages[1], b.pages[1]),
          "notebook round trip: 2 pages, every stroke's points, pressure, tool and id identical (\(data.count) bytes)")
    b.redo()
    check(b.pages[0].strokes.count == 5, "undo history survives reopening: redo brings back the undone stroke (\(b.pages[0].strokes.count) strokes)")
    b.goToPage(1)
    check(abs(b.camera.zoom - 4) < 1e-9, "each page reopens with its own view (page 2 zoom \(b.camera.zoom))")
    // A big notebook: 2,500 strokes x 150 points encode + decode time and size.
    let big = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740), device: nil)
    for k in 0..<2500 { big.testAddStroke(stroke(Double(k % 50) * 30, 900 - Double(k / 50) * 15, 150)) }
    let t0 = CFAbsoluteTimeGetCurrent()
    let bd = try! big.notebookFile().encoded()
    let t1 = CFAbsoluteTimeGetCurrent()
    _ = try! NotebookFile.decode(bd)
    let t2 = CFAbsoluteTimeGetCurrent()
    check((t1 - t0) < 0.25, String(format: "2,500-stroke notebook: encode %.0f ms (main thread, every autosave), decode %.0f ms, %.1f MB", (t1 - t0) * 1000, (t2 - t1) * 1000, Double(bd.count) / 1e6))
}
