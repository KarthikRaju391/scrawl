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
    static let shortcuts: [(String, String)] = [
        ("⌃⌥D  or  D", "Draw mode on / off: the pointer freezes and hides, the trackpad is the page"),
        ("Esc", "Leave draw mode (the pointer comes back)"),
        ("One finger", "Draw"),
        ("Two fingers", "Pan; pinch to zoom"),
        ("2-finger double tap", "Undo (in draw mode)"),
        ("3-finger double tap", "Redo (in draw mode)"),
        ("2-finger double tap, hold, slide", "Scrub through undo: slide left to go back, right to come forward"),
        ("Click (click to draw)", "With Settings › Click to draw: a touch only aims; press to start a stroke, let go of the click and draw on; lifting ends it"),
        ("Scratch out", "A quick zig-zag over a word erases it (pen or marker; one undo brings it back)"),
        ("M  H  E", "Marker, highlighter, eraser; press again for the pen"),
        ("P", "Pen; on the pen, back to the last other tool"),
        ("1 – 5", "Pen size"),
        ("Toolbar", "The same: a click turns a tool or mode on, a second click turns it off. The ⌃ chevron (or a right-click) opens sizes, colours and writing settings"),
        ("W", "Writing mode on / off (pans along the line, then to the next line)"),
        ("Return", "Writing mode: next line, back at the left margin"),
        ("L", "Lock / unlock zoom"),
        ("N", "New page (K keeps writing on this one)"),
        ("G", "Pages overview: arrows or the pointer choose, Return / Space / G opens, Esc goes back"),
        ("⌘[  ⌘]", "Previous / next page"),
        ("← → ↑ ↓", "Pan the page (Shift: a whole screen); in the pages overview, choose a page"),
        ("⌘Z  ⇧⌘Z", "Undo / redo"),
        ("⌘0", "Zoom to the whole page"),
        ("⌃⌘F", "Full screen"),
        ("⌘E  ⇧⌘E", "Export all pages as PDF / this page as PNG"),
    ]
    static var privacy: String {
        let logs = AppPaths.logsDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let counts = Analytics.shared.hasRemote
            ? "Anonymous usage counts (which features you use and for how long; never your ink, pages or text) are kept in \(logs)/events.jsonl and sent to PostHog anonymously (a random ID, no location). Settings › Share anonymous usage counts turns that off. "
            : "Anonymous usage counts (which features you use; never your ink, pages or text) stay in \(logs)/events.jsonl on this Mac. "
        return """
        Your pages are saved automatically on this Mac, in \(AppPaths.dataDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")), and never uploaded. \
        Crash notes and the optional touch diagnostics (Help › Diagnostic Logs) stay in \(logs). \(counts)\
        Otherwise the only network request is Check for Updates, which you start yourself.
        """
    }
}

/// The welcome / help window. `firstRun` shows the welcome title and a Start button.
final class InfoWindow: NSWindowController {
    var onClose: (() -> Void)?
    var onPractice: (() -> Void)?

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
        stack.addArrangedSubview(label("Shortcuts", .systemFont(ofSize: 13, weight: .semibold)))
        let grid = NSGridView(views: HelpText.shortcuts.map { k, v in
            let d = label(v, .systemFont(ofSize: 12)); d.preferredMaxLayoutWidth = 380
            return [label(k, .systemFont(ofSize: 12, weight: .semibold)), d]
        })
        grid.columnSpacing = 14; grid.rowSpacing = 4
        grid.column(at: 0).width = 110; grid.column(at: 1).width = 380
        stack.addArrangedSubview(grid)
        stack.addArrangedSubview(label("Privacy", .systemFont(ofSize: 13, weight: .semibold)))
        stack.addArrangedSubview(label(HelpText.privacy, .systemFont(ofSize: 12), .secondaryLabelColor))
        if firstRun {
            let share = NSButton(checkboxWithTitle: "Share anonymous usage counts", target: nil, action: #selector(InfoWindow.toggleUsage(_:)))
            share.target = self; share.state = Analytics.shared.enabled ? .on : .off
            stack.addArrangedSubview(share)
        }
        let ok = NSButton(title: firstRun ? "Start Drawing" : "Close", target: nil, action: #selector(InfoWindow.closeWindow))
        ok.target = self; ok.keyEquivalent = "\r"
        let practice = NSButton(title: "Try a 30-second practice", target: nil, action: #selector(InfoWindow.startPractice))
        practice.target = self
        let row = NSStackView(views: [ok, practice]); row.spacing = 10
        stack.addArrangedSubview(row)
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
    }

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
