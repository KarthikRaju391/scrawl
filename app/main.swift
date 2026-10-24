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

    func applicationDidFinishLaunching(_ n: Notification) {
        Watchdog.spawn()
        Signals.install { [weak self] in self?.exitDrawMode(); NSApp.terminate(nil) }

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
        if !CommandLine.arguments.contains("--no-activate") { window.makeKeyAndOrderFront(nil) }

        let tb = container.toolbar
        tb.state = cv.tools
        tb.onChange = { [weak self] s in self?.canvas.tools = s }
        tb.onUndo = { [weak self] in self?.canvas.undo() }
        tb.onRedo = { [weak self] in self?.canvas.redo() }
        tb.onDrawMode = { [weak self] in self?.toggleDrawMode() }

        if Settings().inputSource == "mt" { mtError = Multitouch.start() } else { mtError = "disabled by inputSource=nstouch" }
        cv.usingMT = mtError == nil
        Multitouch.onFrame = { [weak cv] contacts, arrival, sensorT in
            DispatchQueue.main.async { cv?.handle(contacts, arrival: arrival, sensorT: sensorT) }
        }
        HotKey.action = { [weak self] in self?.toggleDrawMode() }
        HotKey.register()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) == true ? nil : e }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.exitDrawMode() }
        buildMenu()
        updateBanner()
        startTestReplayIfAsked()
        // --no-activate: open in the background (used by the smoke test so it doesn't take focus).
        if !CommandLine.arguments.contains("--no-activate") { NSApp.activate(ignoringOtherApps: true) } else { window.orderBack(nil) }
    }

    // MARK: draw mode

    func toggleDrawMode() { canvas.drawMode ? exitDrawMode() : enterDrawMode() }

    func enterDrawMode(lock: Bool = true) {
        guard !canvas.drawMode else { return }
        container.toolbar.hidePanel()
        if lock {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Park the frozen cursor in the middle of the canvas so stray clicks land on it.
            let r = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
            let primaryH = NSScreen.screens.first!.frame.height
            CursorLock.lock(at: CGPoint(x: r.midX, y: primaryH - r.midY))
        }
        canvas.drawMode = true
        container.toolbar.drawMode = true
        updateBanner()
    }

    func exitDrawMode() {
        let wasLocked = CursorLock.locked
        CursorLock.unlock()  // unconditional: also covers a lock without draw mode
        guard canvas.drawMode else { return }
        if CommandLine.arguments.contains("--test-replay") {  // test mode: record how draw mode ended
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            let r: [String: Any] = ["wasLocked": wasLocked, "lockedAfter": CursorLock.locked, "t": Date().timeIntervalSince1970]
            try? JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: dir + "/test-exit.json"))
        }
        canvas.drawMode = false
        container.toolbar.drawMode = false
        updateBanner()
    }

    func updateBanner() {
        let model = canvas.usingMT ? Settings().widthModel : "speed (MultitouchSupport off: \(mtError ?? ""))"
        container.banner.stringValue = "Drawing: one finger draws, two fingers pan and pinch. Esc exits."
        container.banner.isHidden = !canvas.drawMode
        container.hint.stringValue = "⌃⌥D to draw with the trackpad  ·  width: \(model)"
        container.hint.isHidden = canvas.drawMode
        container.needsLayout = true
    }

    /// Returns true if the key was handled.
    func key(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { if canvas.drawMode { exitDrawMode(); return true }; container.toolbar.hidePanel(); return true }  // Esc
        guard canvas.drawMode, e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        var s = canvas.tools
        switch ch {
        case "p": s.tool = .pen
        case "m": s.tool = .marker
        case "h": s.tool = .highlighter
        case "e": s.tool = .eraser
        case "1", "2", "3", "4", "5": s.sizeIndex[s.tool] = Int(ch)! - 1
        default: return false
        }
        canvas.tools = s
        container.toolbar.state = s
        return true
    }

    // MARK: test mode (see TestReplay.swift)

    func startTestReplayIfAsked() {
        let a = CommandLine.arguments
        if a.contains("--test-ui") {
            let dir = (canvas.logger.path as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
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
                let dir = (canvas.logger.path as NSString).deletingLastPathComponent
                let report: [String: Any] = ["frames": n, "strokes": canvas.doc.strokes.count, "zoom": canvas.camera.zoom,
                                             "presented": canvas.presentedCount, "rendered": canvas.renderCount, "locked": lock,
                                             "replayWallSec": wall, "replayPlannedSec": planned]
                try? JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: dir + "/test-replay-done.json"))
            }
        }
    }

    // MARK: menu

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Trackpad Draw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(undo), keyEquivalent: "z").target = self
        let redo = edit.addItem(withTitle: "Redo", action: #selector(redoAction), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; redo.target = self
        let clear = edit.addItem(withTitle: "Clear Page", action: #selector(clearPage), keyEquivalent: "\u{8}"); clear.target = self
        editItem.submenu = edit
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Draw Mode (⌃⌥D)", action: #selector(toggleDrawModeAction), keyEquivalent: "").target = self
        view.addItem(withTitle: "Zoom to Whole Page", action: #selector(resetZoom), keyEquivalent: "0").target = self
        let exp = view.addItem(withTitle: "Export Page PNG (for OCR check)", action: #selector(exportPNG), keyEquivalent: "e"); exp.keyEquivalentModifierMask = [.command, .shift]; exp.target = self
        viewItem.submenu = view
        NSApp.mainMenu = main
    }

    @objc func undo() { canvas.undo() }
    @objc func redoAction() { canvas.redo() }
    @objc func clearPage() { canvas.clearPage() }
    @objc func resetZoom() { canvas.resetZoom() }
    @objc func toggleDrawModeAction() { toggleDrawMode() }
    @objc func exportPNG() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = (canvas.logger.path as NSString).deletingLastPathComponent
        let url = URL(fileURLWithPath: "\(dir)/page-\(f.string(from: Date())).png")
        do { try canvas.exportPNG(to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { NSAlert(error: error).runModal() }
    }

    func windowWillClose(_ n: Notification) { exitDrawMode(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) { exitDrawMode() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
