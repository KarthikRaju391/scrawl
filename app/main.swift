// Trackpad Draw: finger drawing on the MacBook trackpad, Keep-style tools.
// ⌃⌥D enters draw mode (cursor frozen + hidden, trackpad maps to the visible page);
// Esc always exits. One finger draws, two fingers pan/pinch, palms are ignored.
import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--watchdog"), i + 1 < CommandLine.arguments.count, let pid = pid_t(CommandLine.arguments[i + 1]) {
    Watchdog.run(parent: pid)
}

final class ContainerView: NSView {
    let canvas: CanvasView
    let toolbar = ToolbarView(frame: .zero)
    let banner = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")

    init(frame: NSRect, canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.945, green: 0.953, blue: 0.957, alpha: 1).cgColor
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 6
        canvas.layer?.masksToBounds = true
        addSubview(canvas)
        addSubview(toolbar)
        addSubview(toolbar.panel)
        for l in [banner, hint] {
            l.alignment = .center
            l.font = .systemFont(ofSize: 12, weight: .medium)
            addSubview(l)
        }
        banner.textColor = .white
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1).cgColor
        banner.layer?.cornerRadius = 10
        hint.textColor = NSColor(white: 0.45, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top: CGFloat = 30, bottom = ToolbarView.height + 8
        let avail = CGRect(x: 16, y: bottom, width: bounds.width - 32, height: bounds.height - bottom - top)
        let aspect = CanvasView.pageUnits.width / CanvasView.pageUnits.height
        var w = avail.width, h = w / aspect
        if h > avail.height { h = avail.height; w = h * aspect }
        canvas.frame = CGRect(x: avail.midX - w / 2, y: avail.minY + (avail.height - h) / 2, width: w, height: h).integral
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ToolbarView.height)
        banner.sizeToFit()
        banner.frame = CGRect(x: bounds.midX - (banner.frame.width + 28) / 2, y: bounds.height - top + 5, width: banner.frame.width + 28, height: 20)
        hint.frame = CGRect(x: 0, y: bounds.height - top + 7, width: bounds.width, height: 16)
        canvas.setNeedsRender()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var container: ContainerView!
    var canvas: CanvasView { container.canvas }
    var keyMonitor: Any?
    var mtError: String?
    var notebookStatus = ""
    var previousCrash = false
    var infoWindow: InfoWindow?
    var inputStatus: InputStatus { InputStatus(mtError: mtError, stalled: canvas.inputStalled, summary: Multitouch.summary) }

    /// Welcome (first run) or Help. Never shown by tests (they'd take focus); --test-welcome reads it instead.
    func showInfo(firstRun: Bool) {
        let w = InfoWindow(status: inputStatus, firstRun: firstRun)
        w.onClose = { [weak self] in self?.infoWindow = nil }
        infoWindow = w
        if firstRun { UserDefaults.standard.set(true, forKey: "welcomed") }
        guard !Launch.background else { return }
        w.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showHelp() { exitDrawMode("help"); showInfo(firstRun: false) }

    /// MultitouchSupport went quiet while a finger was down: drawing already switched to NSTouch and
    /// carries on; the explanation waits until the user leaves draw mode (no window mid-stroke).
    var stallNoticePending = false
    func inputStalled() {
        stallNoticePending = true
        updateBanner()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        AppPaths.ensure()
        previousCrash = CrashNote.checkAndMark()
        Watchdog.spawn()
        Signals.install { [weak self] in self?.exitDrawMode("SIGTERM/SIGINT/SIGHUP"); NSApp.terminate(nil) }

        let screen = NSScreen.main!.visibleFrame
        let size = CGSize(width: min(1400, screen.width * 0.85), height: min(940, screen.height * 0.85))
        window = NSWindow(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Trackpad Draw"
        window.minSize = CGSize(width: 640, height: 480)
        window.delegate = self
        let cv = CanvasView(frame: .zero, device: nil)
        container = ContainerView(frame: window.contentView!.bounds, canvas: cv)
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        if !Launch.background { window.makeKeyAndOrderFront(nil) }

        let tb = container.toolbar
        tb.state = cv.tools
        tb.onChange = { [weak self] s in self?.canvas.changing("toolbar") { self?.canvas.tools = s }; self?.updateBanner() }
        tb.onUndo = { [weak self] in self?.canvas.undo() }
        tb.onRedo = { [weak self] in self?.canvas.redo() }
        tb.onDrawMode = { [weak self] in self?.toggleDrawMode() }
        tb.onWriting = { [weak self] in self?.toggleWriting() }
        tb.onPage = { [weak self] d in self?.page(d) }
        cv.onStatus = { [weak self] in self?.updateBanner() }

        // Input: MultitouchSupport (pressure) unless turned off (Help menu, or --input-nstouch), else the
        // public NSTouch path. Tests never start MT: real touches would interleave with the test input.
        let source = Launch.args.contains("--input-nstouch") ? "nstouch" : Settings().inputSource
        if source != "mt" { mtError = "turned off (basic touch input chosen)" }
        else if canvas.testMode { mtError = nil }
        else { mtError = Multitouch.start() }
        cv.usingMT = mtError == nil
        cv.onInputStalled = { [weak self] in self?.inputStalled() }
        let queue = cv.input
        Multitouch.onFrame = { [weak cv] contacts, arrival, sensorT in
            // Drained on each display tick; if ticks stall, a fallback drains after 50 ms.
            if queue.push(contacts, arrival: arrival, sensorT: sensorT) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { cv?.drainIfStale() }
            }
        }
        HotKey.action = { [weak self] in self?.toggleDrawMode() }
        if !canvas.testMode { HotKey.register() }   // tests never take ⌃⌥D from the app in use
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) == true ? nil : e }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.exitDrawMode("app deactivated"); self?.canvas.autosaver.saveNow(sync: false)
        }
        // The cursor comes back whenever the Mac stops being in front of the user, or the displays change
        // (the frozen cursor's parking spot and the page mapping are no longer valid).
        let ws = NSWorkspace.shared.notificationCenter
        for (name, why) in [(NSWorkspace.screensDidSleepNotification, "display sleep"), (NSWorkspace.willSleepNotification, "system sleep"),
                            (NSWorkspace.sessionDidResignActiveNotification, "user switched / screen locked")] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.exitDrawMode(why); self?.canvas.autosaver.saveNow(sync: false) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.exitDrawMode("displays changed")
        }
        buildMenu()
        notebookStatus = canvas.loadNotebookFromDisk()
        updateBanner()
        startTestReplayIfAsked()
        if !canvas.testMode && !UserDefaults.standard.bool(forKey: "welcomed") { showInfo(firstRun: true) }
        if UserDefaults.standard.string(forKey: "rejoinMode") == "ab" {   // record the hidden condition
            canvas.logger.event(["what": "abCondition", "rejoin": Settings.abCondition])
        }
        // --no-activate: open in the background (used by the smoke test so it doesn't take focus).
        if !Launch.background { NSApp.activate(ignoringOtherApps: true) } else { window.orderBack(nil) }
    }

    // MARK: draw mode

    /// --test-cursor <how>: lock the cursor (dry run only), then end draw mode the way `how` says.
    /// checks/cursor.sh reads the watchdog log to see the cursor came back.
    func testCursor(_ how: String) {
        let dir = AppPaths.logsDir
        func status(_ name: String) {
            let r: [String: Any] = ["drawMode": canvas.drawMode, "locked": CursorLock.locked]
            try? JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        guard CursorLock.dry else { status("refused-not-dry.json"); return }   // never lock the real cursor in a test
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            enterDrawMode(lock: true)
            status("locked.json")
            switch how {
            case "crash": TestCrash.now()
            case "quit": NSApp.terminate(nil)
            case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            case "systemsleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            case "session": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            case "screens": NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            case "esc":
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    _ = key(e)
                }
            default: return   // kill / term: the script signals us
            }
            status("after.json")
        }
    }

    func toggleDrawMode() { canvas.drawMode ? exitDrawMode() : enterDrawMode() }

    func enterDrawMode(lock: Bool = true) {
        guard !canvas.drawMode else { return }
        container.toolbar.hidePanel()
        if lock {
            if !Launch.background {   // dry-run lock tests stay in the background
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            // Park the frozen cursor in the middle of the canvas so stray clicks land on it.
            let r = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
            let primaryH = NSScreen.screens.first!.frame.height
            CursorLock.lock(at: CGPoint(x: r.midX, y: primaryH - r.midY))
        }
        canvas.drawMode = true
        container.toolbar.drawMode = true
        updateBanner()
    }

    func exitDrawMode(_ reason: String = "Esc / hotkey / toolbar") {
        let wasLocked = CursorLock.locked
        CursorLock.unlock(reason: reason)  // unconditional: also covers a lock without draw mode
        guard canvas.drawMode else { return }
        if CommandLine.arguments.contains("--test-replay") {  // test mode: record how draw mode ended
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            let r: [String: Any] = ["wasLocked": wasLocked, "lockedAfter": CursorLock.locked, "t": Date().timeIntervalSince1970]
            try? JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: dir + "/test-exit.json"))
        }
        canvas.drawMode = false
        container.toolbar.drawMode = false
        updateBanner()
        if stallNoticePending { stallNoticePending = false; showInfo(firstRun: false) }
    }

    /// -1 previous, +1 next, 0 new page.
    func page(_ d: Int) {
        if d == 0 { canvas.newPage() } else { canvas.goToPage(canvas.pageIndex + d) }
        updateBanner()
    }

    func toggleWriting() {
        canvas.writingMode.toggle()
        container.toolbar.writingMode = canvas.writingMode
        updateBanner()
    }

    func updateBanner() {
        let input = canvas.usingMT ? "" : "  ·  basic touch input (no pressure)"
        let pageText = "Page \(canvas.pageIndex + 1) of \(canvas.pages.count)"
        if canvas.showPageHint {
            container.banner.stringValue = "\(pageText): you've filled a screen. N = new page, or K to keep writing here."
            container.banner.layer?.backgroundColor = NSColor(srgbRed: 0.85, green: 0.45, blue: 0.05, alpha: 1).cgColor
        } else {
            container.banner.stringValue = canvas.writingMode
                ? "\(pageText) · Writing: pans at the right edge, next line at the line width\(canvas.tools.zoomLocked ? " · zoom locked" : ""). W = off, Esc exits."
                : "\(pageText) · Drawing: one finger draws, two fingers pan\(canvas.tools.zoomLocked ? " (zoom locked, L unlocks)" : " and pinch")\(canvas.aimActive ? " · aim first: touch lightly to aim, press to write" : ""). W = writing, Esc exits."
            container.banner.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1).cgColor
        }
        container.banner.isHidden = !canvas.drawMode && !canvas.showPageHint
        container.hint.stringValue = previousCrash && notebookStatus.hasPrefix("loaded")
            ? "\(AppInfo.name) closed unexpectedly last time. Your pages were restored from the last autosave."
            : "\(pageText)  ·  ⌃⌥D to draw with the trackpad\(input)"
        container.hint.isHidden = !container.banner.isHidden
        container.needsLayout = true
    }

    /// Returns true if the key was handled.
    func key(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { if canvas.drawMode { exitDrawMode(); return true }; container.toolbar.hidePanel(); return true }  // Esc
        // Single-letter shortcuts work in and out of draw mode. D enters draw mode.
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        var s = canvas.tools
        switch ch {
        case "d": if !canvas.drawMode { enterDrawMode(lock: !canvas.testMode) }; return true   // tests never freeze the cursor
        case "p": s.tool = .pen
        case "m": s.tool = .marker
        case "h": s.tool = .highlighter
        case "e": s.tool = .eraser
        case "w": toggleWriting(); return true
        case "n": page(0); return true
        case "l", "z": s.zoomLocked.toggle()   // L (or Z) locks / unlocks the zoom
        case "a": s.aimFirst.toggle()           // aim first: light touch aims, press to ink
        case "k" where canvas.showPageHint: canvas.dismissPageHint(); return true
        case "1", "2", "3", "4", "5": s.sizeIndex[s.tool] = Int(ch)! - 1
        default: return false
        }
        canvas.changing("key") { canvas.tools = s }
        container.toolbar.state = s
        updateBanner()
        return true
    }

    // MARK: test mode (see TestReplay.swift)

    func startTestReplayIfAsked() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--test-stress"), i + 1 < a.count {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            let n = a.firstIndex(of: "--count").flatMap { Int(a[$0 + 1]) } ?? 400
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                if !Launch.background { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
                enterDrawMode(lock: false)
                canvas.setZoomForTest(settingsWritingZoom: true)
                if !a.contains("--zoomed") { canvas.resetZoom() }
                TestStress.run(canvas: canvas, path: a[i + 1], count: n, dir: dir) {
                    try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        if let i = a.firstIndex(of: "--test-hand"), i + 1 < a.count {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                enterDrawMode(lock: false)
                var t = ToolState(); t.sizeIndex[.pen] = 1; canvas.tools = t
                TestHand.run(canvas: canvas, fontDir: a[i + 1], seed: UInt64(arg("--seed") ?? "1") ?? 1, sigma: Double(arg("--sigma") ?? "1.9") ?? 1.9, dir: dir) {
                    try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        if let i = a.firstIndex(of: "--test-session"), i + 1 < a.count {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                TestSession.run(canvas: canvas, path: a[i + 1]) { [self] in
                    canvas.recorder.flush()
                    try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        if let i = a.firstIndex(of: "--test-cursor"), i + 1 < a.count { testCursor(a[i + 1]) }
        if a.contains("--test-about") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestAbout.run(app: self) } }
        if let i = a.firstIndex(of: "--test-input"), i + 1 < a.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestInput.run(a[i + 1], app: self) }
        }
        if let i = a.firstIndex(of: "--test-persist"), i + 1 < a.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestPersist.run(a[i + 1], canvas: canvas, app: self) }
        }
        if a.contains("--test-aim") {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                enterDrawMode(lock: false); canvas.setZoomForTest(settingsWritingZoom: true); canvas.resetZoom()
                TestAim.run(canvas: canvas, dir: dir) { try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8) }
            }
        }
        if a.contains("--test-zoomlock") {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in runZoomLockTest(dir: dir) }
        }
        if let i = a.firstIndex(of: "--test-draw"), i + 1 < a.count {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                if !Launch.background { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
                enterDrawMode(lock: false)
                TestDraw.run(canvas: canvas, path: a[i + 1]) { [self] in
                    exitDrawMode()
                    try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/page.png"), pxPerUnit: 3)
                    try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        if a.contains("--test-scroll") {  // outside draw mode: two-finger scroll pans
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                canvas.setZoomForTest(settingsWritingZoom: true)
                let before = canvas.camera.center
                for (dx, dy) in [(Int32(0), Int32(-120)), (Int32(-200), Int32(0))] {  // scroll down, then right
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0),
                       let e = NSEvent(cgEvent: cg) {
                        canvas.scrollWheel(with: e)
                    }
                }
                let after = canvas.camera.center
                let r: [String: Any] = ["drawMode": canvas.drawMode, "before": [before.x, before.y], "after": [after.x, after.y]]
                try? JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: dir + "/test-scroll.json"))
                try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
            }
        }
        if a.contains("--test-autopan") {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                if !Launch.background { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
                enterDrawMode(lock: false)
                canvas.setZoomForTest(settingsWritingZoom: true)
                var t = canvas.tools; t.lineWidthIndex = 0   // ½ page
                if let i = a.firstIndex(of: "--autopan"), i + 1 < a.count { t.autoPan = ["off": .off, "left": .left][a[i + 1]] ?? .centre } else { t.autoPan = .centre }
                canvas.tools = t
                toggleWriting()
                TestAutoPan.run(canvas: canvas, dir: dir) { [self] in
                    try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/page.png"), pxPerUnit: 1.5)
                    try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        if a.contains("--test-ui") {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                if !Launch.background { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
                TestUI.run(window: window, toolbar: container.toolbar, dir: dir) { [self] in
                    // One wavy stroke through the real input path, without locking the cursor.
                    enterDrawMode(lock: false)
                    var frames: [[Contact]] = []
                    for k in 0...150 {
                        let x = 20 + Double(k) * 0.55, y = 38 + sin(Double(k) / 12) * 14
                        frames.append([Contact(id: 1, state: 4, norm: CGPoint(x: x / 124.8, y: y / 76.8), mm: CGPoint(x: x, y: y),
                                               pressure: 10 + Double(k) / 3, size: 0.5, major: 7.5)])
                    }
                    frames.append([])
                    for (j, f) in frames.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(j) * 0.008) {
                            Multitouch.onFrame?(f, CACurrentMediaTime(), Double(j) * 0.008)
                            // onFrame hops to main async: exit after the lift frame has been handled.
                            if j == frames.count - 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.exitDrawMode() } }
                        }
                    }
                }
            }
        }
        guard let i = a.firstIndex(of: "--test-replay"), i + 1 < a.count else { return }
        let lock = a.contains("--test-lock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            if a.contains("--test-front") { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            enterDrawMode(lock: lock)
            TestReplay.run(path: a[i + 1], onFrame: { cs, t, st in Multitouch.onFrame?(cs, t, st) }) { [self] n, wall, planned in
                canvas.flushInputForTest()
                let dir = (canvas.logger.path as NSString).deletingLastPathComponent
                let report: [String: Any] = ["frames": n, "strokes": canvas.doc.strokes.count, "zoom": canvas.camera.zoom,
                                             "presented": canvas.presentedCount, "rendered": canvas.renderCount, "locked": lock,
                                             "replayWallSec": wall, "replayPlannedSec": planned,
                                             "windowVisible": window.occlusionState.contains(.visible)]
                try? JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: dir + "/test-replay-done.json"))
            }
        }
    }

    // MARK: menu

    @objc func undo() { canvas.undo() }
    @objc func redoAction() { canvas.redo() }
    @objc func clearPage() { canvas.clearPage() }
    @objc func resetZoom() { canvas.resetZoom() }
    @objc func newPageAction() { page(0) }
    @objc func prevPageAction() { page(-1) }
    @objc func nextPageAction() { page(1) }
    @objc func toggleDrawModeAction() { toggleDrawMode() }
    @objc func exportPNG() { export("png") { try self.canvas.exportPNG(to: $0) } }
    @objc func exportPDF() { export("pdf") { try self.canvas.exportPDF(to: $0) } }
    private func export(_ ext: String, _ write: @escaping (URL) throws -> Void) {
        exitDrawMode("export")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ext == "pdf" ? .pdf : .png]
        panel.nameFieldStringValue = ext == "pdf" ? "Trackpad Draw \(f.string(from: Date())).pdf" : "Page \(canvas.pageIndex + 1) \(f.string(from: Date())).png"
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            do { try write(url) } catch { NSAlert(error: error).runModal() }
        }
    }

    func windowWillClose(_ n: Notification) { exitDrawMode("window closed"); NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) {
        exitDrawMode("quit"); canvas.autosaver.saveNow(sync: true); canvas.recorder.flush()
        CrashNote.clear()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
