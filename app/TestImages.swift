// --test-images write|read|big: image pages in the real app (background window, a scratch data folder; checks/images.sh).
//   write : pictures come in by every way there is: ⌘V (the app's Paste action, test pasteboard), a drop on the window
//           (the window's own drag handlers, with a pasteboard holding a file), New Page from Image's import (HEIC,
//           TIFF, PDF), the Inbox (an item put there before launch, and one while running). Then ink on a picture
//           through the real input path, ⌘Z after a new picture page (the page goes, then its file), the page header,
//           Copy as Image, Export Page (PNG, SVG) and Export All as PDF. Waits for the autosave, records what's expected,
//           and stays mid-stroke for the script's kill -9.
//   read  : what the reopened notebook holds (and the picture files' hashes).
//   big   : a 4000 x 12000 screenshot: frame times scrolling it, ink latency on it vs a plain page, memory.
import AppKit
import CryptoKit
import UniformTypeIdentifiers

enum TestImages {
    static var dir: String { AppPaths.dataDir }
    static func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func write(_ obj: Any, _ name: String) {
        try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/" + name))
    }
    /// The picture files in Images/ and their hashes.
    static func files() -> [String: String] {
        var out: [String: String] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: ImageStore.root)) ?? [] where !n.hasPrefix(".") {
            out[n] = FileManager.default.contents(atPath: ImageStore.root + "/" + n).map(sha) ?? "?"
        }
        return out
    }
    static func summary(_ app: AppDelegate) -> [String: Any] {
        var s = TestPersist.summary(app.canvas)
        s["files"] = files()
        s["imagePages"] = app.canvas.pages.enumerated().filter { !$0.element.images.isEmpty }.map { i, d in
            ["page": i, "images": d.images.map { ["id": $0.id, "asset": $0.asset.key, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height], "source": $0.source.label] },
             "strokes": d.strokes.count, "importId": d.importId ?? ""] as [String: Any]
        }
        return s
    }
    /// Wait (spinning the run loop) until `cond` or `timeout`.
    @discardableResult static func wait(_ timeout: Double = 10, _ cond: () -> Bool) -> Bool {
        let d = Date().addingTimeInterval(timeout)
        while !cond() && Date() < d { spin(0.01) }
        return cond()
    }

    /// A test card (gradient, blocks, lines): `w` x `h`.
    static func card(_ w: Int, _ h: Int, hue: Double = 0.6) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let c1 = NSColor(hue: hue, saturation: 0.25, brightness: 0.98, alpha: 1).cgColor, c2 = NSColor(hue: hue, saturation: 0.6, brightness: 0.75, alpha: 1).cgColor
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [c1, c2] as CFArray, locations: [0, 1])!, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        for k in 0..<max(h / 160, 1) { ctx.fill(CGRect(x: w / 12, y: h - 100 - k * 160, width: w * (5 + k % 4) / 12, height: 46)) }   // "text lines"
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        for x in stride(from: 0, to: w, by: 200) { ctx.fill(CGRect(x: x, y: 0, width: 2, height: h)) }
        return ctx.makeImage()!
    }
    static func encode(_ img: CGImage, _ t: UTType) -> Data {
        let d = NSMutableData(); let dest = CGImageDestinationCreateWithData(d, t.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest); return d as Data
    }
    static func pdf() -> Data {
        let d = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: d as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPage(mediaBox: &box)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 72, y: 560, width: 300, height: 160))
        let s = NSAttributedString(string: "A PDF page", attributes: [.font: NSFont.systemFont(ofSize: 36)])
        let line = CTLineCreateWithAttributedString(s); ctx.textPosition = CGPoint(x: 72, y: 480); CTLineDraw(line, ctx)
        ctx.endPage(); ctx.closePDF(); return d as Data
    }

    /// A stand-in for AppKit's dragging session (the window's handlers only read the pasteboard).
    final class Drag: NSObject, NSDraggingInfo {
        let pb: NSPasteboard
        init(_ pb: NSPasteboard) { self.pb = pb }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { NSPoint(x: 300, y: 300) }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pb }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation { get { .default } set {} }
        var animatesToDestination: Bool { get { false } set {} }
        var numberOfValidItemsForDrop: Int { get { 1 } set {} }
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// A screenshot of this window, taken by the script (it watches for shot-<name>.req).
    static func shot(_ name: String, app: AppDelegate? = nil) {
        // A background window presents nothing by itself: draw the canvas now, in this transaction, so the screenshot shows it.
        if let app, !app.galleryShown { app.canvas.drawNowWithTransaction(); CATransaction.flush(); spin(0.15) }
        try? name.write(toFile: dir + "/shot-\(name).req", atomically: true, encoding: .utf8)
        wait(5) { FileManager.default.fileExists(atPath: dir + "/shot-\(name).done") }
    }

    static func run(_ mode: String, app: AppDelegate) {
        let canvas = app.canvas
        var r: [String: Any] = [:]
        switch mode {
        case "write":
            let fx = dir + "/fixtures"; try? FileManager.default.createDirectory(atPath: fx, withIntermediateDirectories: true)
            // 0. The Inbox item put there before launch is a page already (or becomes one now).
            wait(10) { canvas.pages.contains { $0.importId == "before-launch" } }
            r["inboxBeforeLaunch"] = canvas.pages.firstIndex { $0.importId == "before-launch" } ?? -1
            // 1. ⌘V on the first page: the picture goes on that page (not a new one), selected, with the Select tool.
            canvas.goToPage(0)
            let pngData = encode(card(1600, 2400, hue: 0.58), .png)
            let pb = AppDelegate.pasteboard
            pb.clearContents(); pb.setData(pngData, forType: .png)
            let paste = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu?.items.first { $0.title == "Paste" }
            r["pasteEnabled"] = paste.map { app.validateMenuItem($0) } ?? false
            let n0 = canvas.pages.count
            app.paste(nil)
            r["paste"] = wait { canvas.doc.images.count == 1 }
            r["pasteOnPage"] = canvas.pages.count == n0 && canvas.pageIndex == 0
            r["pasteSelected"] = canvas.tools.tool == .select && canvas.selectedImageId == canvas.doc.images.first?.id
            r["pasteHeader"] = app.container.hint.stringValue
            // What the canvas draws right after the paste (its own offscreen render, reduced to 160 x 100): the share of it that is
            // the card's blue (paper and desk are grey or white).
            if let snap = canvas.snapshot(scale: 1) {
                let w = 160, h = 100
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(snap, in: CGRect(x: 0, y: 0, width: w, height: h))
                let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
                var blue = 0
                for k in 0..<(w * h) where Int(p[k * 4 + 2]) > Int(p[k * 4]) + 30 { blue += 1 }
                let f = canvas.doc.images.first.map { $0.frame.width * $0.frame.height / (canvas.renderRect.width * canvas.renderRect.height) } ?? 0
                r["pasteRendered"] = [Double(blue) / Double(w * h), f]   // blue share, the picture's share of the view
            }
            spin(0.3); shot("import", app: app)
            // 2. A JPEG file dropped on the window at a point: on the page, centred there.
            let jpgURL = URL(fileURLWithPath: fx + "/Holiday photo.jpg")
            try? encode(card(1200, 900, hue: 0.08), .jpeg).write(to: jpgURL)
            let dpb = NSPasteboard(name: NSPasteboard.Name("scrawl.test.drag")); dpb.clearContents(); dpb.writeObjects([jpgURL as NSURL])
            let drag = Drag(dpb)
            r["dragEntered"] = app.container.draggingEntered(drag) == .copy
            r["dropTaken"] = app.container.performDragOperation(drag)
            r["drop"] = wait { canvas.doc.images.count == 2 }
            let dropAt = canvas.canvasPoint(fromView: canvas.convert(app.container.convert(drag.draggingLocation, from: nil), from: app.container))
            r["dropAtPointer"] = canvas.doc.images.last.map { abs($0.frame.midX - dropAt.x) < 0.5 && abs($0.frame.midY - dropAt.y) < 0.5 && $0.source.fileName == "Holiday photo.jpg" } ?? false
            r["dropOnPage"] = canvas.pages.count == n0
            // A dropped text file is not taken.
            let txt = URL(fileURLWithPath: fx + "/notes.txt"); try? "hi".write(to: txt, atomically: true, encoding: .utf8)
            dpb.clearContents(); dpb.writeObjects([txt as NSURL])
            r["dropTextRefused"] = app.container.draggingEntered(drag) == [] && !app.container.performDragOperation(drag)
            // 2b. The Select tool through the window's own events: click the photo, drag it, drag its corner, ⌫, ⌘Z, ⌘C.
            // Real NSEvents (window coordinates) to the canvas's own handlers. Not window.sendEvent: a press on a background
            // window that isn't key is the window's (it would come forward), not the canvas's.
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
                let w = canvas.convert(canvas.viewPoint(fromCanvas: p), to: nil)
                guard let e = NSEvent.mouseEvent(with: type, location: w, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
                switch type { case .leftMouseDown: canvas.mouseDown(with: e); case .leftMouseDragged: canvas.mouseDragged(with: e); default: canvas.mouseUp(with: e) }
            }
            func pointerDrag(_ a: CGPoint, _ b: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
                mouse(.leftMouseDown, a, mods)
                for k in 1...10 { let f = Double(k) / 10; mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), mods); spin(0.008) }
                mouse(.leftMouseUp, b, mods); spin(0.05)
            }
            canvas.selectedImageId = nil   // inserting selected it: the click must do it
            guard let photo = canvas.doc.images.last else { r["error"] = "no picture on the page after paste and drop"; write(r, "images-write.json"); try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8); return }
            mouse(.leftMouseDown, CGPoint(x: photo.frame.midX, y: photo.frame.midY)); mouse(.leftMouseUp, CGPoint(x: photo.frame.midX, y: photo.frame.midY))
            r["clickSelects"] = canvas.selectedImageId == photo.id
            pointerDrag(CGPoint(x: photo.frame.midX, y: photo.frame.midY), CGPoint(x: photo.frame.midX - 300, y: photo.frame.midY + 150))
            let moved = canvas.selectedImage
            r["moved"] = moved.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? []; r["photo"] = [photo.frame.minX, photo.frame.minY, photo.frame.width, photo.frame.height]
            r["moveByPointer"] = moved.map { abs($0.frame.minX - (photo.frame.minX - 300)) < 0.5 && abs($0.frame.minY - (photo.frame.minY + 150)) < 0.5 } ?? false
            if let m = moved { pointerDrag(CGPoint(x: m.frame.maxX, y: m.frame.minY), CGPoint(x: m.frame.maxX + 120, y: m.frame.minY - 40)) }
            let resized = canvas.selectedImage
            if let a = moved, let b = resized {   // the bottom-right corner dragged: the top-left corner stays, proportions kept
                r["resizeByPointer"] = b !== a && abs(b.frame.width / b.frame.height - a.frame.width / a.frame.height) < 1e-6 && b.frame.width > a.frame.width
                    && abs(b.frame.minX - a.frame.minX) < 1e-6 && abs(b.frame.maxY - a.frame.maxY) < 1e-6
            } else { r["resizeByPointer"] = false }
            spin(0.2); shot("attach", app: app)
            _ = app.copySelectedPicture()
            r["copyPicture"] = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")).map { sha($0) == sha(photo.asset.data() ?? Data()) } ?? false
            let del = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                       characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)
            r["deleteKey"] = del.map { app.key($0) } == true && canvas.doc.images.count == 1
            app.undo()
            r["undoDelete"] = canvas.doc.images.count == 2 && canvas.doc.images.last === resized
            app.undo(); app.undo()
            r["undoMoves"] = canvas.doc.images.last === photo
            app.redoAction(); app.redoAction()
            r["redoMoves"] = canvas.doc.images.last === resized
            // 3. New Page from Image… (what the panel imports): HEIC, TIFF, PDF, three pages at once, the last opened.
            let n2 = canvas.pages.count
            app.importImages([ImagePageRequest(data: encode(card(1000, 1400, hue: 0.33), .heic), source: ImageSource(kind: .file, fileName: "plant.heic")),
                              ImagePageRequest(data: encode(card(800, 600, hue: 0.9), .tiff), source: ImageSource(kind: .file, fileName: "scan.tiff")),
                              ImagePageRequest(data: pdf(), source: ImageSource(kind: .file, fileName: "Handout.pdf"))], via: "open")
            r["open3"] = wait { canvas.pages.count == n2 + 3 }
            r["openHeader"] = app.container.hint.stringValue
            r["menuItem"] = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu?.items.first { $0.title == "New Page from Image…" }.map { "\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)" } ?? ""
            // 4. An Inbox item while the app runs (the script writes it when asked).
            try? "go".write(toFile: dir + "/inbox-now.req", atomically: true, encoding: .utf8)
            r["inboxWhileRunning"] = wait(10) { canvas.pages.contains { $0.importId == "while-running" } }
            r["inboxDone"] = wait(10) { FileManager.default.fileExists(atPath: AppPaths.dataDir + "/Inbox/while-running.done.json") }
            r["inboxHeader"] = app.container.hint.stringValue
            shot("inbox", app: app)
            // The overview: picture pages' tiles (from their tops), then back to the page.
            app.showGallery(); spin(0.8); shot("gallery")
            app.openPage(canvas.pageIndex); spin(0.6)
            // 5. ⌘Z right after a new picture page: the page goes; after the save, its file too (no other page uses it).
            let uniq = encode(card(640, 480, hue: 0.75), .png)
            pb.clearContents(); pb.setData(uniq, forType: .png)
            let n3 = canvas.pages.count
            app.importImages([ImagePageRequest(data: uniq, source: ImageSource(kind: .file, fileName: "uniq.png"))], via: "open", to: .newPages)
            wait { canvas.pages.count == n3 + 1 }
            let key = canvas.doc.images.first?.asset.key ?? "?"
            r["undoFileBefore"] = files().keys.contains { $0.hasPrefix(key) }
            app.undo()
            r["undoRemovedPage"] = canvas.pages.count == n3 && !canvas.pages.contains { $0.images.contains { $0.asset.key == key } }
            TestPersist.waitForSave(canvas) {}
            wait(5) { !files().keys.contains { $0.hasPrefix(key) } }
            r["undoFileAfterSave"] = files().keys.contains { $0.hasPrefix(key) }
            // 6. Ink on the pasted picture's page (the real input path, draw mode without the pointer lock).
            let pastedPage = canvas.pages.firstIndex { $0.images.first?.asset.pixelWidth == 1600 && $0.images.first?.asset.pixelHeight == 2400 } ?? 0
            canvas.goToPage(pastedPage)
            app.apply(.tool(.pen), from: "test")
            app.enterDrawMode(lock: false)
            let pen = TestPersist.Pen(canvas: canvas)
            var penDone = false
            pen.strokes(5, y0: 20) { penDone = true }
            wait(15) { penDone }
            r["inkOnPicture"] = canvas.doc.strokes.count
            r["inkPage"] = pastedPage
            // 7. Copy as Image (a selection over the picture and the ink), exports.
            canvas.setSelectionForTest(CGRect(x: 100, y: canvas.camera.page.height - 600, width: 900, height: 500))
            app.copySelectionAction()
            r["copyPNG"] = AppDelegate.pasteboard.data(forType: .png)?.count ?? 0
            canvas.setSelectionForTest(nil)
            try? canvas.export(ExportOptions(format: .png, scale: 1, area: .page, background: .paper), to: URL(fileURLWithPath: dir + "/export.png"))
            try? canvas.export(ExportOptions(format: .svg, scale: 1, area: .page, background: .paper), to: URL(fileURLWithPath: dir + "/export.svg"))
            try? canvas.exportPDF(to: URL(fileURLWithPath: dir + "/export.pdf"))
            if let d = AppDelegate.pasteboard.data(forType: .png) { try? d.write(to: URL(fileURLWithPath: dir + "/copy.png")) }
            // The window as it is (the script's screenshot of this window).
            app.exitDrawMode("test")
            spin(0.3); shot("writing", app: app)
            write(r, "images-write.json")
            // 8. Saved; the expected state; then mid-stroke until the script's kill -9.
            canvas.setNeedsRender()
            TestPersist.waitForSave(canvas) {
                write(summary(app), "expected.json")
                try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/before.png"), pxPerUnit: 1)
                app.enterDrawMode(lock: false)
                pen.stroke(at: 60, x0: 20, len: 60, lift: false) {
                    write(["inFlightPoints": canvas.liveStrokePointCountForTest], "midstroke.json")
                    Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in pen.frame(CGPoint(x: 50, y: 60)) }
                }
            }
        case "big":
            // A plain page first (latency baseline), then a 4000 x 12000 screenshot.
            app.enterDrawMode(lock: false)
            let pen = TestPersist.Pen(canvas: canvas)
            var done = false
            canvas.logger.event(["what": "phase", "phase": "plain"])
            pen.strokes(12, y0: 15) { done = true }; wait(30) { done }
            let shot = autoreleasepool { encode(card(4000, 12000, hue: 0.55), .png) }
            let m0 = TestImagesMemory.footprintMB()
            let t0 = CACurrentMediaTime()
            var made = false
            app.importImages([ImagePageRequest(data: shot, source: ImageSource(kind: .paste, fileName: "Long screenshot.png"))], via: "paste")
            let n = canvas.pages.count
            wait(20) { canvas.pages.count > n - 1 && canvas.doc.images.first?.asset.pixelHeight == 12000 }
            made = canvas.doc.images.first?.asset.pixelHeight == 12000
            r["importSeconds"] = CACurrentMediaTime() - t0; r["made"] = made
            spin(0.5)
            r["footprintAfterImportMB"] = TestImagesMemory.footprintMB()
            canvas.logger.event(["what": "phase", "phase": "picture"])
            done = false; pen.strokes(12, y0: 15) { done = true }; wait(30) { done }
            // Scroll the whole picture: one arrow step per display frame, down then up, zoom 1 then 2.
            app.exitDrawMode("test")
            for z in [1.0, 2.0] {
                canvas.setZoom(z); spin(0.3)
                canvas.resetPerf()
                for k in 0..<240 { canvas.panByArrow(dx: 0, dy: k < 120 ? 1 : -1, screen: false); spin(1.0 / 60) }
                let p = canvas.perf
                func q(_ v: [Double], _ f: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[Int(f * Double(s.count - 1))] }
                let work = zip(p.cpu, p.drawableWait).map { $0 - $1 }   // the frame's own work: minus waiting for a drawable
                r["zoom\(Int(z))"] = ["frames": p.cpu.count, "cpuP50": q(p.cpu, 0.5), "cpuP95": q(p.cpu, 0.95), "gpuP50": q(p.gpu, 0.5), "gpuP95": q(p.gpu, 0.95),
                                      "buildP95": q(p.build, 0.95), "waitP95": q(p.drawableWait, 0.95), "workP50": q(work, 0.5), "workP95": q(work, 0.95),
                                      "gapP50": q(p.gaps, 0.5), "gapP95": q(p.gaps, 0.95), "gapMax": p.gaps.max() ?? 0]
            }
            r["footprintMB"] = [m0, TestImagesMemory.footprintMB()]
            r["gpuTexturesMB"] = Double(canvas.renderer.images.residentBytes) / 1_048_576
            r["strokeLog"] = canvas.logger.path
            write(r, "images-big.json")
        default:   // read
            var s = summary(app)
            s["loadStatus"] = app.notebookStatus
            s["hint"] = app.container.hint.stringValue
            write(s, "actual.json")
            try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/after.png"), pxPerUnit: 1)
        }
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}

enum TestImagesMemory {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
