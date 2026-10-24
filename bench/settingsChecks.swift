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
    var wide = Camera(page: page); wide.zoom = 3; wide.center = CGPoint(x: -500, y: 500); wide.clamp()
    check(wide.visible.minX == 0, "view stays inside the page's sides (no writing off the page edge)")

    let suite = "trackpad-draw-bench-\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    var t = ToolState(); t.tool = .marker; t.colorIndex[.marker] = 5; t.sizeIndex[.pen] = 4; t.background = 3; t.lineWidthIndex = 2; t.zoomLocked = true
    t.save(to: d)
    let u = ToolState.load(from: d)
    check(u.tool == .marker && u.colorIndex[.marker] == 5 && u.sizeIndex[.pen] == 4 && u.background == 3 && u.lineWidthIndex == 2 && u.zoomLocked,
          "tools, colour, size, background, line width and zoom lock survive save + load")
    UserDefaults.standard.removePersistentDomain(forName: suite)
}
