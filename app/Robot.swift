// --test-robot <dir>: the robot user's hook (robot/robot.py drives it). Dev builds only: release builds compile
// this file to nothing, so the shipped app has no way in.
//
// The driver writes <dir>/cmd-N.json; the app runs it and writes <dir>/res-N.json. Keys come from outside as
// real CGEvents posted to this process (robot/robot-input.swift). What comes in here:
//   touch  frames for the trackpad callback (Multitouch.onFrame, the MultitouchSupport/NSTouch entry point),
//          fed from a thread on the driver's 8 ms clock, like the real driver
//   click  a toolbar button, as AppKit mouse events through window.sendEvent (hit-testing and all). macOS
//          doesn't deliver CGEvent clicks posted to a background app, and system-wide clicks would take the
//          pointer from the person using the Mac
//   state  what the user would see: modes, tool, page, view, toast, panel, overview selection, frame timing
//   window resize the window; quit (the normal quit path, which saves)
// A line marked "robot:needs <text>" uses a feature newer than some old commits: robot/old-commit.sh drops it
// when the old commit's app/ sources don't contain <text>.
#if !RELEASE
import AppKit
import QuartzCore

final class Robot {
    let app: AppDelegate, dir: String
    private var next = 1
    private var timer: Timer?
    private var busy = false
    private var gapsMark = 0
    private var stepStart = 0.0

    init(app: AppDelegate, dir: String) { self.app = app; self.dir = dir }

    func start() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // A crash in a robot run fails the run (robot.py sees the exit); it must not put a "quit unexpectedly"
        // dialog on Karthik's screen. ROBOT_CRASH_REPORTS=1 keeps the report, for a stack trace.
        if ProcessInfo.processInfo.environment["ROBOT_CRASH_REPORTS"] != "1" { TestCrash.noReports(crashOnly: true) }   // robot:needs static func noReports
        app.canvas.resumeOnDrawStart = true   // robot:needs var resumeOnDrawStart
        app.warmsThumbnails = true; app.warmThumbnails()   // robot:needs func warmThumbnails
        let t = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        try? "\(ProcessInfo.processInfo.processIdentifier) \(app.window.windowNumber)".write(toFile: dir + "/ready", atomically: true, encoding: .utf8)
    }

    // Main-thread stalls: the gaps between this 4 ms timer's ticks. A stall here is ink that freezes and jumps
    // (what the autosave bug did), whether or not the window is on screen to present frames.
    private var lastTick = 0.0
    private var tickGaps: [Double] = []

    private func poll() {
        let now = CACurrentMediaTime()
        if lastTick > 0 { tickGaps.append((now - lastTick) * 1000) }
        lastTick = now
        guard !busy else { return }
        let p = dir + "/cmd-\(next).json"
        guard let d = FileManager.default.contents(atPath: p), let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        busy = true
        let n = next
        next += 1
        run(c) { [weak self] r in
            guard let self else { return }
            var r = r; r["n"] = n
            if let out = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) {
                try? out.write(to: URL(fileURLWithPath: self.dir + "/res-\(n).tmp"))
                try? FileManager.default.moveItem(atPath: self.dir + "/res-\(n).tmp", toPath: self.dir + "/res-\(n).json")
            }
            self.busy = false
        }
    }

    private func run(_ c: [String: Any], done: @escaping ([String: Any]) -> Void) {
        let canvas = app.canvas
        switch c["cmd"] as? String ?? "" {
        case "state":
            done(state())
        case "mark":   // start of a step: frame timing from here
            gapsMark = canvas.perf.gaps.count; stepStart = CACurrentMediaTime(); tickGaps = []
            done(["ok": true])
        case "touch":
            // Contacts are [id, x, y, pressure, size, major, state] in pad mm, or 0...1 with "norm" (recorded sessions).
            // state is the sensor's (4 touching, 5 breaking, 6 lingering, 3 making); 4 if left out.
            let k = (c["norm"] as? Bool ?? false) ? Multitouch.padMM : CGSize(width: 1, height: 1)
            let clickAt = Set((c["frames"] as? [[Any]] ?? []).enumerated().compactMap { ($0.element.count > 2 && ($0.element[2] as? String) == "click") ? $0.offset : nil })
            let frames = (c["frames"] as? [[Any]] ?? []).map { f -> (Double, [Contact]) in
                let cs = (f[1] as? [[Double]] ?? []).map { v in
                    let mm = CGPoint(x: v[1] * k.width, y: v[2] * k.height)
                    return Contact(id: Int32(v[0]), state: v.count > 6 ? Int32(v[6]) : 4, norm: CGPoint(x: mm.x / Multitouch.padMM.width, y: mm.y / Multitouch.padMM.height),
                                   mm: mm, pressure: v[3], size: v.count > 4 ? v[4] : 0.5, major: v.count > 5 ? v[5] : 7.5)
                }
                return (f[0] as? Double ?? 0.008, cs)
            }
            // The view at each touch-down of a new contact, so the driver can tell whether the page moved
            // inside a word.
            let downs = Downs()
            let t = Thread {
                var deadline = CACurrentMediaTime(), sensorT = 0.0
                var seen = Set<Int32>()
                var k = 0
                for (dt, cs) in frames {
                    deadline += dt; sensorT += dt
                    preciseWait(until: deadline)
                    k += 1
                    if k % 3 == 0 {   // the page as the user sees it while touching (e.g. the undo scrub's live preview)
                        DispatchQueue.main.sync {
                            let n = canvas.doc.strokes.count; if downs.trace.last != n { downs.trace.append(n) }
                            if !self.app.container.pageMap.isHidden && self.app.container.pageMap.alphaValue > 0.05 { downs.mapSeen += 1 }   // robot:needs class PageMapView
                        }
                    }
                    for c in cs where !seen.contains(c.id) {
                        seen.insert(c.id)
                        DispatchQueue.main.sync { downs.items.append(["id": Int(c.id), "view": Self.view(canvas)]) }
                    }
                    Multitouch.onFrame?(cs, CACurrentMediaTime(), sensorT)
                    if clickAt.contains(k - 1) { DispatchQueue.main.sync { self.app.robotCanvasClick() } }   // robot:needs func robotCanvasClick
                }
                Thread.sleep(forTimeInterval: c["settle"] as? Double ?? 0.6)
                DispatchQueue.main.async { canvas.flushInputForTest(); done(["frames": frames.count, "downs": downs.items, "strokeTrace": downs.trace, "mapSeen": downs.mapSeen]) }
            }
            t.qualityOfService = .userInteractive
            t.start()
        case "click":
            let item = Self.item(c["item"] as? String ?? "")
            let how = c["how"] as? String ?? "plain"
            let tb = app.container.toolbar
            guard let item, var p = tb.center(of: item) else { done(["error": "no such item"]); return }
            if how == "chevron", let q = tb.chevron(of: item) { p = q }   // robot:needs func chevron(of
            let types: [NSEvent.EventType] = how == "right" ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            gapsMark = canvas.perf.gaps.count; stepStart = CACurrentMediaTime()
            for t in types {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: how == "control" ? [.control] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }
            }
            // Click to the first frame the canvas presents after it (null if nothing on the canvas changed).
            let t0 = CACurrentMediaTime(), n0 = canvas.perf.gaps.count
            func wait() {
                if canvas.perf.gaps.count > n0 { done(["firstFrameMs": (CACurrentMediaTime() - t0) * 1000]); return }
                if CACurrentMediaTime() - t0 > 0.5 { done(["firstFrameMs": NSNull()]); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { wait() }
            }
            wait()
        case "menu":   // a menu item, as picked with the pointer. ⌘-shortcuts posted to an app in the background
                       // never reach its menu, so the robot uses the menu for those.
            let sel = NSSelectorFromString(c["action"] as? String ?? "")
            for top in NSApp.mainMenu?.items ?? [] {
                for i in top.submenu?.items ?? [] where i.action == sel {
                    var enabled = true
                    enabled = app.validateMenuItem(i)   // robot:needs func validateMenuItem
                    if enabled { NSApp.sendAction(sel, to: i.target, from: i) }
                    done(["ok": true]); return
                }
            }
            done(["error": "no menu item"])
        case "clickMap":   // a click (or a drag, with "to") on the page map at fractions of its size
            var ok = false
            ok = clickMap(c)   // robot:needs class PageMapView
            done(ok ? ["ok": true] : ["error": "no page map"])
        case "settingsSwitch":   // a click on a Settings checkbox
            var ok = false
            ok = { app.settingsWindow.setSwitchForTest(c["index"] as? Int ?? 0, c["on"] as? Bool ?? true); return true }()   // robot:needs class SettingsWindow
            done(ok ? ["ok": true] : ["error": "no settings window"])
        case "pageCorner":   // 0.1.6: the view's top-left at the page's top-left, zoom kept (arrow keys no longer stop at the page's edge)
            let cam = canvas.camera, v = cam.visible
            if c["left"] as? Bool ?? true { canvas.setVisibleForReplay(x: 0, y: (c["top"] as? Bool ?? true) ? cam.page.height - v.height : v.minY, w: v.width, z: cam.zoom) }
            else { canvas.setVisibleForReplay(x: v.minX, y: cam.page.height - v.height, w: v.width, z: cam.zoom) }
            canvas.flushInputForTest()
            done(["view": Self.view(canvas)])
        case "tileMenu":   // the overview tile's context menu: its items, then "Delete Page" picked
            var r: [String: Any] = ["error": "no tile menu"]
            r = app.robotTileMenu(c["index"] as? Int ?? 0)   // robot:needs func robotTileMenu
            done(r)
        case "zoomMenu":   // the toolbar's zoom menu: its items; then pick `pick` or type `type` (percent) in its field
            var r: [String: Any] = ["error": "no zoom menu"]
            r = app.robotZoomMenu(pick: c["pick"] as? String, type: c["type"] as? String)   // robot:needs func robotZoomMenu
            done(r)
        case "enterDrawLocked":   // draw mode as the user gets it: the pointer frozen (a dry-run lock in tests)
            app.enterDrawMode(lock: true)
            done(["ok": true])
        case "settingsKey":   // a key pressed while the Settings window is in front (it goes to that window)
            guard let w = app.settingsWindow.window, w.isVisible else { done(["error": "no settings window"]); return }   // robot:needs class SettingsWindow
            let ch = c["chars"] as? String ?? "\u{1b}"
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                        context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: UInt16(c["code"] as? Int ?? 53)) { NSApp.sendEvent(e) }
            done(["ok": true])
        case "closeSettings":
            app.settingsWindow.window?.performClose(nil)   // robot:needs class SettingsWindow
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(["ok": true]) }
        case "dropThumbnails":
            ThumbnailCache.shared.dropAll()   // robot:needs func dropAll
            done(["ok": true])
        case "toPagePt":   // pad mm -> page (same as toPage, for one point)
            let v = canvas.camera.visible
            let q = c["point"] as? [Double] ?? [0, 0]
            var n = CGPoint(x: q[0] / Multitouch.padMM.width, y: q[1] / Multitouch.padMM.height)
            n = Camera.active(n)
            done(["point": [v.minX + n.x * v.width, v.minY + n.y * v.height]])
        case "clickDrawTimeout":
            app.setClickDrawTimeout(c["seconds"] as? Double ?? 3)   // robot:needs func setClickDrawTimeout
            done(["ok": true])
        case "canvasClick":   // a trackpad click in draw mode: the frozen pointer sits on the canvas, so it lands there
            app.robotCanvasClick()   // robot:needs func robotCanvasClick
            done(["ok": true])
        case "panelPick":   // a click on a tile of the open writing panel (line width 0-2, 3 writing off)
            let tb = app.container.toolbar
            guard !tb.panel.isHidden, let i = c["writing"] as? Int else { done(["error": "panel not open"]); return }
            let p = tb.panel.centerOfWriting(i)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }
            }
            done(["ok": true])
        case "seed":   // a notebook that's been used a lot: pages of handwriting-sized strokes (set-up, not a user action)
            let pages = c["pages"] as? Int ?? 20, per = c["perPage"] as? Int ?? 450
            for k in 0..<pages {
                if k > 0 || !canvas.doc.strokes.isEmpty { canvas.newPage() }
                for j in 0..<per {
                    let x0: Double = 60 + Double(j % 15) * 100, y0: Double = 940 - Double(j / 15) * 30
                    var pts: [StrokePoint] = []
                    for i in 0..<60 { let u = Double(i); pts.append(StrokePoint(p: CGPoint(x: x0 + u * 1.2, y: y0 + sin(u / 3) * 10), pressure: 0.6)) }
                    canvas.testAddStroke(pts)
                }
            }
            done(["pages": canvas.pages.count])
        case "toPage":   // pad mm -> the page point under it now
            let v = canvas.camera.visible
            let pts = (c["points"] as? [[Double]] ?? []).filter { $0.count >= 2 }.map { q -> [Double] in
                var n = CGPoint(x: q[0] / Multitouch.padMM.width, y: q[1] / Multitouch.padMM.height)
                n = Camera.active(n)   // robot:needs static func active(
                return [v.minX + n.x * v.width, v.minY + n.y * v.height]
            }
            done(["points": pts])
        case "toPad":   // page points -> where they are on the pad now (mm), as a user sees them on screen
            let pts = (c["points"] as? [[Double]] ?? []).filter { $0.count >= 2 }.map { Self.padMM(canvas, CGPoint(x: $0[0], y: $0[1])) }   // (a bad point is skipped, never a crash)
            done(["points": pts])
        case "exportPNG":   // the page as stored ink (the OCR reference for the screenshot)
            let path = c["path"] as? String ?? dir + "/page.png"
            var ok = false
            ok = (try? canvas.exportPNG(to: URL(fileURLWithPath: path))) != nil   // robot:needs func exportPNG
            done(ok ? ["ok": true] : ["error": "no export in this build"])
        case "window":
            let w = c["w"] as? Double ?? 1000, h = c["h"] as? Double ?? 700
            app.window.setContentSize(NSSize(width: w, height: h))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done(["ok": true]) }
        case "trap":   // an unexpected crash, as a bug in the app would cause (tests the crash handling)
            let a: [Int] = []; _ = a[c.count]
            done(["ok": true])
        case "quit":
            done(["ok": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        default:
            done(["error": "unknown command"])
        }
    }

    private func clickMap(_ c: [String: Any]) -> Bool {   // robot:needs class PageMapView
        let m = app.container.pageMap   // robot:needs class PageMapView
        guard !m.isHidden else { return false }   // robot:needs class PageMapView
        var pts = [CGPoint(x: c["x"] as? Double ?? 0.5, y: c["y"] as? Double ?? 0.5)]   // robot:needs class PageMapView
        if let to = c["to"] as? [Double] { pts.append(CGPoint(x: to[0], y: to[1])) }   // robot:needs class PageMapView
        for (i, f) in pts.enumerated() {   // robot:needs class PageMapView
            let p = m.convert(CGPoint(x: f.x * m.bounds.width, y: f.y * m.bounds.height), to: nil)   // robot:needs class PageMapView
            if let e = NSEvent.mouseEvent(with: i == 0 ? .leftMouseDown : .leftMouseDragged, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }   // robot:needs class PageMapView
        }   // robot:needs class PageMapView
        if let e = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { app.window.sendEvent(e) }   // robot:needs class PageMapView
        return true   // robot:needs class PageMapView
    }   // robot:needs class PageMapView

    final class Downs: @unchecked Sendable { var items: [[String: Any]] = []; var trace: [Int] = []; var mapSeen = 0 }

    static func view(_ canvas: CanvasView) -> [String: Double] {
        let v = canvas.camera.visible
        return ["x": v.minX, "y": v.minY, "w": v.width, "h": v.height, "zoom": canvas.camera.zoom]
    }

    /// Pad millimetres of a page point at the current view (the inverse of the trackpad mapping, edge guard included).
    static func padMM(_ canvas: CanvasView, _ p: CGPoint) -> [Double] {
        let v = canvas.camera.visible
        var n = CGPoint(x: (p.x - v.minX) / v.width, y: (p.y - v.minY) / v.height)
        n = Camera.pad(fromActive: n)   // robot:needs static func pad(fromActive
        return [n.x * Multitouch.padMM.width, n.y * Multitouch.padMM.height]
    }

    static func item(_ name: String) -> ToolbarView.Item? {
        switch name {
        case "undo": return .undo; case "redo": return .redo
        case "pen": return .tool(.pen); case "marker": return .tool(.marker); case "highlighter": return .tool(.highlighter); case "eraser": return .tool(.eraser)
        case "background": return .background; case "writing": return .writing; case "zoomLock": return .zoomLock
        case "draw": return .draw; case "prevPage": return .prevPage; case "nextPage": return .nextPage; case "newPage": return .newPage
        case "gallery": return .gallery   // robot:needs case gallery
        default: return nil
        }
    }

    private func state() -> [String: Any] {
        let canvas = app.canvas, tb = app.container.toolbar
        let gaps = Array(canvas.perf.gaps.suffix(from: min(gapsMark, canvas.perf.gaps.count)))
        let sorted = gaps.sorted()
        var s: [String: Any] = [
            "draw": canvas.drawMode, "writing": canvas.writingMode, "tool": canvas.tools.tool.rawValue, "zoomLocked": canvas.tools.zoomLocked,
            "lineWidth": canvas.tools.lineWidthIndex,
            "page": canvas.pageIndex, "pages": canvas.pages.count, "strokes": canvas.doc.strokes.count,
            "strokesPerPage": canvas.pages.map { $0.strokes.count },
            "view": Self.view(canvas),
            "padMM": [Multitouch.padMM.width, Multitouch.padMM.height],
            "pageW": canvas.camera.page.width,
            "lastStrokeEnds": canvas.doc.strokes.last.map { s -> [[Double]] in [[s.points[0].p.x, s.points[0].p.y], [s.points[s.points.count - 1].p.x, s.points[s.points.count - 1].p.y]] } ?? [],
            "lastStrokeMid": canvas.doc.strokes.last.map { s -> [Double] in let p = s.points[s.points.count / 2].p; return [p.x, p.y] } ?? [],
            "lastStrokes": canvas.doc.strokes.suffix(40).map { [$0.bounds.minX, $0.bounds.minY, $0.bounds.maxX, $0.bounds.maxY] },
            "toolbarHidden": tb.isHidden, "panelOpen": !tb.panel.isHidden,
            "toolbarTool": tb.state.tool.rawValue, "toolbarWriting": tb.writingMode, "toolbarDraw": tb.drawMode,
            "window": ["w": app.window.contentLayoutRect.width, "h": app.window.contentLayoutRect.height],
            // Frames presented since the step began: the longest gap between two frames, and how many gaps were
            // over 50 ms (a stall you can see).
            "frames": ["count": gaps.count, "maxGapMs": sorted.last ?? 0, "p99GapMs": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))],
                       "over50": gaps.filter { $0 > 50 }.count, "sinceMarkMs": (CACurrentMediaTime() - stepStart) * 1000],
            "mainThread": ["ticks": tickGaps.count, "maxStallMs": tickGaps.max() ?? 0, "over50": tickGaps.filter { $0 > 50 }.count,
                           "over20": tickGaps.filter { $0 > 20 }.count],
        ]
        s["toast"] = app.container.toast.isHidden ? "" : app.container.toast.stringValue   // robot:needs let toast
        s["panelMode"] = tb.panel.isHidden ? "" : "\(tb.panel.mode)"
        // Chrome over the page: what's on screen and how much of it (points squared).
        let b = app.container.banner
        var chrome: [String: Any] = ["banner": (!b.isHidden && b.alphaValue > 0.01) ? b.stringValue : "", "bannerArea": (!b.isHidden && b.alphaValue > 0.01) ? b.frame.width * b.frame.height : 0,
                                     "toolbarArea": tb.isHidden ? 0 : 15 * 44 * 44.0]
        chrome["capsule"] = app.container.capsule.isHidden ? "" : "\(app.container.capsule.info.map { "\($0.tool.title)\($0.writing ? " writing" : "")\($0.locked ? " locked" : "") \($0.zoom) \($0.page)/\($0.pages)" } ?? "")"   // robot:needs class StatusCapsule
        chrome["capsuleArea"] = app.container.capsule.isHidden ? 0 : app.container.capsule.frame.width * app.container.capsule.frame.height   // robot:needs class StatusCapsule
        chrome["frame"] = !app.container.drawFrame.isHidden   // robot:needs class DrawModeFrame
        s["chrome"] = chrome
        s["newLines"] = canvas.newLineCount
        s["follows"] = canvas.writingStateForTest.follows   // 0.1.6: the view following a long line
        s["columnBound"] = Camera.columnBound               // the rules before 0.1.6 (--column-bound)
        s["lineMeasure"] = WritingLayout.measureFromView ? "view" : "page"   // what the width setting is a share of (0.1.7: the page)
        s["clickDrawOn"] = canvas.clickDrawOn   // robot:needs var clickDrawOn
        s["aimRing"] = [CanvasView.aimRingColor.x, CanvasView.aimRingColor.y, CanvasView.aimRingColor.z, CanvasView.aimRingColor.w].map { (Double($0) * 100).rounded() / 100 }   // robot:needs aimRingColor
        s["pageBounds"] = canvas.doc.strokes.map { [$0.bounds.minX, $0.bounds.minY, $0.bounds.maxX, $0.bounds.maxY] }
        s["nextLine"] = canvas.nextLineAt.map { [$0.x, $0.y] } ?? []   // robot:needs var nextLineAt
        if let g = app.gallery, app.galleryShown {   // robot:needs class GalleryView
            s["thumbs"] = canvas.pages.map { d -> Int in let c = g.thumbnails.cached(d); return c.image == nil ? 0 : (c.fresh ? 2 : 1) }   // 0 blank, 1 old, 2 up to date
        }
        // Where posted keys can go: CGEvents posted to a background app reach only its key window (0.1.6.1 gate: a relaunched
        // copy that never got a key window ignored every key of a scenario).
        s["windowKey"] = app.window.isKeyWindow; s["appActive"] = NSApp.isActive; s["keyWindowIsOurs"] = NSApp.keyWindow === app.window
        s["galleryOpenMs"] = ((app.lastTransition["stepsMs"] as? [String: Double]) ?? [:]).values.reduce(0, +)
        s["cursorLocked"] = CursorLock.locked
        s["mapRegion"] = { let r = app.container.pageMap.regionForTest; return [r.minX, r.minY, r.maxX, r.maxY] }()   // robot:needs var regionForTest
        s["inkBounds"] = { var u = CGRect.null; for st in canvas.doc.strokes { u = u.union(st.bounds) }; return u.isNull ? [] : [u.minX, u.minY, u.maxX, u.maxY] }()
        s["zoomBadge"] = app.container.zoomBadge.isHidden || app.container.zoomBadge.alphaValue < 0.05 ? "" : app.container.zoomBadge.stringValue   // robot:needs let zoomBadge
        s["toolbarZoom"] = tb.zoomText   // robot:needs var zoomText
        s["pageArrows"] = [tb.canGoBack, tb.canGoForward]
        s["analyticsSession"] = Analytics.shared.context.sessionID   // robot:needs final class Analytics
        if let g = app.gallery, app.galleryShown {   // robot:needs class PageTitles
            s["galleryTitles"] = canvas.pages.map { g.titles.title($0) }   // robot:needs class PageTitles
            s["galleryMatching"] = g.matching; s["galleryQuery"] = g.query   // robot:needs class PageTitles
            s["searchFocused"] = app.window.firstResponder is NSText   // robot:needs class PageTitles
        }   // robot:needs class PageTitles
        s["thumbRegions"] = canvas.pages.map { let r = ThumbnailCache.region($0.strokes, page: canvas.camera.page); return [r.minX, r.minY, r.width, r.height] }   // robot:needs static func region(
        s["pasteboardPNG"] = AppDelegate.pasteboard.data(forType: .png)?.count ?? 0   // robot:needs static let pasteboard
        s["shareFile"] = app.lastSharePicker != nil ? (FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("Scrawl-share/Scrawl page \(app.actionPageIndex + 1).png").path) ? "ok" : "missing") : ""   // robot:needs var lastSharePicker
        s["haptics"] = Haptics.count   // robot:needs enum Haptics
        s["fading"] = canvas.ghostCountForTest   // robot:needs var ghostCountForTest
        s["pendingMove"] = app.container.pendingMove.isHidden ? "" : "\(app.container.pendingMove.kind.map { "\($0)" } ?? "")"   // robot:needs class PendingMoveView
        s["tips"] = Dictionary(uniqueKeysWithValues: Tips.Tip.allCases.map { ($0.rawValue, app.tips.count($0)) })   // robot:needs final class Tips
        s["practice"] = app.container.practice.isHidden ? [:] : ["done": app.container.practice.done.map { "\($0)" }.sorted()]   // robot:needs final class PracticeView
        s["toolbarTips"] = tb.tooltipsForTest   // robot:needs var tooltipsForTest
        s["settingsWindow"] = app.settingsWindow.window?.isVisible == true ? app.settingsWindow.window!.windowNumber : 0   // robot:needs class SettingsWindow
        s["lineLimitX"] = canvas.lineLimitX as Any   // robot:needs var lineLimitX
        s["limitDrawn"] = canvas.limitDrawnForTest as Any   // robot:needs var limitDrawnForTest
        s["lineRight"] = canvas.lineRightForTest as Any   // robot:needs var lineRightForTest
        s["limitAlpha"] = canvas.limitAlphaForTest   // robot:needs var limitAlphaForTest
        let wf = app.window.frame, cf = canvas.convert(canvas.bounds, to: nil)
        s["canvasFrame"] = [cf.minX, wf.height - cf.maxY, cf.width, cf.height, wf.width]   // window points, from the window's top-left
        s["aimMark"] = canvas.markForTest.map { [$0.x, $0.y] } as Any   // robot:needs var markForTest
        s["aimPad"] = canvas.aimPadForTest.map { [$0.x, $0.y] } as Any   // robot:needs var aimPadForTest
        s["clickDrawRange"] = app.settingsWindow.clickDrawRangeForTest   // robot:needs var clickDrawRangeForTest
        s["settingsSwitches"] = app.settingsWindow.switchesForTest.map { [$0.0, $0.1] as [Any] }   // robot:needs class SettingsWindow
        s["gallery"] = app.galleryShown ? (app.gallery?.selected ?? -1) : -2   // robot:needs var galleryShown
        s["galleryOrder"] = app.galleryShown ? (app.gallery?.order ?? []) : []   // robot:needs private(set) var order: [Int]
        s["canUndo"] = canvas.doc.canUndo   // robot:needs var canUndo
        s["pageMap"] = (app.container.pageMap.isHidden || app.container.pageMap.alphaValue < 0.05) ? [:] : ["w": app.container.pageMap.frame.width, "h": app.container.pageMap.frame.height, "alpha": app.container.pageMap.alphaValue]   // robot:needs class PageMapView
        return s
    }
}
#endif
