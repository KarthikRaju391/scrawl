// Feedback for changes you'd otherwise not notice: a haptic tick (Force Touch trackpads) when a gesture undo
// or redo lands, at each step of the undo scrub, on a new line and on a scratch-out; and a faint chevron while
// the page waits to move (the 400 ms pause), gone if a touch cancels the move.
import AppKit

enum Haptics {
    /// Settings could turn it off later; the count is for tests (you can't feel a test).
    nonisolated(unsafe) static var enabled = true
    nonisolated(unsafe) static private(set) var count = 0
    static func tick() {
        guard enabled else { return }
        count += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

final class PendingMoveView: NSView {
    enum Kind { case pan, newLine }
    private(set) var kind: Kind?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ k: Kind) { kind = k; isHidden = false; needsDisplay = true; superview?.needsLayout = true }
    func hide() { kind = nil; isHidden = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let k = kind else { return }
        let name = k == .pan ? "chevron.compact.right" : "arrow.turn.down.left"
        let cfg = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium).applying(.init(paletteColors: [NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 0.45)]))
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: k == .pan ? "The page will move along" : "Next line coming")?.withSymbolConfiguration(cfg) {
            img.draw(in: CGRect(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }
}
