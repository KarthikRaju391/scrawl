// --test-export: File › Export Page… end to end in the real app. ⇧⌘E through the menu opens the save sheet with the
// options; the test changes them as a person would (each control's own action), reads the size shown, waits while
// checks/export.sh photographs the sheet, then saves through the sheet's own Save. The saved files, the remembered
// choices, the usage event and a "What's on screen" export against the canvas's render go to test-export.json.
import AppKit

enum TestExport {
    static func run(app: AppDelegate) {
        let dir = AppPaths.dataDir
        TestCrash.noReports(crashOnly: true)   // a crash here must never leave a dialog on the screen
        var r: [String: Any] = [:]
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func step(_ s: String) { try? s.write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8) }
        /// Asks checks/export.sh to photograph the window and its sheet (shot-<name>.req) and waits for shot-<name>.done; 15 s at most.
        func photo(_ name: String) {
            FileManager.default.createFile(atPath: dir + "/shot-\(name).req", contents: nil)
            let d = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: dir + "/shot-\(name).done") && Date() < d { spin(0.1) }
        }
        /// The File menu item whose shortcut is ⇧⌘E, triggered as the menu does (a synthetic key event can't reach a
        /// background app's menu reliably).
        func shiftCmdE() -> Bool {
            guard let m = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu,
                  let i = m.items.firstIndex(where: { $0.keyEquivalent.lowercased() == "e" && $0.keyEquivalentModifierMask == [.command, .shift] }) else { return false }
            m.performActionForItem(at: i)
            return true
        }
        func openSheet() -> (NSSavePanel, ExportAccessory?)? {
            guard shiftCmdE() else { return nil }
            let d = Date().addingTimeInterval(5)
            while app.window.attachedSheet == nil && Date() < d { spin(0.05) }
            spin(0.4)
            // The panel can hand back a wrapper for its accessory view; the app keeps the options view it attached.
            r["openSheetSeen", default: [String]()] = (r["openSheetSeen"] as? [String] ?? []) + ["panel \(app.exportPanel != nil) sheet \(String(describing: app.window.attachedSheet.map { type(of: $0) })) acc \(app.exportAccessory != nil) accWin \(app.exportAccessory?.window != nil)"]
            guard let p = app.exportPanel, app.window.attachedSheet != nil else { return nil }
            return (p, app.exportAccessory.flatMap { $0.window != nil ? $0 : nil })
        }
        func pick(_ p: NSPopUpButton, _ title: String) { p.selectItem(withTitle: title); _ = p.sendAction(p.action, to: p.target) }
        /// Types a percentage into the field, as a person would (the field's text and the live update).
        func type(_ a: ExportAccessory, _ text: String) { a.percent.stringValue = text; a.takePercent(text) }
        let out = dir + "/exports"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        func finish() {
            Analytics.shared.flushAndWait()
            let log = (try? String(contentsOfFile: AppPaths.logsDir + "/events.jsonl", encoding: .utf8)) ?? ""
            r["exportEvents"] = log.split(separator: "\n").filter { $0.contains("\"export\"") }.map(String.init)
            r["panelChose"] = app.exportChosenForTest
            r["exports"] = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-export.json"))
            step("done")
        }
        let c = app.canvas
        app.exportDirectoryForTest = out   // never the person's own folders
        if c.drawMode { app.exitDrawMode("test") }

        // A page with pen, marker and a self-crossing highlighter, on dot paper, viewed at 250%.
        func wave(_ x: Double, _ y: Double, _ n: Int = 60) -> [StrokePoint] {
            (0..<n).map { StrokePoint(p: CGPoint(x: x + Double($0) * 8, y: y + sin(Double($0) / 5) * 30), pressure: 0.3 + 0.4 * abs(sin(Double($0) / 7))) }
        }
        for k in 0..<4 { c.testAddStroke(wave(120, 850 - Double(k) * 110)) }
        c.testAddStroke(wave(150, 400), tool: .marker, color: SIMD4(0x1A / 255, 0x73 / 255, 0xE8 / 255, 1))
        c.testAddStroke((0...240).map { i in let t = Double(i) / 240 * 2 * .pi; return StrokePoint(p: CGPoint(x: 700 + 260 * sin(t), y: 600 + 130 * sin(2 * t)), pressure: 0.5) },
                        tool: .highlighter, color: SIMD4(0xFD / 255, 0xD6 / 255, 0x63 / 255, 0.35), sizePt: 28)
        c.testAddStroke(wave(300, -500))
        var t = c.tools; t.background = 2; c.tools = t
        c.setVisibleForReplay(x: 450, y: 420, w: 0, z: 2.5)
        spin(0.3)
        r["strokes"] = c.doc.strokes.count
        r["menuTitle"] = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu?.items.first { $0.keyEquivalent == "e" && $0.keyEquivalentModifierMask.contains(.shift) }?.title ?? ""

        // 1. ⇧⌘E opens the sheet with the options, at the defaults.
        guard let (panel, accOpt) = openSheet() else {
            r["sheet"] = false; finish(); return
        }
        r["sheet"] = true
        guard let acc = accOpt else {
            r["accessory"] = false
            app.window.endSheet(panel, returnCode: .cancel); spin(0.3); finish(); return
        }
        r["accessory"] = true
        func state() -> [String: Any] {
            let o = acc.options
            return ["format": o.format.rawValue, "scale": o.scale, "area": o.area.rawValue, "background": o.background.rawValue, "label": acc.sizeLabel.stringValue,
                    "orange": acc.sizeLabel.textColor == .systemOrange, "type": panel.allowedContentTypes.first?.preferredFilenameExtension ?? "", "name": panel.nameFieldStringValue,
                    "percent": acc.percent.stringValue, "scaleItem": acc.scale.titleOfSelectedItem ?? ""]
        }
        let page = c.exportArea(.page), screen = c.exportArea(.screen)
        r["pageRect"] = [page.minX, page.minY, page.width, page.height]
        r["screenRect"] = [screen.minX, screen.minY, screen.width, screen.height]
        r["visible"] = [c.camera.visible.minX, c.camera.visible.minY, c.camera.visible.width, c.camera.visible.height]
        r["bounds"] = [c.bounds.width, c.bounds.height]
        r["pageTop"] = c.camera.page.height
        var states: [[String: Any]] = []
        states.append(["step": "opened"].merging(state()) { a, _ in a })
        photo("defaults")
        pick(acc.format, "SVG"); states.append(["step": "svg"].merging(state()) { a, _ in a })
        pick(acc.scale, "3×"); states.append(["step": "3x"].merging(state()) { a, _ in a })
        pick(acc.scale, "Custom"); type(acc, "250"); states.append(["step": "250%"].merging(state()) { a, _ in a })
        pick(acc.area, "What's on screen"); states.append(["step": "screen"].merging(state()) { a, _ in a })
        pick(acc.background, "Transparent"); states.append(["step": "transparent"].merging(state()) { a, _ in a })
        photo("svg-screen")
        pick(acc.area, "Page"); type(acc, "800"); states.append(["step": "800% page"].merging(state()) { a, _ in a })
        photo("capped")
        type(acc, "40"); states.append(["step": "40% typed"].merging(state()) { a, _ in a })
        type(acc, "250"); pick(acc.area, "What's on screen")

        // 2. Save (the sheet's OK): SVG, 250%, what's on screen, transparent. The sheet opened in `out` (set before it was
        //    shown) with a .png name; the format was switched to SVG while it was up.
        spin(0.3)
        app.window.endSheet(panel, returnCode: .OK)   // the sheet's Save (ok(_:) raises on an out-of-process panel)
        var d = Date().addingTimeInterval(5)
        while app.window.attachedSheet != nil && Date() < d { spin(0.05) }
        spin(0.5)
        r["states"] = states
        /// The files in `out` with that extension, and whether each one's bytes are that format.
        func saved(_ ext: String) -> [(name: String, isFormat: Bool)] {
            ((try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []).filter { $0.hasSuffix("." + ext) }.sorted().map { n in
                let head = (try? FileHandle(forReadingFrom: URL(fileURLWithPath: out + "/" + n)).readData(ofLength: 8)) ?? Data()
                return (n, ext == "png" ? head.starts(with: [0x89, 0x50, 0x4E, 0x47]) : head.starts(with: Array("<?xml".utf8)))
            }
        }
        let svgFiles = saved("svg")
        r["svgFiles"] = svgFiles.map { "\($0.name) \($0.isFormat ? "is SVG" : "is NOT SVG")" }
        r["pngFilesAfterSVG"] = saved("png").map(\.name)
        r["savedSVG"] = svgFiles.count == 1 && svgFiles[0].isFormat
        if let f = svgFiles.first, let svg = try? String(contentsOfFile: out + "/" + f.name, encoding: .utf8) {
            r["svgHead"] = String(svg.prefix(400))
            r["svgPaths"] = svg.components(separatedBy: "class=\"stroke").count - 1
        }
        r["svgWantPaths"] = c.doc.strokes.filter { $0.bounds.intersects(screen) }.count

        // 3. Reopened, the sheet remembers those choices; save a PNG of the view at the screen's density (Paper).
        guard let (panel2, acc2o) = openSheet(), let acc2 = acc2o else { r["reopened"] = false; finish(); return }
        let o2 = acc2.options
        r["reopened"] = ["format": o2.format.rawValue, "scale": o2.scale, "area": o2.area.rawValue, "background": o2.background.rawValue, "name": panel2.nameFieldStringValue]
        let pct = c.ptPerUnit * c.camera.zoom * Double(app.window.backingScaleFactor) * 100
        pick(acc2.format, "PNG"); pick(acc2.background, "Paper"); type(acc2, String(Int(pct.rounded())))
        r["screenPercent"] = Int(pct.rounded())
        spin(0.3)
        app.window.endSheet(panel2, returnCode: .OK)
        d = Date().addingTimeInterval(5)
        while app.window.attachedSheet != nil && Date() < d { spin(0.05) }
        spin(0.5)
        let pngFiles = saved("png")
        r["pngFiles"] = pngFiles.map { "\($0.name) \($0.isFormat ? "is PNG" : "is NOT PNG")" }
        r["svgFilesAfterPNG"] = saved("svg").map(\.name)
        r["savedPNG"] = pngFiles.count == 1 && pngFiles[0].isFormat
        if let f = pngFiles.first, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: out + "/" + f.name) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            r["pngSize"] = [img.width, img.height]
            // The canvas's own render of the view at the same pixels per page unit.
            let s = Double(Int(pct.rounded())) / 100 / (c.ptPerUnit * c.camera.zoom)
            if let snap = c.snapshot(scale: s) {
                r["snapSize"] = [snap.width, snap.height]
                if snap.width == img.width && snap.height == img.height {
                    func px(_ i: CGImage) -> [UInt8] {
                        let ctx = CGContext(data: nil, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        ctx.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
                        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: i.width * i.height * 4))
                    }
                    let a = px(img), b = px(snap)
                    var over = 0, sum = 0
                    for i in stride(from: 0, to: a.count, by: 4) {
                        var m = 0; for k in 0..<3 { m = max(m, abs(Int(a[i + k]) - Int(b[i + k]))) }
                        if m > 40 { over += 1 }; sum += m
                    }
                    r["screenDiffOver40"] = Double(over) / Double(a.count / 4)
                    r["screenDiffMean"] = Double(sum) / Double(a.count / 4)
                }
                if let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out + "/canvas-render.png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dst, snap, nil); CGImageDestinationFinalize(dst)
                }
            }
        }
        // 4. Cancel leaves no file and changes nothing.
        if let (p3, _) = openSheet() {
            let before = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
            app.window.endSheet(p3, returnCode: .cancel); spin(0.4)
            r["cancelLeavesNoFile"] = ((try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []).count == before.count && app.window.attachedSheet == nil
        }
        finish()

    }
}
