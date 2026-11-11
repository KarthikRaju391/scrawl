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
    let practice = PracticeView()
    let pendingMove = PendingMoveView()
    let zoomBadge = PillLabel()
    let selectionBar = SelectionBar(frame: .zero)
    let backPill = BackToContentPill(frame: .zero)   // "Back to content" once the page's content is mostly out of view (BackToContent.swift)
    /// After each layout (the selection bar follows the selection).
    var onLayout: (() -> Void)?

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
        practice.isHidden = true; addSubview(practice)
        pendingMove.isHidden = true; addSubview(pendingMove)
        zoomBadge.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold); zoomBadge.textColor = .white
        zoomBadge.fillColor = NSColor(white: 0.15, alpha: 0.8); zoomBadge.isHidden = true; addSubview(zoomBadge)
        selectionBar.isHidden = true; addSubview(selectionBar, positioned: .below, relativeTo: toast)
        backPill.isHidden = true; addSubview(backPill, positioned: .below, relativeTo: toast)
        registerForDraggedTypes([.fileURL] + ImagePages.pasteboardTypes)
    }
    /// Pictures dropped on the window (files, or images from another app): true if they were taken.
    var onDropImages: ((NSPasteboard, CGPoint) -> Bool)?
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { ImagePages.pasteboardHasImage(s.draggingPasteboard) && onDropImages != nil ? .copy : [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { draggingEntered(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { onDropImages?(s.draggingPasteboard, convert(s.draggingLocation, from: nil)) ?? false }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The writing area is the whole window (or the whole screen in full screen): the trackpad maps onto
        // exactly this rectangle, so there are no margins. The toolbar and labels float on top; the toolbar
        // hides in draw mode (keys work there; the pointer is frozen so it couldn't be clicked anyway).
        canvas.frame = bounds
        canvas.bottomInsetPt = canvas.drawMode ? 0 : 6 + ToolbarView.height + 8   // the toolbar's strip (hidden in draw mode)
        pageMap.isHidden = !pageMap.wanted
        if !pageMap.isHidden && pageMap.alphaValue < 0.05 { pageMap.alphaValue = 1 }
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
        let bw = zoomBadge.fittingWidth
        zoomBadge.frame = CGRect(x: bounds.width - max(bw, 56) - 12 - (PageMapView.width - max(bw, 56)) / 2, y: (pageMap.isHidden ? bounds.height - 12 : pageMap.frame.minY - 6) - 24,
                                 width: max(bw, 56), height: 24)
        let ps = practice.fittingSize
        // Below the page label at the top (it covered "Page 1 of 1 · created ..." in narrow windows).
        practice.frame = CGRect(x: 16, y: bounds.height - ps.height - 36, width: ps.width, height: ps.height)
        // Pan: at the right edge; next line: low on the left, where the line will start.
        pendingMove.frame = pendingMove.kind == .newLine ? CGRect(x: 14, y: bounds.height * 0.3, width: 40, height: 40)
                                                         : CGRect(x: bounds.width - 46, y: bounds.midY - 20, width: 40, height: 40)
        hint.frame = CGRect(x: bounds.midX - hint.fittingWidth / 2, y: bounds.height - 27, width: hint.fittingWidth, height: 18)
        // Back to content: bottom right, just above the toolbar (clear of its pill, its option panel and the toasts at the top).
        let bp = backPill.fittingSize_
        backPill.frame = CGRect(x: bounds.width - bp.width - 14, y: 6 + ToolbarView.height + 8, width: bp.width, height: bp.height)
        onLayout?()
        canvas.setNeedsRender()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    weak var viewMenu: NSMenu?
    weak var ownFullScreenItem: NSMenuItem?
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
    /// Counts notes shown: a fade-out only hides the note it started on.
    var toastShown = 0
    var gallery: GalleryView?
    var lastSharePicker: NSSharingServicePicker?
    /// The Export Page sheet while it's open (the test mode drives it).
    var exportPanel: NSSavePanel?
    var exportAccessory: ExportAccessory?
    /// Test runs: the folder the sheet opens in (set before it's shown; an out-of-process panel ignores later changes).
    var exportDirectoryForTest: String?
    var exportChosenForTest: [String] = []
    var galleryReturnsToDraw = false
    var transitionView: NSView?
    /// Ends the running gallery transition at once (its last frame and completion); nil when none runs.
    var transitionFinish: (() -> Void)?
    var lastTransition: [String: Any] = [:]
    private var lastBannerText = ""
    private var bannerFade: DispatchWorkItem?
    var migrationNotes: [String] = []
    var infoWindow: InfoWindow?
    var inputStatus: InputStatus { InputStatus(mtError: mtError, stalled: canvas.inputStalled, summary: Multitouch.summary) }

    /// Welcome (first run) or Help. Never shown by tests (they'd take focus); --test-welcome reads it instead.
    func showInfo(firstRun: Bool) {
        let w = makeInfoWindow(firstRun: firstRun)
        infoWindow = w
        if firstRun { UserDefaults.standard.set(true, forKey: "welcomed") }
        guard !Launch.background else { return }
        w.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func makeInfoWindow(firstRun: Bool) -> InfoWindow {
        let w = InfoWindow(status: inputStatus, firstRun: firstRun)
        w.onClose = { [weak self] in self?.infoWindow = nil }
        w.onPractice = { [weak self] in self?.startPractice() }
        if firstRun { w.onStart = { [weak self] in guard let self, !self.canvas.drawMode else { return }; self.apply(.draw, from: "welcome") } }
        return w
    }
    @objc func showHelp() { exitDrawMode("help"); showInfo(firstRun: false) }

    /// MultitouchSupport went quiet while a finger was down: drawing already switched to NSTouch and
    /// carries on; the explanation waits until the user leaves draw mode (no window mid-stroke).
    var stallNoticePending = false
    func inputStalled() {
        usage.record("error", ["category": "input_stalled"])
        stallNoticePending = true
        updateBanner()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")   // our View menu has it
        if AppPaths.override == nil && !Launch.testing { migrationNotes = Migration.run() }
        AppPaths.ensure()
        previousCrash = CrashNote.checkAndMark()
        UpdateInstaller.confirmIfPending()   // after an in-app update: tell the waiting helper this version started
        UpdateLocation.discardLeftover()     // a staged copy left by a quit or crash on "ready"
        Watchdog.spawn()
        Signals.install { [weak self] in self?.exitDrawMode("SIGTERM/SIGINT/SIGHUP"); NSApp.terminate(nil) }

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var size = CGSize(width: min(1400, screen.width * 0.85), height: 0)
        size.height = size.width / Self.padAspect
        if size.height > screen.height * 0.85 { size.height = screen.height * 0.85; size.width = size.height * Self.padAspect }
        window = NSWindow(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppInfo.name
        // Narrow enough to sit beside another app, wide enough for the whole toolbar (below ~560 pt the Draw
        // button and the page buttons were cut off at the window's edges).
        window.minSize = CGSize(width: ToolbarView.minimumWindowWidth, height: 300)
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
        tb.onUndo = { [weak self] in
            guard let self, !self.undoPageOp() else { return }
            self.tips.undoByKeyOrToolbar(inDrawMode: self.canvas.drawMode); self.usage.record("undo", ["source": "toolbar"]); self.canvas.undo()
        }
        tb.onRedo = { [weak self] in self?.usage.record("redo", ["source": "toolbar"]); self?.canvas.redo() }
        tb.onPage = { [weak self] d in self?.page(d) }
        tb.onGallery = { [weak self] in self?.toggleGallery() }
        cv.onStatus = { [weak self] in self?.updateBanner() }
        cv.onBackgroundClick = { [weak self] in self?.container.toolbar.hidePanel() }
        cv.onDocChanged = { [weak self] in self?.updateUndoState(); self?.container.pageMap.refresh(); self?.warmThumbnailSoon() }
        cv.onViewChange = { [weak self] source in self?.container.pageMap.viewChanged(source: source); self?.zoomChanged(source: source); self?.updateSelectionBar(); self?.updateBackToContent() }
        container.backPill.onClick = { [weak self] in self?.backToContentAction() }
        cv.onSelectionChange = { [weak self] _ in self?.selectionChanged() }
        container.onLayout = { [weak self] in self?.updateSelectionBar() }
        container.selectionBar.onCopy = { [weak self] in self?.copySelectionAction() }
        container.selectionBar.onExport = { [weak self] in self?.exportSelectionAction() }
        tb.onZoomMenu = { [weak self] view, r in self?.zoomMenu().popUp(positioning: nil, at: CGPoint(x: r.minX, y: r.maxY + 4), in: view) }
        cv.onTouching = { [weak self] down in if !down { self?.container.pageMap.refresh() } }
        cv.onTapCommand = { [weak self] text in self?.updateUndoState(); self?.showToast(text) }
        // The chevron shows the waiting writing-mode move itself, so the two can't disagree (0.1.6: ⌘Z left it on screen with
        // no move coming; Esc hid it and the page moved anyway).
        cv.onPendingMove = { [weak self] m in
            guard let v = self?.container.pendingMove else { return }
            if let m { v.show(m.kind == "newLine" ? .newLine : .pan) } else { v.hide() }
        }
        tips.show = { [weak self] text in self?.showToast(text, seconds: 4) }
        tips.onShown = { t in Analytics.shared.record("tip_shown", ["tip": t.rawValue]) }
        cv.onAct = { [weak self] name, extra in self?.canvasAct(name, extra) }
        container.onDropImages = { [weak self] pb, p in self?.dropImages(pb, at: p) ?? false }

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
            self?.settingsResumeDraw = false   // you went elsewhere: closing Settings later doesn't start drawing
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
        // Any other window of ours in front (Settings, Help, About, a save panel) can't be used with the pointer
        // frozen: draw mode ends.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, w !== self.window, self.canvas.drawMode else { return }
            self.exitDrawMode("another window")
        }
        canvas.autosaver.extraImageKeys = { [weak self] in Set(self?.pageOps.flatMap(\.imageKeys) ?? []) }
        notebookStatus = canvas.loadNotebookFromDisk()
        prepareImages()
        startInbox()
        warmThumbnails()   // every page's thumbnail, in the background, so the overview opens complete
        updateBanner()
        startTestReplayIfAsked()
        let firstRun = !canvas.testMode && Self.shouldWelcome(.standard)
        if firstRun { showInfo(firstRun: true) }
        usageLaunch()
        if !canvas.testMode { showUsageNoticeIfNeeded(firstRun: firstRun) }
        if UserDefaults.standard.string(forKey: "rejoinMode") == "ab" {   // record the hidden condition
            canvas.logger.event(["what": "abCondition", "rejoin": Settings.abCondition])
        }
        // --no-activate: open in the background (used by the smoke test so it doesn't take focus).
        // --offscreen (checks/stability.sh): the window is never put on screen, not even behind other windows.
        if !Launch.background { NSApp.activate(ignoringOtherApps: true) } else if !Launch.offscreen { window.orderBack(nil) }
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
        // Never behind the pages overview (0.1.6: ⌃⌥D or closing Settings there froze the pointer while fingers inked a page
        // you couldn't see). The overview closes first, with its usual transition into the open page, and draw mode starts
        // as that ends (galleryReturnsToDraw), the same way as leaving the overview you opened from draw mode.
        if transitionView != nil { finishTransitionNow(); guard !canvas.drawMode else { return } }
        if galleryShown { galleryReturnsToDraw = true; openPage(canvas.pageIndex); return }
        container.toolbar.hidePanel()
        // Select is a pointer tool: any way into draw mode (D, ⌃⌥D, the overview, practice) draws with the pen.
        if canvas.tools.tool == .select { var t = canvas.tools; t.tool = .pen; canvas.changing("draw mode") { canvas.tools = t }; container.toolbar.state = t }
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
        container.capsule.isHidden = false; container.drawFrame.isHidden = false
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
        container.capsule.isHidden = true; container.drawFrame.isHidden = true
        updateBanner()
        if stallNoticePending { stallNoticePending = false; showInfo(firstRun: false) }
    }

    /// Prev is dimmed on the first page, Next on the last (it never creates a page; the + button and N do).
    func updateUndoState() { container.toolbar.canUndo = canvas.doc.canUndo; container.toolbar.canRedo = canvas.doc.canRedo }

    /// A short message in the middle of the top edge ("Undo", "Redo"), fading out.
    func showToast(_ text: String, seconds: Double = 0.9) {
        let t = container.toast
        // In front of everything, the pages overview too (added later, it covered "Page 3 deleted · ⌘Z to undo").
        if container.subviews.last !== t { container.addSubview(t, positioned: .above, relativeTo: nil) }
        t.stringValue = text
        t.frame = CGRect(x: container.bounds.midX - t.fittingWidth / 2, y: container.bounds.height - 64, width: t.fittingWidth, height: 24)
        // A note shown while the last one fades out: that fade must not hide the new one when it ends (it did, and
        // moving the note to the front above ends a running fade at once: "Practice done" vanished as it appeared).
        toastFade?.cancel(); toastShown += 1
        let shown = toastShown
        NSAnimationContext.runAnimationGroup { $0.duration = 0; t.animator().alphaValue = 1 }
        t.isHidden = false
        let w = DispatchWorkItem { [weak self, weak t] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; t?.animator().alphaValue = 0 },
                                                completionHandler: { if self?.toastShown == shown { t?.isHidden = true } })
        }
        toastFade = w; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func updatePageArrows() {
        updateUndoState()
        container.toolbar.canGoBack = canvas.pageIndex > 0
        container.toolbar.canGoForward = canvas.pageIndex < canvas.pages.count - 1
    }

    /// -1 previous, +1 next, 0 new page.
    func page(_ d: Int) {
        if d == -1 && !container.toolbar.canGoBack || d == 1 && !container.toolbar.canGoForward { return }
        if d == 0 { canvas.newPage() } else { canvas.goToPage(canvas.pageIndex + d); tips.pageByArrow() }
        updateBanner()
    }

    func toggleWriting() {
        canvas.writingMode.toggle()
        container.toolbar.writingMode = canvas.writingMode
        updateBanner()
    }

    /// The "Back to content" pill: shown outside draw mode (and the overview) once the page's content is mostly out of view.
    func updateBackToContent() {
        let p = container.backPill
        let want = !galleryShown && canvas.backToContentWanted(showing: !p.isHidden)
        guard want == p.isHidden else { return }
        p.isHidden = !want; container.needsLayout = true
        canvas.act("backToContentPill", ["shown": want])
    }

    func updateBanner() {
        updateBackToContent()
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
            : "\(pageText)  ·  created \(PageDate.short(canvas.doc.created))\(imageSourceNote)  ·  ⌃⌥D to draw with the trackpad\(input)"
        container.hint.isHidden = !container.banner.isHidden
        let t = canvas.tools
        container.capsule.info = StatusCapsule.Info(tool: t.tool, color: t.tool == .eraser ? .gray : ToolState.colors[t.colorIndex[t.tool] ?? 0],
                                                    writing: canvas.writingMode, locked: t.zoomLocked, page: canvas.pageIndex + 1, pages: canvas.pages.count,
                                                    zoom: CanvasView.zoomText(canvas.camera.zoom))
        container.toolbar.zoomText = CanvasView.zoomText(canvas.camera.zoom)
        container.needsLayout = true
    }

    /// Returns true if the key was handled.
    func key(_ e: NSEvent) -> Bool {
        // A press while the overview's transition runs: it ends now, and the press acts on where things really are.
        if transitionView != nil, !e.isARepeat { finishTransitionNow() }
        // Keys meant for a text field (a save panel's file name, the overview's search) are not shortcuts.
        // Esc in an empty search leaves the field, so the next Esc closes the overview.
        if galleryShown, e.keyCode == 53, let t = window.firstResponder as? NSText, t.string.isEmpty, let g = gallery { window.makeFirstResponder(g); return true }
        // Esc always leaves draw mode, whichever of the app's windows is in front.
        if e.keyCode == 53, canvas.drawMode, e.modifierFlags.intersection([.command, .control, .option]).isEmpty { exitDrawMode("Esc"); return true }
        if e.window !== window || window.firstResponder is NSText { return false }
        let arrow: (Int, Int)? = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)][e.keyCode]
        let plainOrShift = e.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if galleryShown, let a = arrow, plainOrShift { gallery?.moveSelection(dx: a.0, dy: a.1); return true }
        // A held key auto-repeats: the overview and the pages change once per press, not per repeat (Karthik, 30 Oct:
        // holding G flashed between the overview and the hovered page about 5 times a second).
        if galleryShown, e.keyCode == 36 || e.keyCode == 76 || e.keyCode == 49 { if !e.isARepeat { openSelectedTile() }; return true }   // Return, Enter, Space
        if galleryShown, e.keyCode == 51 || e.keyCode == 117, plainOrShift, let g = gallery, g.selected >= 0, g.selected < canvas.pages.count {   // Delete, ⌦
            deletePage(g.selected); return true
        }
        // A picture selected with the Select tool: ⌫ deletes it.
        if !galleryShown, e.keyCode == 51 || e.keyCode == 117, plainOrShift, canvas.selectedImage != nil { canvas.deleteSelectedImage(); updateUndoState(); return true }
        if !galleryShown, let a = arrow, plainOrShift {
            canvas.panByArrow(dx: a.0, dy: a.1, screen: e.modifierFlags.contains(.shift)); return true
        }
        // Every other single-key shortcut acts once per press, like G: a held D, W, L or tool key flipped its mode
        // ~25 times a second, a held N added a page per repeat, a held Return a line per repeat.
        if e.isARepeat, !galleryShown, plainOrShift { return true }
        if galleryShown {   // the page overview: G or Esc goes back to the current page; other keys do nothing
            // G (like Return / Space) opens the highlighted tile; Esc goes back to the page that was open.
            if e.isARepeat { }
            else if e.keyCode == 53 { TransitionTiming.inputAt = CACurrentMediaTime(); openPage(canvas.pageIndex) }
            else if e.charactersIgnoringModifiers?.lowercased() == "g" { TransitionTiming.inputAt = CACurrentMediaTime(); openSelectedTile() }
            return e.modifierFlags.intersection([.command, .control, .option]).isEmpty
        }
        if e.keyCode == 36 || e.keyCode == 76, canvas.writingMode { canvas.newLineByHand(); return true }   // Return: next line
        // Esc: clears the selection (Select is never on in draw mode, where Esc leaves draw mode above).
        if e.keyCode == 53 {
            if canvas.drawMode { exitDrawMode(); return true }
            if canvas.selectedImageId != nil { canvas.selectedImageId = nil; return true }
            if canvas.selection != nil { canvas.setSelection(nil, "esc"); return true }
            container.toolbar.hidePanel(); return true
        }
        // Single-letter shortcuts work in and out of draw mode. D, W, L/Z and the tool keys go through the
        // same rules as the toolbar and the menu (see Modes.swift).
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let modeKeys: [String: ModeInput] = ["d": .draw, "w": .writing, "l": .zoomLock, "z": .zoomLock,
                                             "p": .tool(.pen), "m": .tool(.marker), "h": .tool(.highlighter), "e": .tool(.eraser), "s": .tool(.select)]
        if let i = modeKeys[ch] { apply(i, from: "key"); return true }
        var s = canvas.tools
        switch ch {
        case "g": if !e.isARepeat { TransitionTiming.inputAt = CACurrentMediaTime(); toggleGallery() }; return true   // once per press
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
        let old = modeState, new = old.after(input, lastOther: lastOtherTool, drawBeforeSelect: drawBeforeSelect)
        if new.tool == .select && old.tool != .select { drawBeforeSelect = old.draw }
        if new.draw != old.draw { settingsResumeDraw = false }   // you chose draw mode yourself since Settings opened
        usageMode(old: old, new: new, source: source)
        if new.tool != old.tool || new.locked != old.locked {
            var t = canvas.tools; t.tool = new.tool; t.zoomLocked = new.locked
            noteTool(t.tool)
            canvas.changing(source) { canvas.tools = t }
            container.toolbar.state = t
        }
        if new.tool == .eraser && old.tool != .eraser { tips.pickedEraser() }
        if new.locked && !old.locked { tips.zoomLocked() }
        if new.writing != old.writing { toggleWriting() }
        if new.draw != old.draw { if new.draw { enterDrawMode(lock: !canvas.testMode) } else { exitDrawMode(source) } }   // tests never freeze the pointer
        container.toolbar.hidePanel()
        updateBanner()
        if canvas.drawMode, let note = new.change(from: old) { showToast(note) }
    }

    /// The last tool other than the pen (marker, highlighter or eraser), for P on the pen.
    private(set) var lastOtherTool: ToolKind?
    /// Whether draw mode was on when Select was picked: S again goes back to it.
    var drawBeforeSelect = false
    let tips = Tips()
    let usageState = UsageState()
    /// Pages deleted since the last ink change: ⌘Z puts them back, newest first.
    var pageOps: [PageOp] = []
    /// The browser extension's snapshots (Inbox.swift), and its items waiting for the save that includes their page.
    var inbox: Inbox?
    var inboxWaiting: [(id: String, doc: Document, through: Int)] = []
    var lastBadgeZoom = 1.0
    var warmsThumbnails = !Launch.testing
    var thumbWarm: DispatchWorkItem?
    /// Settings was opened from draw mode: closing it goes back to drawing. Only if nothing else happened since: it's dropped
    /// when you turn draw mode on or off yourself, open the overview, or switch to another app.
    var settingsResumeDraw = false
    /// The update sheet, while it's open (Updater.swift).
    var updatePanel: UpdatePanel?
    var badgeFade: DispatchWorkItem?
    weak var zoomField: NSTextField?
    var robot: AnyObject?   // the robot user's hook (Robot.swift, dev builds only)
    func noteTool(_ t: ToolKind) { if t != .pen && t != .select { lastOtherTool = t } }   // P toggles between drawing tools

    // MARK: test mode (see TestReplay.swift)

    func startTestReplayIfAsked() {
        let a = CommandLine.arguments
        #if !RELEASE
        if a.contains("--test-update") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestUpdate.run(app: self) } }
        if a.contains("--test-update-report") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in TestUpdate.report(app: self) } }
        #endif
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
        if a.contains("--test-galleryflow") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGalleryFlow.run(app: self) } }
        if a.contains("--test-selectbar") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestSelectBar.run(app: self) } }
        else if a.contains("--test-select") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestSelect.run(app: self) } }
        if a.contains("--test-export") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestExport.run(app: self) } }
        if a.contains("--test-menus") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestMenus.run(app: self) } }
        if a.contains("--test-a11y") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestAccessibility.run(app: self) } }
        if a.contains("--test-gallery-order") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGalleryOrder.run(app: self) } }
        if a.contains("--test-gallery-replay") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGalleryReplay.run(app: self) } }
        if a.contains("--test-toast") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestToast.run(app: self) } }
        if a.contains("--test-arrowkeys") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestArrowKeys.run(app: self) } }
        if a.contains("--test-taps") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestTaps.run(app: self) } }
        if a.contains("--test-tooldraw") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestToolDraw.run(app: self) } }
        if a.contains("--test-gallery-speed") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGallerySpeed.run(app: self) } }
        if let i = a.firstIndex(of: "--test-meta"), i + 1 < a.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestMeta.run(a[i + 1], app: self) } }
        if let i = a.firstIndex(of: "--test-arrows"), i + 1 < a.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestArrows.run(a[i + 1], app: self) } }
        if let i = a.firstIndex(of: "--test-gallery"), i + 1 < a.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in TestGallery.run(a[i + 1], app: self) } }
        // From a run-loop timer, not the main queue: the test waits (spinning the run loop) for imports that finish with
        // DispatchQueue.main.async, which can't run while a main-queue block is running.
        if let i = a.firstIndex(of: "--test-images"), i + 1 < a.count { Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [self] _ in TestImages.run(a[i + 1], app: self) } }
        if let i = a.firstIndex(of: "--test-stability-thumbs"), i + 1 < a.count { Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [self] _ in TestStabilityThumbs.run(app: self, phase: a[i + 1]) } }
        else if a.contains("--test-stability") { Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [self] _ in TestStability.run(app: self) } }   // 0.1.6.1 (checks/stability.sh)
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

    @objc func undo() {
        if undoPageOp() { return }
        tips.undoByKeyOrToolbar(inDrawMode: canvas.drawMode); usage.record("undo", ["source": "key"]); canvas.undo()
    }
    @objc func redoAction() { usage.record("redo", ["source": "key"]); canvas.redo() }
    @objc func clearPage() { canvas.clearPage() }
    @objc func resetZoom() { canvas.resetZoom() }
    @objc func backToContentAction() { canvas.backToContent(); usage.record("back_to_content") }
    @objc func newPageAction() { page(0) }
    @objc func prevPageAction() { page(-1) }
    @objc func nextPageAction() { page(1) }
    @objc func toggleDrawModeAction() { apply(.draw, from: "menu") }
    @objc func toggleZoomLockAction() { apply(.zoomLock, from: "menu") }
    lazy var settingsWindow: SettingsWindow = {
        let w = SettingsWindow(switches: [
            .init(title: "Scratch out: a quick zig-zag over a word erases it", key: "scratchOut", get: { ScratchOut.enabled }, set: { ScratchOut.enabled = $0 }),
            .init(title: "Page map when zoomed in", key: "pageMap", get: { PageMapView.enabled }, set: { PageMapView.enabled = $0 }),
            .init(title: "Tips (each shows at most twice)", key: "tipsEnabled", get: { Tips.enabled }, set: { Tips.enabled = $0 }),
            .init(title: "Start draw mode where I last wrote", key: "resumeLastPoint",
                  get: { CanvasView.resumeLastPoint }, set: { CanvasView.resumeLastPoint = $0 }),
            .init(title: "Click to draw: a touch aims, a click starts the ink", key: "clickToDraw",
                  get: { CanvasView.clickToDraw }, set: { CanvasView.clickToDraw = $0 }),
            .init(title: "Share anonymous usage counts (never your ink or text)", key: "analyticsEnabledSwitch", get: { Analytics.shared.enabled }, set: { Analytics.shared.enabled = $0 }),
        ])
        w.onChange = { [weak self] in self?.container.needsLayout = true }
        w.onClose = { [weak self] in
            guard let self, self.settingsResumeDraw else { return }
            self.settingsResumeDraw = false
            if !self.canvas.drawMode { self.enterDrawMode(lock: !self.canvas.testMode) }
        }
        w.onSwitch = { key in Analytics.shared.record("settings_changed", ["key": key]) }
        w.onClickDrawTimeout = { [weak self] v in self?.setClickDrawTimeout(v) }
        w.onPauseBeforeMove = { ms in
            let v = min(max((ms / 50).rounded() * 50, 200), 1000)
            Settings.pauseChosenMs = v
            if !Launch.testing { UserDefaults.standard.set(v, forKey: "pauseBeforeMoveMs") }
        }
        return w
    }()
    @objc func showSettings() {
        // Draw mode freezes and hides the pointer: Settings couldn't be clicked. It steps aside while Settings is
        // open and comes back when it closes.
        if canvas.drawMode { settingsResumeDraw = true; exitDrawMode("settings") }
        settingsWindow.refresh()
        if Launch.background { settingsWindow.window?.orderFront(nil) } else { settingsWindow.showWindow(nil); settingsWindow.window?.makeKeyAndOrderFront(nil) }
    }
    // MARK: thumbnails ready before the overview opens

    /// Render any page whose thumbnail is missing or out of date (background, parallel). Off in test modes that
    /// count renders; the robot turns it on.
    func warmThumbnails() {
        guard warmsThumbnails else { return }
        let page = canvas.camera.page
        for d in canvas.pages { ThumbnailCache.shared.refresh(d, page: page) { [weak self] in self?.gallery?.redrawGrid() } }
    }
    /// After an edit: the edited page's thumbnail, a moment after the ink stops changing.
    func warmThumbnailSoon() {
        guard warmsThumbnails else { return }
        thumbWarm?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.warmThumbnails() }
        thumbWarm = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    // MARK: click to draw

    func setClickDrawTimeout(_ seconds: Double) {
        CanvasView.clickDrawTimeout = min(max(seconds.rounded(), 0), 5)
        if !Launch.testing { UserDefaults.standard.set(CanvasView.clickDrawTimeout, forKey: "clickToDrawTimeout") }
    }
    /// Test hook: a click on the trackpad in draw mode (the frozen pointer sits on the canvas).
    func robotCanvasClick() {
        let p = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(e) }
        }
    }

    // MARK: zoom as a percentage

    /// The view moved: the toolbar and capsule follow the zoom; a zoom you changed by hand shows a badge
    /// (by the page map) for a moment.
    func zoomChanged(source: String) {
        let z = canvas.camera.zoom, text = CanvasView.zoomText(z)
        container.toolbar.zoomText = text
        if var i = container.capsule.info, i.zoom != text { i.zoom = text; container.capsule.info = i; container.needsLayout = true }
        guard abs(z - lastBadgeZoom) > 1e-9 else { return }
        lastBadgeZoom = z
        guard ["pinch", "magnify", "zoomSnap", "zoomMenu"].contains(source) else { return }
        let b = container.zoomBadge
        b.stringValue = text; b.alphaValue = 1; b.isHidden = false; container.needsLayout = true
        badgeFade?.cancel()
        let w = DispatchWorkItem { [weak b] in NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; b?.animator().alphaValue = 0 }, completionHandler: { b?.isHidden = true }) }
        badgeFade = w; DispatchQueue.main.asyncAfter(deadline: .now() + PageMapView.holdSeconds, execute: w)
    }
    /// The toolbar's zoom menu: presets, the whole page, and a field to type any zoom.
    func zoomMenu() -> NSMenu {
        let m = NSMenu()
        for (k, z) in CanvasView.zoomPresets.enumerated() {
            let i = NSMenuItem(title: CanvasView.zoomText(z), action: #selector(zoomPresetPicked(_:)), keyEquivalent: ""); i.tag = k; i.target = self
            i.state = abs(canvas.camera.zoom - z) < 1e-6 ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        let whole = NSMenuItem(title: "Actual Size (100%)  ⌘0", action: #selector(resetZoom), keyEquivalent: ""); whole.target = self; m.addItem(whole)
        m.addItem(.separator())
        let field = NSTextField(frame: CGRect(x: 16, y: 2, width: 120, height: 22))
        field.placeholderString = "Type a zoom, e.g. 175"
        field.target = self; field.action = #selector(zoomTyped(_:))
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 152, height: 26)); holder.addSubview(field)
        let fi = NSMenuItem(); fi.view = holder; m.addItem(fi)
        zoomField = field
        return m
    }
    @objc func zoomPresetPicked(_ i: NSMenuItem) { canvas.setZoom(CanvasView.zoomPresets[i.tag]); usage.record("zoom_preset", ["zoom": CanvasView.zoomPresets[i.tag]]) }
    @objc func zoomTyped(_ f: NSTextField) {
        let t = f.stringValue.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v > 0 else { NSSound.beep(); return }
        canvas.setZoom(v / 100); usage.record("zoom_typed")
        f.enclosingMenuItem?.menu?.cancelTracking()
    }
    /// Test hook: the zoom menu's items; pick one by title, or type into its field.
    func robotZoomMenu(pick: String?, type: String?) -> [String: Any] {
        let m = zoomMenu()
        if let pick, let i = m.items.first(where: { $0.title == pick }), let a = i.action { NSApp.sendAction(a, to: i.target, from: i) }
        if let type, let f = zoomField { f.stringValue = type; zoomTyped(f) }
        return ["items": m.items.filter { $0.view == nil && !$0.isSeparatorItem }.map(\.title) + (zoomField != nil ? ["(type a zoom)"] : [])]
    }

    // MARK: tips and the practice page (Tips.swift)

    func canvasAct(_ name: String, _ extra: [String: Any]) {
        usageAct(name, extra)
        if ["commit", "scratchOut", "erase", "clear", "newPage", "insertImage", "imageMove", "imageResize", "imageDelete", "imageOrder"].contains(name) { pageOps = [] }   // ⌘Z is for the ink again
        switch name {
        case "gestureUndo": tips.gestureUndo(); practiceTick(.undo); Haptics.tick()
        case "gestureRedo", "scrubStep": Haptics.tick()
        case "newLine": Haptics.tick()
        case "scrubStart": tips.gestureUndo(); practiceTick(.undo)
        case "pinchZoom": tips.pinchZoom(at: CACurrentMediaTime())
        case "scratchOut": tips.scratchedOut(); practiceTick(.scratch); Haptics.tick()
        case "newLineByHand": tips.manualNewLine()
        case "commit": if practiceActive { practiceStrokes += 1; if practiceStrokes >= 3 { practiceTick(.write) } }
        default: break
        }
    }
    var practiceActive: Bool { !container.practice.isHidden }
    private(set) var practiceStrokes = 0
    func practiceTick(_ s: PracticeView.Step) {
        guard practiceActive, !container.practice.done.contains(s) else { return }
        container.practice.tick(s); usage.record("practice", ["step": "\(s)"])
    }
    @objc func startPracticeAction() { startPractice() }
    func startPractice() {
        if galleryShown { openPage(canvas.pageIndex) }
        if !canvas.doc.strokes.isEmpty { page(0) }   // a blank open page (a new notebook's first) is used as it is
        practiceStrokes = 0
        let p = container.practice
        p.reset(); p.isHidden = false; p.alphaValue = 1
        usage.record("practice", ["step": "started"])
        p.onFinished = { [weak self] in
            self?.usage.record("practice", ["step": "finished"])
            self?.showToast("Practice done. That's the whole app!", seconds: 2.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.container.practice.isHidden = true }
        }
        container.needsLayout = true
        if !canvas.drawMode { enterDrawMode(lock: !canvas.testMode) }
    }

    @objc func togglePageMapAction() {
        PageMapView.enabled.toggle()
        usage.record("page_map", ["on": PageMapView.enabled])
        if !canvas.testMode { UserDefaults.standard.set(PageMapView.enabled, forKey: "pageMap") }
        settingsWindow.refresh()
        container.needsLayout = true
    }
    @objc func penAction() { apply(.tool(.pen), from: "menu") }
    @objc func markerAction() { apply(.tool(.marker), from: "menu") }
    @objc func highlighterAction() { apply(.tool(.highlighter), from: "menu") }
    @objc func eraserAction() { apply(.tool(.eraser), from: "menu") }
    @objc func exportPDF() {
        exitDrawMode("export")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(AppInfo.name) \(f.string(from: Date())).pdf"
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            self.finishExport("pdf") { try self.canvas.exportPDF(to: url) }
        }
    }
    /// File › Export Page… (⇧⌘E): the current page as PNG or SVG, with the options under the save panel's browser.
    @objc func exportPage() { openExportSheet(area: nil) }
    /// `area`: the area to start on (Export Selection… starts on Selection); nil keeps the last choice.
    func openExportSheet(area: ExportOptions.Area?) {
        exitDrawMode("export")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let panel = NSSavePanel()
        var opts = ExportOptions.load()
        if let area { opts.area = area }
        let canvas = self.canvas
        let acc = ExportAccessory(options: opts, hasSelection: canvas.selection != nil) { canvas.exportArea($0) }
        panel.accessoryView = acc
        let what = opts.area == .selection ? "Selection, page" : "Page"
        panel.nameFieldStringValue = "\(what) \(canvas.pageIndex + 1) \(f.string(from: Date())).\(opts.format.rawValue)"
        panel.useFormat(opts.format)
        acc.onChange = { [weak panel] o in
            guard let panel, panel.allowedContentTypes.first?.preferredFilenameExtension != o.format.rawValue else { return }
            panel.useFormat(o.format)
        }
        if let d = exportDirectoryForTest { panel.directoryURL = URL(fileURLWithPath: d) }
        exportPanel = panel; exportAccessory = acc
        panel.beginSheetModal(for: window) { r in
            self.exportPanel = nil; self.exportAccessory = nil
            guard r == .OK, let chosen = panel.url else { return }
            let o = acc.options
            o.save()
            var url = ExportOptions.url(chosen, for: o.format)
            if let d = self.exportDirectoryForTest {   // tests never write outside their folder, whatever the panel says
                self.exportChosenForTest.append(chosen.path)
                url = URL(fileURLWithPath: d).appendingPathComponent(url.lastPathComponent)
            }
            self.finishExport(o.format.rawValue) { try self.canvas.export(o, to: url) }
        }
    }
    private func finishExport(_ format: String, _ write: () throws -> Void) {
        do { try write(); usage.record("export", ["format": format]) }
        catch { usage.record("error", ["category": "export_failed"]); NSAlert(error: error).runModal() }
    }

    func windowWillClose(_ n: Notification) { exitDrawMode("window closed"); NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) {
        exitDrawMode("quit"); canvas.autosaver.saveNow(sync: true); canvas.recorder.flush()
        if let p = updatePanel, !p.restarting { p.window.close() }   // quitting on "ready" (not Restart to Update): the staged copy goes
        usageQuit()
        CrashNote.clear()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
