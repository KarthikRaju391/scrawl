// Tips in context, each shown at most twice, only when what you're doing suggests it would help. Settings ›
// Tips turns them off. And the practice page: a short checklist that ticks itself as you try each thing.
import AppKit

final class Tips {
    enum Tip: String, CaseIterable {
        case undoGesture, autoNewLine, zoomLock, scratchOut, overview
        var text: String {
            switch self {
            case .undoGesture: return "Tip: a two-finger double tap undoes. Hold the second tap and slide to scrub."
            case .autoNewLine: return "Tip: writing mode starts the next line by itself when the line is full."
            case .zoomLock: return "Tip: L locks the zoom, so two fingers only pan."
            case .scratchOut: return "Tip: scratch out a word with a quick zig-zag, no eraser needed."
            case .overview: return "Tip: G shows every page."
            }
        }
    }
    static let maxShows = 2
    nonisolated(unsafe) static var enabled = Launch.testing ? true : (UserDefaults.standard.object(forKey: "tipsEnabled") as? Bool ?? true)

    private var shown: [String: Int]
    private let save: ([String: Int]) -> Void
    /// Shows a tip (the app's toast, held a little longer).
    var show: ((String) -> Void)?
    /// A tip was shown (analytics).
    var onShown: ((Tip) -> Void)?

    init(testing: Bool = Launch.testing) {
        if testing { shown = [:]; save = { _ in } }
        else { shown = UserDefaults.standard.dictionary(forKey: "tipsShown") as? [String: Int] ?? [:]; save = { UserDefaults.standard.set($0, forKey: "tipsShown") } }
    }

    // What's been seen, for the triggers.
    private var plainUndosInDraw = 0
    private var pinches: [Double] = []
    private var eraserPicks = 0
    private var arrowPageMoves = 0

    func count(_ t: Tip) -> Int { shown[t.rawValue] ?? 0 }
    private func offer(_ t: Tip) {
        guard Self.enabled, count(t) < Self.maxShows else { return }
        shown[t.rawValue] = count(t) + 1; save(shown)
        show?(t.text); onShown?(t)
    }
    /// You already know it: never show this one.
    private func known(_ t: Tip) { if count(t) < Self.maxShows { shown[t.rawValue] = Self.maxShows; save(shown) } }

    // Triggers.
    func undoByKeyOrToolbar(inDrawMode: Bool) { guard inDrawMode else { return }; plainUndosInDraw += 1; if plainUndosInDraw % 3 == 0 { offer(.undoGesture) } }
    func gestureUndo() { known(.undoGesture) }
    func manualNewLine() { offer(.autoNewLine) }
    func pinchZoom(at t: Double) {
        pinches = pinches.filter { t - $0 < 60 } + [t]
        if pinches.count >= 3 { pinches = []; offer(.zoomLock) }
    }
    func zoomLocked() { known(.zoomLock) }
    func pickedEraser() { eraserPicks += 1; if eraserPicks >= 2 { offer(.scratchOut) } }
    func scratchedOut() { known(.scratchOut) }
    func pageByArrow() { arrowPageMoves += 1; if arrowPageMoves >= 3 { arrowPageMoves = 0; offer(.overview) } }
    func openedOverview() { known(.overview) }
}

/// Help › Practice Page: a fresh page and a checklist in the corner; each line ticks when you do it.
final class PracticeView: NSView {
    enum Step: Int, CaseIterable {
        case write, undo, scratch, overview
        var text: String {
            switch self {
            case .write: return CanvasView.clickToDraw ? "Write your name: click once, then just write" : "Write your name"
            case .undo: return "Undo a stroke: two-finger double tap"
            case .scratch: return "Scratch out a word: quick zig-zag over it"
            case .overview: return "See all pages: press G"
            }
        }
    }
    private(set) var done = Set<Step>()
    var onFinished: (() -> Void)?

    func reset() { done = []; needsDisplay = true }
    func tick(_ s: Step) {
        guard !done.contains(s) else { return }
        done.insert(s); needsDisplay = true
        if done.count == Step.allCases.count { onFinished?() }
    }
    override var fittingSize: NSSize { NSSize(width: 300, height: CGFloat(Step.allCases.count) * 22 + 40) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor(white: 1, alpha: 0.94).setFill(); bg.fill()
        NSColor(white: 0, alpha: 0.12).setStroke(); bg.stroke()
        let title = "Practice: try each one" as NSString
        title.draw(at: CGPoint(x: 14, y: bounds.height - 26), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(white: 0.2, alpha: 1)])
        for (i, s) in Step.allCases.enumerated() {
            let y = bounds.height - 50 - CGFloat(i) * 22
            let ok = done.contains(s)
            let mark = (ok ? "✓" : "○") as NSString
            mark.draw(at: CGPoint(x: 14, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                                                                 .foregroundColor: ok ? NSColor.systemGreen : NSColor(white: 0.55, alpha: 1)])
            (s.text as NSString).draw(at: CGPoint(x: 34, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                                                 .foregroundColor: ok ? NSColor(white: 0.55, alpha: 1) : NSColor(white: 0.2, alpha: 1)])
        }
    }
}
