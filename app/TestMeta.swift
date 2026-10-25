// --test-meta write|read|makeold|readold: page dates through the real app. write: dates set on a
// controlled clock, a stroke on page 1, labels recorded (overview tiles, the open page's label),
// screenshots, save. read (a restart): the same dates and labels. makeold: writes old.tdnb in the
// format saved before page dates; readold: the app opens that notebook (copied in as Notebook.tdnb).
import AppKit

private struct OldNotebookFile: Codable {   // PageFile before created/edited existed
    var formatVersion = 1, appVersion = "0.1.0-pre", pageIndex = 1, nextStrokeId = 4
    var pages: [Page] = []
    var strokes: [NotebookFile.StrokeFile] = []
    struct Page: Codable { var strokes: [Int]; var undo: [[Int]]; var redo: [[Int]]; var zoom: Double; var centerX: Double; var centerY: Double }
}

enum TestMeta {
    static func run(_ phase: String, app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        func shot(_ n: Int) {
            try? "\(n)".write(toFile: dir + "/shot-\(n).req", atomically: true, encoding: .utf8)
            let d = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(n).done") && Date() < d { spin(0.03) }
        }
        func labels() -> [String: Any] {
            var hints: [String] = []
            for i in canvas.pages.indices { canvas.goToPage(i); app.updateBanner(); hints.append(app.container.hint.stringValue) }
            app.showGallery(); waitTransition()
            let tiles = canvas.pages.indices.map { app.gallery!.tileLabel($0) }
            app.openPage(0); waitTransition()
            return ["hints": hints, "tiles": tiles]
        }
        func dates() -> [[String: Any]] {
            canvas.pages.map { ["created": $0.created?.timeIntervalSince1970 ?? -1, "edited": $0.edited?.timeIntervalSince1970 ?? -1, "strokes": $0.strokes.count] }
        }
        var r: [String: Any] = ["phase": phase]
        switch phase {
        case "write":
            if canvas.drawMode { app.exitDrawMode("test") }
            var t = canvas.tools; t.background = 3; canvas.tools = t
            let launchCreated = canvas.pages[0].created?.timeIntervalSince1970 ?? -1
            r["page1AtLaunch"] = ["created": launchCreated, "wallClock": Date().timeIntervalSince1970]
            var clock = Date(timeIntervalSince1970: 1_792_400_000)   // Oct 19, 2026
            Document.clock = { clock }
            canvas.testAddStroke((0..<60).map { StrokePoint(p: CGPoint(x: 100 + Double($0) * 10, y: 880), pressure: 0.6) })
            app.page(0)                                                       // page 2, created Oct 19
            canvas.testAddStroke((0..<60).map { StrokePoint(p: CGPoint(x: 100 + Double($0) * 10, y: 760), pressure: 0.6) })
            clock = Date(timeIntervalSince1970: 1_792_600_000); app.page(0)   // page 3, created Oct 21
            let before = dates()
            clock = Date(timeIntervalSince1970: 1_792_800_000)                 // Oct 24: a stroke on page 1
            canvas.goToPage(0)
            canvas.testAddStroke((0..<60).map { StrokePoint(p: CGPoint(x: 100 + Double($0) * 10, y: 700), pressure: 0.6) })
            r["beforeStroke"] = before
            r["dates"] = dates()
            r["labels"] = labels()
            // Screenshots: the open page with its label, then the overview.
            canvas.goToPage(1); app.updateBanner(); canvas.draw(); shot(0)
            app.showGallery(); waitTransition(); shot(1)
            app.openPage(1); waitTransition()
            canvas.autosaver.saveNow(sync: true)
        case "read":
            r["dates"] = dates(); r["labels"] = labels(); r["load"] = app.notebookStatus
        case "makeold":
            var old = OldNotebookFile()
            old.strokes = (1...3).map { id in NotebookFile.StrokeFile(id: id, tool: "pen", color: [0, 0, 0, 1], size: 3,
                                                                points: NotebookFile.pack((0..<40).map { k in StrokePoint(p: CGPoint(x: 100 + Double(k) * 15, y: 900 - Double(id) * 80), pressure: 0.6) })) }
            old.pages = [.init(strokes: [1, 2], undo: [[1]], redo: [], zoom: 1, centerX: 800, centerY: 492), .init(strokes: [3], undo: [], redo: [], zoom: 2, centerX: 400, centerY: 700)]
            let e = PropertyListEncoder(); e.outputFormat = .binary
            try? e.encode(old).write(to: URL(fileURLWithPath: dir + "/old.tdnb"))
        default:   // readold
            r["load"] = app.notebookStatus; r["dates"] = dates(); r["labels"] = labels()
        }
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-meta-\(phase).json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
