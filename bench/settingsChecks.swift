// Zoom lock and saved settings.
import CoreGraphics
import Foundation

func settingsChecks(_ check: (Bool, String) -> Void) {
    let page = CGSize(width: 1600, height: 985)
    var cam = Camera(page: page); cam.zoom = 3; cam.home()
    let before = cam
    cam.navigate(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.4, y: 0.5), ratio: 1.8, zoomLocked: true)
    check(cam.zoom == 3 && cam.center.x > before.center.x, String(format: "zoom locked: pinch ratio 1.8 leaves zoom at %.1f and still pans (%.0f units)", cam.zoom, cam.center.x - before.center.x))
    var cam2 = before
    cam2.navigate(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.5), ratio: 1.8, zoomLocked: false)
    check(abs(cam2.zoom - 5.4) < 1e-9, "zoom unlocked: pinch ratio 1.8 zooms 3 -> 5.4")
    Camera.columnBound = true
    var wide = Camera(page: page); wide.zoom = 3; wide.center = CGPoint(x: -500, y: 500); wide.clamp()
    check(wide.visible.minX == 0, "--column-bound (before 0.1.6): the view stays inside the page's sides")
    Camera.columnBound = false
    var free = Camera(page: page); free.zoom = 3; free.center = CGPoint(x: -500, y: 1500); free.clamp()
    var far = Camera(page: page); far.zoom = 0.1; far.center = CGPoint(x: -50_000, y: 50_000); far.clamp()
    check(free.center == CGPoint(x: -500, y: 1500) && far.zoom == Camera.minZoom && far.center.x == -Camera.reach * page.width && far.center.y == page.height + Camera.reach * page.width,
          "the infinite canvas: the view goes past the page's left side and above its top (\(free.center)); zoom stops at 25% and the view within \(Int(Camera.reach)) page widths of the page (\(far.center))")

    let suite = "trackpad-draw-bench-\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    var t = ToolState(); t.tool = .marker; t.colorIndex[.marker] = 5; t.sizeIndex[.pen] = 4; t.background = 3; t.lineWidthIndex = 2; t.zoomLocked = true
    t.save(to: d)
    let u = ToolState.load(from: d)
    check(u.tool == .marker && u.colorIndex[.marker] == 5 && u.sizeIndex[.pen] == 4 && u.background == 3 && u.lineWidthIndex == 2 && u.zoomLocked,
          "tools, colour, size, background, line width and zoom lock survive save + load")
    UserDefaults.standard.removePersistentDomain(forName: suite)
}
