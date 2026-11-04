// Attachments: a picture inserted on the open page, then selected, moved, resized, deleted and reordered with the Select
// tool through the canvas's own pointer handlers. Checks the frames exactly (page units), that the ink never moves, that
// each change is one undo step (undo and redo give back the exact objects), that the notebook keeps the current frame
// and the history, that exports draw the picture where it now is, and that backups keep their pictures.
import AppKit

private func card(_ w: Int, _ h: Int, _ rgb: (CGFloat, CGFloat, CGFloat)) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(.black); ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: 2))
    let d = NSMutableData(); let dest = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest); return d as Data
}

func attachmentChecks(_ check: (Bool, String) -> Void) {
    let tmp = NSTemporaryDirectory() + "scrawl-attach-bench-\(getpid())"
    try? FileManager.default.removeItem(atPath: tmp)
    ImageStore.root = tmp + "/Images"; ImageStore.cacheRoot = tmp + "/ImageCache"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    guard !AppPaths.persists || AppPaths.override != nil else { check(false, "attachments: saving would reach the real notebook: stopping"); return }

    let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 860), device: nil)
    var t = c.tools; t.tool = .select; c.tools = t
    let ink = (0..<60).map { StrokePoint(p: CGPoint(x: 300 + Double($0) * 12, y: 600 + sin(Double($0) / 5) * 40), pressure: 0.6) }
    c.testAddStroke(ink)
    let stroke = c.doc.strokes[0], strokeBounds = stroke.bounds
    func prep(_ d: Data, _ name: String) -> PreparedImagePage { PreparedImagePage(asset: try! ImageStore.importImage(d), request: ImagePageRequest(data: d, source: ImageSource(kind: .paste, fileName: name))) }
    let k = c.ptPerUnit * c.camera.zoom   // view points per page unit
    func near(_ a: CGRect, _ b: CGRect, _ tol: Double = 1e-6) -> Bool { abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol }
    func ev(_ type: NSEvent.EventType, _ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    /// The pointer from page point a to page point b (button down), through the canvas's handlers.
    func drag(_ a: CGPoint, _ b: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
        let va = c.viewPoint(fromCanvas: a), vb = c.viewPoint(fromCanvas: b)
        c.mouseDown(with: ev(.leftMouseDown, va, mods))
        for s in 1...8 { let f = Double(s) / 8; c.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: va.x + (vb.x - va.x) * f, y: va.y + (vb.y - va.y) * f), mods)) }
        c.mouseUp(with: ev(.leftMouseUp, vb, mods))
    }
    func click(_ p: CGPoint) { let v = c.viewPoint(fromCanvas: p); c.mouseDown(with: ev(.leftMouseDown, v)); c.mouseUp(with: ev(.leftMouseUp, v)) }

    // 1. Insert: centred in the view, at most 60% of it, the picture's proportions, never above its own pixel size.
    let big = prep(card(3000, 2000, (0.2, 0.5, 0.9)), "big.png"), small = prep(card(120, 80, (0.9, 0.3, 0.2)), "small.png")
    let undo0 = c.doc.canUndo
    let a = c.insertImage(big)
    let v = c.camera.visible
    check(abs(a.frame.midX - v.midX) < 1e-6 && abs(a.frame.midY - v.midY) < 1e-6 && a.frame.width <= v.width * 0.6 + 1e-6 && a.frame.height <= v.height * 0.6 + 1e-6
          && abs(a.frame.width / a.frame.height - 1.5) < 1e-9 && c.doc.images.count == 1 && c.doc.strokes.first === stroke,
          "insert: a large picture lands centred in the view (\(Int(a.frame.width)) x \(Int(a.frame.height)) units in a \(Int(v.width)) x \(Int(v.height)) view), 3:2 kept, under the ink")
    let b = c.insertImage(small, center: CGPoint(x: 1200, y: 300))
    let natural = 120.0 / 2 / k   // 120 px at 2x backing = 60 pt
    check(abs(b.frame.width - natural) < 1e-6 && abs(b.frame.midX - 1200) < 1e-6 && abs(b.frame.midY - 300) < 1e-6 && c.doc.images.last === b,
          "insert: a small picture keeps its own size (\(String(format: "%.1f", b.frame.width)) units = 60 pt) at the drop point, on top of the other")
    c.undo()
    check(c.doc.images.count == 1 && c.doc.images[0] === a, "undo takes the last inserted picture away (one step)")
    c.redo()
    check(c.doc.images.count == 2 && c.doc.images[1] === b && undo0, "redo puts the same picture back")

    // 2. Select by clicking; a click off pictures selects none and is the box selection's.
    click(CGPoint(x: a.frame.midX, y: a.frame.midY))
    check(c.selectedImageId == a.id && c.selection == nil, "a click on a picture with Select selects it (no box)")
    check(c.imageSelectionItems(vis: c.renderRect).count == 3, "the selected picture draws its outline and four handles")
    click(CGPoint(x: 1200, y: 300))
    check(c.selectedImageId == b.id, "a click where pictures overlap... selects the topmost under the pointer (the small one)")
    click(CGPoint(x: 100, y: 100))
    check(c.selectedImageId == nil, "a click off every picture deselects")

    // 3. Move: exactly the pointer's travel in page units; ink stays; one undo step.
    let steps0 = c.doc.canUndo, beforeMove = c.doc.images
    let from = CGPoint(x: a.frame.midX - 40, y: a.frame.midY + 10), dx = 200.0, dy = -120.0
    drag(from, CGPoint(x: from.x + dx, y: from.y + dy))
    guard let moved = c.selectedImage, moved.asset === a.asset else { check(false, "move: the picture is still selected after the drag"); return }
    check(near(moved.frame, a.frame.offsetBy(dx: dx, dy: dy), 1e-3) && moved.id != a.id && c.doc.images.count == 2 && c.doc.images[0] === moved,
          "move: the picture moved by the drag exactly (\(moved.frame.minX - a.frame.minX), \(moved.frame.minY - a.frame.minY) units), a new object in the same place in the order")
    check(c.doc.strokes.count == 1 && c.doc.strokes[0] === stroke && stroke.bounds == strokeBounds, "the ink didn't move or change")
    c.undo()
    check(c.doc.images.count == beforeMove.count && zip(c.doc.images, beforeMove).allSatisfy { $0 === $1 } && steps0, "one undo puts the picture back exactly where it was (the same object; the other picture untouched)")
    c.redo()
    check(c.doc.images.first === moved, "redo moves it again")

    // 4. Resize from the top-right corner: proportions kept, the bottom-left corner stays; with Shift, free.
    click(CGPoint(x: moved.frame.midX, y: moved.frame.midY))
    let tr = CGPoint(x: moved.frame.maxX, y: moved.frame.maxY)
    drag(tr, CGPoint(x: tr.x + 150, y: tr.y + 10))
    guard let r1 = c.selectedImage else { check(false, "resize: the picture is still selected after the drag"); return }
    check(abs(r1.frame.minX - moved.frame.minX) < 1e-6 && abs(r1.frame.minY - moved.frame.minY) < 1e-6 && abs(r1.frame.width / r1.frame.height - 1.5) < 1e-6
          && abs(r1.frame.width - (moved.frame.width + 150)) < 1e-3,
          "resize (top-right corner): grows with the pointer, 3:2 kept, the opposite corner fixed (\(Int(moved.frame.width)) -> \(Int(r1.frame.width)) units wide)")
    let tr2 = CGPoint(x: r1.frame.maxX, y: r1.frame.maxY)
    drag(tr2, CGPoint(x: tr2.x - 100, y: tr2.y + 80), .shift)
    guard let r2 = c.selectedImage else { check(false, "resize: the picture is still selected after the drag"); return }
    check(abs(r2.frame.width - (r1.frame.width - 100)) < 1e-3 && abs(r2.frame.height - (r1.frame.height + 80)) < 1e-3 && r2.frame.origin == r1.frame.origin,
          "resize with Shift: width and height follow the pointer freely (\(Int(r2.frame.width)) x \(Int(r2.frame.height)))")
    let bl = CGPoint(x: r2.frame.minX, y: r2.frame.minY)
    drag(bl, CGPoint(x: r2.frame.maxX + 500, y: r2.frame.maxY + 500))
    guard let r3 = c.selectedImage else { check(false, "resize: the picture is still selected after the drag"); return }
    check(r3.frame.width * k >= CanvasView.minImagePt - 1e-6 && r3.frame.height * k >= CanvasView.minImagePt - 1e-6 && abs(r3.frame.maxX - r2.frame.maxX) < 1e-6 && abs(r3.frame.maxY - r2.frame.maxY) < 1e-6,
          "resize past the opposite corner: it stops at the smallest size (\(String(format: "%.0f", r3.frame.width * k)) x \(String(format: "%.0f", r3.frame.height * k)) pt), never flips")
    c.undo(); c.undo()
    check(c.doc.images.first === r1 && c.doc.images.count == 2, "two undos step back through two resizes exactly")
    c.redo(); c.redo()

    // 5. A click on a picture without moving it is no edit.
    let canUndoBefore = c.doc.canUndo, imgsBefore = c.doc.images
    if let f = c.doc.images.first { click(CGPoint(x: f.frame.midX, y: f.frame.midY)) }
    c.undo(); c.redo()
    check(c.doc.images.count == imgsBefore.count && zip(c.doc.images, imgsBefore).allSatisfy { $0 === $1 } && canUndoBefore, "a click that doesn't move a picture adds no undo step")

    // 6. Reorder and delete.
    if let f = c.doc.images.first { click(CGPoint(x: f.frame.midX, y: f.frame.minY + 2)) }
    guard let bottom = c.selectedImage else { check(false, "a click selects the bottom picture"); return }
    c.reorderSelectedImage(1)
    check(c.doc.images.last === bottom, "Bring Forward: the selected picture goes above the other")
    c.undo()
    check(c.doc.images.first === bottom, "undo: back below")
    c.redo()
    let beforeDelete = c.doc.images
    c.deleteSelectedImage()
    check(c.doc.images.count == 1 && !c.doc.images.contains { $0 === bottom } && c.selectedImageId == nil && c.doc.strokes[0] === stroke, "⌫ deletes the selected picture (not the ink)")
    check(c.notebookSnapshot().imageKeys.contains(bottom.asset.key), "a deleted picture's file stays while the undo history refers to it")
    c.undo()
    check(c.doc.images.count == beforeDelete.count && zip(c.doc.images, beforeDelete).allSatisfy { $0 === $1 }, "undo brings the deleted picture back, exactly as it was (order too)")

    // 7. Another tool or another page clears the selection.
    click(CGPoint(x: bottom.frame.midX, y: bottom.frame.midY))
    t.tool = .pen; c.tools = t
    check(c.selectedImageId == nil, "switching tool clears the picture selection")
    t.tool = .select; c.tools = t

    // 8. The notebook keeps the current frames and the history (each edit is its own object).
    let f = c.notebookFile(), data = try! f.encoded()
    let d = CanvasView(frame: c.frame, device: nil)
    d.load(try! NotebookFile.decode(data))
    let same = d.doc.images.count == c.doc.images.count && zip(d.doc.images, c.doc.images).allSatisfy { $0.id == $1.id && $0.frame == $1.frame && $0.asset.key == $1.asset.key }
    let ids = Set((f.images ?? []).map(\.id))
    check(same && ids.count == (f.images ?? []).count, "notebook round trip: the pictures where they are now (\(d.doc.images.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))w" })); \(ids.count) image objects in the file, ids unique")
    var backs = 0
    while d.doc.canUndo && !d.doc.images.isEmpty && backs < 30 { d.undo(); backs += 1 }
    check(d.doc.images.isEmpty && d.doc.strokes.count == 1 && d.doc.strokes[0].id == stroke.id, "undo on the reopened page steps back through every picture edit to the page with only its ink (\(backs) steps)")

    // 9. Export: the picture drawn where it now is.
    guard let now = c.doc.images.first(where: { $0.asset === big.asset }) else { check(false, "export: the moved picture is on the page"); return }
    let e = PageExport(strokes: [], rect: CGRect(x: 0, y: -200, width: 1600, height: c.camera.page.height + 200), pageWidth: 1600, pageTop: c.camera.page.height,
                       paper: 0, options: ExportOptions(format: .png, scale: 0.5, area: .page, background: .white), images: c.doc.images)
    let img = e.image()!
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func at(_ p: CGPoint) -> (Int, Int, Int) {
        let x = Int((p.x - e.rect.minX) * 0.5), y = Int((e.rect.maxY - p.y) * 0.5), i = (y * img.width + x) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
    let inside = at(CGPoint(x: now.frame.minX + now.frame.width * 0.25, y: now.frame.minY + now.frame.height * 0.25)), old = at(CGPoint(x: a.frame.minX + 4, y: a.frame.maxY - 4))
    check(inside.2 > 200 && inside.0 < 80 && (old == (255, 255, 255) || now.frame.contains(CGPoint(x: a.frame.minX + 4, y: a.frame.maxY - 4))),
          "export draws the picture where it was moved to (\(inside)), not where it was (\(old))")

    // 10. Backups keep their pictures: a picture only a backup refers to isn't removed.
    let backupsDir = tmp + "/Backups"
    try? FileManager.default.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: backupsDir + "/Notebook-daily-20261104.tdnb"))
    let inBackup = ImageStore.keysInBackups(backupsDir)
    let removed = ImageStore.collectGarbage(keep: inBackup, grace: 0)
    check(inBackup.contains(big.asset.key) && inBackup.contains(small.asset.key) && removed.isEmpty && FileManager.default.fileExists(atPath: big.asset.path),
          "a picture a backup refers to stays when no page uses it any more (\(inBackup.count) kept, \(removed.count) removed)")
}
