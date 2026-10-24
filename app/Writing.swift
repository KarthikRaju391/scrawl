// Writing mode = auto-pan. Whatever the zoom, when a finished stroke reaches the right edge of the
// visible area, the view pans left so the end of that stroke sits in the middle of the screen, and
// you carry on writing from the middle of the pad (easy to find by feel). Never pans mid-stroke.
import CoreGraphics

struct AutoPan {
    var edge = 0.85    // a stroke reaching past this fraction of the visible width triggers a pan
    var landAt = 0.5   // ...which puts the stroke's right end at this fraction (the middle)

    /// New camera centre after a stroke with bounds `ink` finished, or nil to stay put.
    func afterStroke(_ ink: CGRect, visible v: CGRect, page: CGSize) -> CGPoint? {
        guard ink.maxX > v.minX + v.width * edge else { return nil }
        let minX = min(ink.maxX - v.width * landAt, page.width - v.width)
        guard minX > v.minX + 0.5 else { return nil }  // already at the page's right end
        return CGPoint(x: minX + v.width / 2, y: v.midY)
    }
}
