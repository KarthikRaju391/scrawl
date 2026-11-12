// First run and Help: what the app does, which touch input is live, shortcuts, and where data goes.
// The app needs no macOS permissions: MultitouchSupport, the ⌃⌥D hotkey (Carbon) and freezing the
// pointer work without Accessibility or Input Monitoring. If touches don't arrive anyway (a future
// macOS could gate them), the app falls back to the public touch API and says how to fix it.
import AppKit

enum InputStatus: Equatable {
    case full(String)        // MultitouchSupport running; which trackpads
    case basic(String)       // public NSTouch path; why
    case stalled             // MT started but never delivered; switched to basic
    case noTrackpad

    init(mtError: String?, stalled: Bool, summary: String) {
        if stalled { self = .stalled }
        else if let e = mtError { self = e == "no trackpad found" ? .noTrackpad : .basic(e) }
        else { self = .full(summary.isEmpty ? "trackpad" : summary) }
    }
    var headline: String {
        switch self {
        case .full: return "✓ Full touch input, with pressure"
        case .basic: return "Basic touch input (no pressure)"
        case .stalled: return "⚠︎ Touches weren't arriving: switched to basic touch input"
        case .noTrackpad: return "⚠︎ No trackpad found"
        }
    }
    var detail: String {
        switch self {
        case .full(let s): return "Using \(s). Pressure sets the line width."
        case .basic(let why): return "MultitouchSupport is \(why). Drawing works; line width follows speed instead of pressure."
        case .stalled: return "The trackpad's full touch data stopped reaching \(AppInfo.name), so it now uses the standard touch events. If you want pressure back, check System Settings › Privacy & Security › Input Monitoring, then reopen the app."
        case .noTrackpad: return "\(AppInfo.name) draws with a finger on a trackpad (built-in or Magic Trackpad). Connect one and reopen the app; your pages can still be viewed and exported."
        }
    }
}

enum HelpText {
    /// What one finger does: with click to draw (the default from 0.1.7.2), a touch aims and a click writes.
    static var oneFinger: (String, String) {
        CanvasView.clickToDraw ? ("One finger", "Touch to aim (a blue ring shows where), click to write; then write on with no more clicks until you stop for 3 s. Two fingers pan; pinch to zoom")
                               : ("One finger", "Draw. Two fingers pan; pinch to zoom")
    }
    static var shortcuts: [(String, String)] { [oneFinger] + rest }
    private static let rest: [(String, String)] = [
        ("⌃⌥D  or  D", "Draw mode on / off: the pointer freezes and hides, the trackpad is the page"),
        ("Esc", "Leave draw mode (the pointer comes back)"),
        ("Two fingers", "Pan; pinch to zoom"),
        ("2-finger double tap", "Undo (in draw mode)"),
        ("3-finger double tap", "Redo (in draw mode)"),
        ("2-finger double tap, hold, slide", "Scrub through undo: slide left to go back, right to come forward"),
        ("Click (click to draw)", "On by default (Settings › Click to draw): a touch shows the aim mark under your finger; press to click and the stroke starts at the mark, then draw on with no more clicks until you stop for 3 s. Off: a touch draws"),
        ("Scratch out", "A quick zig-zag over a word erases it (pen or marker; one undo brings it back)"),
        ("M  H  E", "Marker, highlighter, eraser; press again for the pen"),
        ("P", "Pen; on the pen, back to the last other tool"),
        ("1 – 5", "Size of the current tool"),
        ("Toolbar", "The same: a click turns a tool or mode on, a second click turns it off. The ⌃ chevron (or a right-click) opens sizes, colours and writing settings"),
        ("W", "Writing mode on / off (the next line when a line reaches its width; a faint line shows it as you get close)"),
        ("Return", "Writing mode: next line, back where the block began"),
        ("L", "Lock / unlock zoom"),
        ("N", "New page (K keeps writing on this one)"),
        ("G", "Pages overview: arrows or the pointer choose, Return / Space / G opens, Esc goes back"),
        ("⌘[  ⌘]", "Previous / next page"),
        ("← → ↑ ↓", "Pan the page (Shift: a whole screen); in the pages overview, choose a page"),
        ("⌘Z  ⇧⌘Z", "Undo / redo"),
        ("⌘0", "Actual size (100%), where you are"),
        ("⇧⌘0", "Back to content: all of the page's writing in view"),
        ("Green button", "Full screen (or View › Enter Full Screen)"),
        ("⌘E  ⇧⌘E", "Export all pages as PDF / this page as PNG"),
    ]
    /// The first run shows only these (the window has to fit a 13" screen); Help lists every shortcut.
    static var basics: [(String, String)] { [
        ("⌃⌥D  or  D", "Draw mode on / off: the pointer freezes and hides, the trackpad is the page"),
        ("Esc", "Leave draw mode (the pointer comes back)"),
        oneFinger,
        ("2-finger double tap", "Undo (in draw mode); ⌘Z works too"),
        ("G", "All your pages; Return opens one"),
        ("⌘E", "Export every page as a PDF"),
    ] }
    static var privacy: String {
        let logs = AppPaths.logsDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let counts = Analytics.shared.hasRemote
            ? "Anonymous usage counts (which features you use and for how long; never your ink, pages or text) are kept in \(logs)/events.jsonl and sent to PostHog anonymously (a random ID, no location). Settings › Share anonymous usage counts turns that off. "
            : "Anonymous usage counts (which features you use; never your ink, pages or text) stay in \(logs)/events.jsonl on this Mac. "
        return """
        Your pages are saved automatically on this Mac, in \(AppPaths.dataDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")), and never uploaded. \
        Crash notes and the optional touch diagnostics (Help › Record Touch Diagnostics) stay in \(logs). \(counts)\
        Otherwise the only network request is Check for Updates, which you start yourself.
        """
    }
}

/// The welcome / help window. `firstRun` shows the welcome title and a Start button.
final class InfoWindow: NSWindowController {
    var onClose: (() -> Void)?
    var onPractice: (() -> Void)?
    /// First run: "Start Drawing" closes the window and turns draw mode on.
    var onStart: (() -> Void)?

    convenience init(status: InputStatus, firstRun: Bool) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = firstRun ? "Welcome to \(AppInfo.name)" : "\(AppInfo.name) Help"
        self.init(window: w)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)
        func label(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s); l.font = font; l.textColor = color
            l.preferredMaxLayoutWidth = 508; l.setAccessibilityIdentifier(s); return l
        }
        if firstRun {
            stack.addArrangedSubview(label("Welcome to \(AppInfo.name)", .systemFont(ofSize: 20, weight: .semibold)))
            stack.addArrangedSubview(label("Write and sketch with a finger on your trackpad. Press ⌃⌥D (or D) to start: the pointer freezes and hides, and the trackpad becomes the page. Press Esc to get the pointer back.", .systemFont(ofSize: 13)))
        }
        stack.addArrangedSubview(label(status.headline, .systemFont(ofSize: 13, weight: .semibold),
                                       { if case .full = status { return .systemGreen }; return .systemOrange }()))
        stack.addArrangedSubview(label(status.detail, .systemFont(ofSize: 12), .secondaryLabelColor))
        if status == .stalled {
            let b = NSButton(title: "Open Input Monitoring Settings", target: nil, action: #selector(InfoWindow.openInputMonitoring))
            b.target = self; stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(label(firstRun ? "The basics" : "Shortcuts", .systemFont(ofSize: 13, weight: .semibold)))
        // Each label wraps at its column's width (wrapping at the window's width clipped the long keys to one line).
        let grid = NSGridView(views: (firstRun ? HelpText.basics : HelpText.shortcuts).map { k, v in
            let key = label(k, .systemFont(ofSize: 12, weight: .semibold)); key.preferredMaxLayoutWidth = 150
            let d = label(v, .systemFont(ofSize: 12)); d.preferredMaxLayoutWidth = 344
            return [key, d]
        })
        grid.columnSpacing = 14; grid.rowSpacing = 4
        grid.column(at: 0).width = 150; grid.column(at: 1).width = 344
        if firstRun { stack.addArrangedSubview(grid); stack.addArrangedSubview(label("Help › \(AppInfo.name) Help (⌘?) lists every shortcut.", .systemFont(ofSize: 12), .secondaryLabelColor)) }
        if !firstRun { stack.addArrangedSubview(grid) }
        stack.addArrangedSubview(label("Privacy", .systemFont(ofSize: 13, weight: .semibold)))
        stack.addArrangedSubview(label(HelpText.privacy, .systemFont(ofSize: 12), .secondaryLabelColor))
        if firstRun {
            let share = NSButton(checkboxWithTitle: "Share anonymous usage counts", target: nil, action: #selector(InfoWindow.toggleUsage(_:)))
            share.target = self; share.state = Analytics.shared.enabled ? .on : .off
            stack.addArrangedSubview(share)
        }
        let ok = NSButton(title: firstRun ? "Start Drawing" : "Close", target: nil, action: firstRun ? #selector(InfoWindow.start) : #selector(InfoWindow.closeWindow))
        ok.target = self; ok.keyEquivalent = "\r"
        let practice = NSButton(title: "Try a 30-second practice", target: nil, action: #selector(InfoWindow.startPractice))
        practice.target = self
        let row = NSStackView(views: [ok, practice]); row.spacing = 10
        stack.addArrangedSubview(row)
        // Never taller than the screen: the buttons stay reachable (the help list scrolls instead).
        let fit = stack.fittingSize, maxH = ((NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800) - 60
        if fit.height <= maxH {
            w.contentView = stack
            w.setContentSize(fit)
        } else {
            let doc = FlippedView(frame: CGRect(origin: .zero, size: fit)); stack.frame = doc.bounds; doc.addSubview(stack)
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: fit.width, height: maxH))
            scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = doc
            w.contentView = scroll
            w.setContentSize(scroll.frame.size)
        }
        w.center()
    }
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    @objc func start() { window?.close(); onClose?(); onStart?() }

    @objc func closeWindow() { window?.close(); onClose?() }
    @objc func toggleUsage(_ b: NSButton) { Analytics.shared.enabled = b.state == .on }
    @objc func startPractice() { window?.close(); onClose?(); onPractice?() }
    @objc func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    /// Every piece of text in the window (tests read it without showing the window).
    var texts: [String] {
        func walk(_ v: NSView) -> [String] {
            var out: [String] = []
            if let t = v as? NSTextField { out.append(t.stringValue) }
            if let b = v as? NSButton { out.append("[\(b.title)]") }
            for s in v.subviews { out += walk(s) }
            return out
        }
        return window?.contentView.map(walk) ?? []
    }
}
