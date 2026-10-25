// Scrawl (formerly Trackpad Draw): finger drawing on the MacBook trackpad, Keep-style tools.
// ⌃⌥D enters draw mode (cursor frozen + hidden, trackpad maps to the visible page);
// Esc always exits. One finger draws, two fingers pan/pinch, palms are ignored.
import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--watchdog"), i + 1 < CommandLine.arguments.count, let pid = pid_t(CommandLine.arguments[i + 1]) {
    Watchdog.run(parent: pid)
}

final class ContainerView: NSView {
    let canvas: CanvasView
    let toolbar = ToolbarView(frame: .zero)
    let banner = PillLabel()
    let hint = PillLabel()
    let toast = PillLabel()
    let pageMap = PageMapView()
    let capsule = StatusCapsule()
    let drawFrame = DrawModeFrame(frame: .zero)

    init(frame: NSRect, canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: frame)
        // The page, toolbar and panels are drawn light in both modes; system controls (checkboxes, sliders)
        // must use light-mode colours too, or their labels turn white on the light panel in dark mode.
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.945, green: 0.953, blue: 0.957, alpha: 1).cgColor
        canvas.wantsLayer = true
        addSubview(canvas)
        addSubview(toolbar)
        addSubview(toolbar.panel)
        for l in [banner, hint] {
            l.font = .systemFont(ofSize: 12, weight: .medium)
            addSubview(l)
        }
        banner.textColor = .white
        banner.fillColor = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1)
        hint.textColor = NSColor(white: 0.45, alpha: 1)
        hint.fillColor = NSColor(white: 1, alpha: 0.85)
        hint.paddingX = 12
        toast.identifier = NSUserInterfaceItemIdentifier("toast")
        toast.font = .systemFont(ofSize: 13, weight: .semibold); toast.textColor = .white
        toast.fillColor = NSColor(white: 0.15, alpha: 0.85)
        toast.isHidden = true
        addSubview(toast)
        pageMap.canvas = canvas
        pageMap.isHidden = true
        addSubview(pageMap)
        capsule.isHidden = true; addSubview(capsule)
        drawFrame.isHidden = true; addSubview(drawFrame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The writing area is the whole window (or the whole screen in full screen): the trackpad maps onto
        // exactly this rectangle, so there are no margins. The toolbar and labels float on top; the toolbar
        // hides in draw mode (keys work there; the pointer is frozen so it couldn't be clicked anyway).
        canvas.frame = bounds
        pageMap.isHidden = !pageMap.wanted
        if !pageMap.isHidden {
            let h = pageMap.preferredHeight
            pageMap.frame = CGRect(x: bounds.width - PageMapView.width - 12, y: bounds.height - h - 12, width: PageMapView.width, height: h)
            pageMap.refresh()
        }
        toolbar.frame = CGRect(x: 0, y: 6, width: bounds.width, height: ToolbarView.height)
        toolbar.isHidden = canvas.drawMode
        if canvas.drawMode { toolbar.hidePanel() }
        banner.frame = CGRect(x: bounds.midX - banner.fittingWidth / 2, y: bounds.height - 28, width: banner.fittingWidth, height: 20)
        capsule.isHidden = !canvas.drawMode; drawFrame.isHidden = !canvas.drawMode
        capsule.frame = CGRect(x: bounds.midX - capsule.fittingWidth / 2, y: 14, width: capsule.fittingWidth, height: 26)
        drawFrame.frame = bounds
        hint.frame = CGRect(x: bounds.midX - hint.fittingWidth / 2, y: bounds.height - 27, width: hint.fittingWidth, height: 18)
        canvas.setNeedsRender()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let padAspect = CanvasView.pageUnits.width / CanvasView.pageUnits.height
    /// First run under this bundle ID (the migration never copies "welcomed").
    static func shouldWelcome(_ d: UserDefaults) -> Bool { !d.bool(forKey: "welcomed") }
    var window: NSWindow!
    var container: ContainerView!
    var canvas: CanvasView { container.canvas }
    var keyMonitor: Any?
    var mtError: String?
    var notebookStatus = ""
    var previousCrash = false
    var toastFade: DispatchWorkItem?
    var gallery: GalleryView?
    var galleryReturnsToDraw = false
    var transitionView: NSView?
    var lastTransition: [String: Any] = [:]
    private var lastBannerText = ""
    private var bannerFade: DispatchWorkItem?
    var migrationNotes: [String] = []
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
        if AppPaths.override == nil && !Launch.testing { migrationNotes = Migration.run() }
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")   // our View menu has it
        AppPaths.ensure()
        previousCrash = CrashNote.checkAndMark()
        Watchdog.spawn()
        Signals.install { [weak self] in self?.exitDrawMode("SIGTERM/SIGINT/SIGHUP"); NSApp.terminate(nil) }

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var size = CGSize(width: min(1400, screen.width * 0.85), height: 0)
        size.height = size.width / Self.padAspect
        if size.height > screen.height * 0.85 { size.height = screen.height * 0.85; size.width = size.height * Self.padAspect }
        window = NSWindow(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppInfo.name
        window.minSize = CGSize(width: 360, height: 300)
        // Any window shape (e.g. tall beside another app) and full screen (green button, ⌃⌘F): the trackpad
        // maps without distortion to the largest pad-shaped rectangle in the window (CanvasView.padRect).
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        let cv = CanvasView(frame: .zero, device: nil)
        container = ContainerView(frame: window.contentView!.bounds, canvas: cv)
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        if !Launch.background { window.makeKeyAndOrderFront(nil) }

        let tb = container.toolbar
        tb.state = cv.tools
        noteTool(cv.tools.tool)
        tb.onChange = { [weak self] s in   // a panel pick: a size, colour, background or writing setting
            guard let self else { return }
            self.canvas.changing("toolbar") { self.canvas.tools = s }; self.updateBanner()
        }
        tb.onMode = { [weak self] i in self?.apply(i, from: "toolbar") }
        tb.onUndo = { [weak self] in self?.canvas.undo() }
        tb.onRedo = { [weak self] in self?.canvas.redo() }
        tb.onPage = { [weak self] d in self?.page(d) }
        tb.onGallery = { [weak self] in self?.toggleGallery() }
        cv.onStatus = { [weak self] in self?.updateBanner() }
        cv.onDocChanged = { [weak self] in self?.updateUndoState(); self?.container.pageMap.refresh() }
        cv.onViewChange = { [weak self] in
            guard let self else { return }
            let m = self.container.pageMap
            if m.isHidden == m.wanted { self.container.needsLayout = true }
            if !m.isHidden { m.needsDisplay = true }
        }
        cv.onTouching = { [weak self] down in
            guard let m = self?.container.pageMap, !m.isHidden else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; m.animator().alphaValue = down ? 0.35 : 1 }
            if !down { m.refresh() }
        }
        cv.onTapCommand = { [weak self] text in self?.updateUndoState(); self?.showToast(text) }

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
        HotKey.action = { [weak self] in self?.apply(.draw, from: "hotkey") }
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
        if !canvas.testMode && Self.shouldWelcome(.standard) { showInfo(firstRun: true) }
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
            CursorLock.lock(at: CursorLock.parkPoint(canvasOnScreen: r, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? r.maxY))
        }
        canvas.drawMode = true
        if let t = canvas.resumeTarget() { canvas.act("resume"); canvas.animateCamera(to: t, src: "resume") }   // back to where you last wrote
        container.toolbar.drawMode = true
        container.toolbar.isHidden = true; container.toolbar.hidePanel()   // at once, not at the next layout
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
        canvas.noteDrawExit()
        container.toolbar.drawMode = false
        container.toolbar.isHidden = false   // at once: a click right after Esc must reach it
        updateBanner()
        if stallNoticePending { stallNoticePending = false; showInfo(firstRun: false) }
    }

    /// Prev is dimmed on the first page, Next on the last (it never creates a page; the + button and N do).
    func updateUndoState() { container.toolbar.canUndo = canvas.doc.canUndo; container.toolbar.canRedo = canvas.doc.canRedo }

    /// A short message in the middle of the top edge ("Undo", "Redo"), fading out.
    func showToast(_ text: String) {
        let t = container.toast
        t.stringValue = text
        t.frame = CGRect(x: container.bounds.midX - t.fittingWidth / 2, y: container.bounds.height - 64, width: t.fittingWidth, height: 24)
        toastFade?.cancel(); t.alphaValue = 1; t.isHidden = false
        let w = DispatchWorkItem { [weak t] in NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; t?.animator().alphaValue = 0 }, completionHandler: { t?.isHidden = true }) }
        toastFade = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    func updatePageArrows() {
        updateUndoState()
        container.toolbar.canGoBack = canvas.pageIndex > 0
        container.toolbar.canGoForward = canvas.pageIndex < canvas.pages.count - 1
    }

    /// -1 previous, +1 next, 0 new page.
    func page(_ d: Int) {
        if d == -1 && !container.toolbar.canGoBack || d == 1 && !container.toolbar.canGoForward { return }
        if d == 0 { canvas.newPage() } else { canvas.goToPage(canvas.pageIndex + d) }
        updateBanner()
    }

    func toggleWriting() {
        canvas.writingMode.toggle()
        container.toolbar.writingMode = canvas.writingMode
        updateBanner()
    }

    func updateBanner() {
        updatePageArrows()
        let input = canvas.usingMT ? "" : "  ·  basic touch input (no pressure)"
        let pageText = "Page \(canvas.pageIndex + 1) of \(canvas.pages.count)"
        if canvas.showPageHint {
            container.banner.stringValue = "\(pageText): you've filled a screen. N = new page, or K to keep writing here."
            container.banner.fillColor = NSColor(srgbRed: 0.85, green: 0.45, blue: 0.05, alpha: 1)
        } else {
            // Short, and only for 2 s on entry or a mode change; the capsule at the bottom keeps the state.
            container.banner.stringValue = canvas.writingMode ? "Writing · W off · Esc to stop" : "Drawing · Esc to stop"
            container.banner.fillColor = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1)
        }
        let wasHidden = container.banner.isHidden
        container.banner.isHidden = !canvas.drawMode && !canvas.showPageHint
        // In draw mode the banner sits on the writing area: show it when it appears or changes, then fade
        // it out (the page-full hint stays until answered). It used to fade only when its text changed, so
        // entering draw mode with the same text as before left it on screen for the whole session.
        if container.banner.stringValue != lastBannerText || container.banner.isHidden || wasHidden {
            lastBannerText = container.banner.stringValue
            bannerFade?.cancel(); container.banner.alphaValue = 1
            if canvas.drawMode && !canvas.showPageHint {
                let w = DispatchWorkItem { [weak self] in
                    NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.container.banner.animator().alphaValue = 0 }
                }
                bannerFade = w; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
            }
        }
        container.hint.stringValue = previousCrash && notebookStatus.hasPrefix("loaded")
            ? "\(AppInfo.name) closed unexpectedly last time. Your pages were restored from the last autosave."
            : "\(pageText)  ·  created \(PageDate.short(canvas.doc.created))  ·  ⌃⌥D to draw with the trackpad\(input)"
        container.hint.isHidden = !container.banner.isHidden
        let t = canvas.tools
        container.capsule.info = StatusCapsule.Info(tool: t.tool, color: t.tool == .eraser ? .gray : ToolState.colors[t.colorIndex[t.tool] ?? 0],
                                                    writing: canvas.writingMode, locked: t.zoomLocked, page: canvas.pageIndex + 1, pages: canvas.pages.count)
        container.needsLayout = true
    }

    /// Returns true if the key was handled.
    func key(_ e: NSEvent) -> Bool {
        // Keys meant for a text field (a save panel's file name, any other window) are not shortcuts.
        if e.window !== window || window.firstResponder is NSText { return false }
        let arrow: (Int, Int)? = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)][e.keyCode]
        let plainOrShift = e.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if galleryShown, let a = arrow, plainOrShift { gallery?.moveSelection(dx: a.0, dy: a.1); return true }
        if galleryShown, e.keyCode == 36 || e.keyCode == 76 || e.keyCode == 49 { openSelectedTile(); return true }   // Return, Enter, Space
        if !galleryShown, let a = arrow, plainOrShift {
            canvas.panByArrow(dx: a.0, dy: a.1, screen: e.modifierFlags.contains(.shift)); return true
        }
        if galleryShown {   // the page overview: G or Esc goes back to the current page; other keys do nothing
            // G (like Return / Space) opens the highlighted tile; Esc goes back to the page that was open.
            if e.keyCode == 53 { TransitionTiming.inputAt = CACurrentMediaTime(); openPage(canvas.pageIndex) }
            else if e.charactersIgnoringModifiers?.lowercased() == "g" { TransitionTiming.inputAt = CACurrentMediaTime(); openSelectedTile() }
            return e.modifierFlags.intersection([.command, .control, .option]).isEmpty
        }
        if e.keyCode == 36 || e.keyCode == 76, canvas.writingMode { canvas.newLineByHand(); return true }   // Return: next line
        if e.keyCode == 53 { if canvas.drawMode { exitDrawMode(); return true }; container.toolbar.hidePanel(); return true }  // Esc
        // Single-letter shortcuts work in and out of draw mode. D, W, L/Z and the tool keys go through the
        // same rules as the toolbar and the menu (see Modes.swift).
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let modeKeys: [String: ModeInput] = ["d": .draw, "w": .writing, "l": .zoomLock, "z": .zoomLock,
                                             "p": .tool(.pen), "m": .tool(.marker), "h": .tool(.highlighter), "e": .tool(.eraser)]
        if let i = modeKeys[ch] { apply(i, from: "key"); return true }
        var s = canvas.tools
        switch ch {
        case "g": TransitionTiming.inputAt = CACurrentMediaTime(); toggleGallery(); return true
        case "n": page(0); return true
        case "k" where canvas.showPageHint: canvas.dismissPageHint(); return true
        case "1", "2", "3", "4", "5": s.sizeIndex[s.tool] = Int(ch)! - 1
        default: return false
        }
        canvas.changing("key") { canvas.tools = s }
        container.toolbar.state = s
        updateBanner()
        return true
    }

    var modeState: ModeState { ModeState(draw: canvas.drawMode, writing: canvas.writingMode, locked: canvas.tools.zoomLocked, tool: canvas.tools.tool) }

    /// A mode or tool input from a key, the toolbar or the menu (the rules are in Modes.swift). In draw mode,
    /// where the toolbar is hidden, a short note says what changed.
    func apply(_ input: ModeInput, from source: String) {
        let old = modeState, new = old.after(input, lastOther: lastOtherTool)
        if new.tool != old.tool || new.locked != old.locked {
            var t = canvas.tools; t.tool = new.tool; t.zoomLocked = new.locked
            noteTool(t.tool)
            canvas.changing(source) { canvas.tools = t }
            container.toolbar.state = t
        }
        if new.writing != old.writing { toggleWriting() }
        if new.draw != old.draw { if new.draw { enterDrawMode(lock: !canvas.testMode) } else { exitDrawMode(source) } }   // tests never freeze the pointer
        container.toolbar.hidePanel()
        updateBanner()
        if canvas.drawMode, let note = new.change(from: old) { showToast(note) }
    }

    /// The last tool other than the pen (marker, highlighter or eraser), for P on the pen.
    private(set) var lastOtherTool: ToolKind?
    var robot: AnyObject?   // the robot user's hook (Robot.swift, dev builds only)
    func noteTool(_ t: ToolKind) { if t != .pen { lastOtherTool = t } }

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
        #if !RELEASE
        if let i = a.firstIndex(of: "--test-robot"), i + 1 < a.count { let r = Robot(app: self, dir: a[i + 1]); robot = r; r.start() }   // robot/robot.py
        #endif
        if a.contains("--test-pan") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestPan.run(app: self) } }
        if a.contains("--test-modes") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestModes.run(app: self) } }
        if a.contains("--test-jitter") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestJitter.run(app: self) } }
        if a.contains("--test-gallerykeys") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGalleryKeys.run(app: self) } }
        if a.contains("--test-toast") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestToast.run(app: self) } }
        if a.contains("--test-arrowkeys") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestArrowKeys.run(app: self) } }
        if a.contains("--test-taps") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestTaps.run(app: self) } }
        if a.contains("--test-tooldraw") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestToolDraw.run(app: self) } }
        if a.contains("--test-gallery-speed") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGallerySpeed.run(app: self) } }
        if let i = a.firstIndex(of: "--test-meta"), i + 1 < a.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestMeta.run(a[i + 1], app: self) } }
        if let i = a.firstIndex(of: "--test-arrows"), i + 1 < a.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestArrows.run(a[i + 1], app: self) } }
        if let i = a.firstIndex(of: "--test-gallery"), i + 1 < a.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGallery.run(a[i + 1], app: self) } }
        if a.contains("--test-page") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestPage.run(app: self) } }
        if a.contains("--test-newline") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestNewLine.run(app: self) } }
        if a.contains("--test-keys") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestKeys.run(app: self) } }
        if a.contains("--test-edge") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestEdge.run(app: self) } }
        if a.contains("--test-mapping") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestMapping.run(app: self) } }
        if a.contains("--test-about") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestAbout.run(app: self) } }
        if let i = a.firstIndex(of: "--test-input"), i + 1 < a.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestInput.run(a[i + 1], app: self) }
        }
        if let i = a.firstIndex(of: "--test-persist"), i + 1 < a.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestPersist.run(a[i + 1], canvas: canvas, app: self) }
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
    @objc func toggleDrawModeAction() { apply(.draw, from: "menu") }
    @objc func toggleZoomLockAction() { apply(.zoomLock, from: "menu") }
    @objc func togglePageMapAction() {
        PageMapView.enabled.toggle()
        if !canvas.testMode { UserDefaults.standard.set(PageMapView.enabled, forKey: "pageMap") }
        container.needsLayout = true
    }
    @objc func penAction() { apply(.tool(.pen), from: "menu") }
    @objc func markerAction() { apply(.tool(.marker), from: "menu") }
    @objc func highlighterAction() { apply(.tool(.highlighter), from: "menu") }
    @objc func eraserAction() { apply(.tool(.eraser), from: "menu") }
    @objc func exportPNG() { export("png") { try self.canvas.exportPNG(to: $0) } }
    @objc func exportPDF() { export("pdf") { try self.canvas.exportPDF(to: $0) } }
    private func export(_ ext: String, _ write: @escaping (URL) throws -> Void) {
        exitDrawMode("export")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ext == "pdf" ? .pdf : .png]
        panel.nameFieldStringValue = ext == "pdf" ? "\(AppInfo.name) \(f.string(from: Date())).pdf" : "Page \(canvas.pageIndex + 1) \(f.string(from: Date())).png"
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
