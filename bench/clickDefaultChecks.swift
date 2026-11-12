// 0.1.7.2: click to draw is the default (Karthik). A fresh install's empty defaults read as on; an explicit choice is kept.
// With it on, a touch alone never inks; a click starts the ink, and drawing goes off again 3 s after the last lift.
// ⌘0 (Actual Size) animates about the view's centre like Back to Content, ends at exactly 100% there, and a hand move
// stops it where it is.
import AppKit

func clickDefaultChecks(_ check: (Bool, String) -> Void) {
    // Defaults in a throwaway domain (never the app's own).
    let name = "scrawl-bench-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    defer { d.removePersistentDomain(forName: name) }
    let fresh = CanvasView.clickToDrawSetting(d)
    d.set(false, forKey: "clickToDraw"); let off = CanvasView.clickToDrawSetting(d)
    d.set(true, forKey: "clickToDraw"); let on = CanvasView.clickToDrawSetting(d)
    check(fresh && !off && on, "click to draw: a fresh install (empty defaults) has it on (\(fresh)); an explicit off stays off (\(!off)); an explicit on stays on (\(on))")

    // The bench isn't the app (no bundle): it keeps the checks' default, off, whatever its own defaults domain says
    // (it has no setting, which reads as on: f4276b7 crashed the line-width checks that way).
    check(Bundle.main.bundleIdentifier == nil && CanvasView.clickToDraw == false, "click to draw: a process that isn't the app (the bench) starts with it off (\(CanvasView.clickToDraw))")
    // A touch alone never inks; a click, then the same touch, does; 3 s after the last lift it's off again.
    let saved = CanvasView.clickToDraw
    defer { CanvasView.clickToDraw = saved }
    CanvasView.clickToDraw = true
    let r = WReal(waitMs: 400, widthIdx: 0, zoom: 1, viewX: 0)
    r.canvas.writingMode = false
    r.vclock = CACurrentMediaTime()   // frames on the real clock, as live: the click's tap check compares the two
    let v = r.canvas.camera.visible
    func word(_ x: Double) -> CGRect { CGRect(x: v.minX + x * v.width, y: v.midY, width: v.width * 0.05, height: 20) }
    var strokes: [Int] = []
    for k in 0..<3 { _ = r.apply(.write(.at(0)), place: word(0.2 + 0.1 * Double(k))); r.tick(0.3); strokes.append(r.canvas.doc.strokes.count) }
    r.canvas.clickDown()   // a click (the trackpad pressed), as the live app gets it
    _ = r.apply(.write(.at(0)), place: word(0.6)); r.tick(0.3); strokes.append(r.canvas.doc.strokes.count)
    _ = r.apply(.write(.at(0)), place: word(0.7)); r.tick(0.3); strokes.append(r.canvas.doc.strokes.count)   // still on: no more clicks
    // 3 s after the last lift (the timer runs on the real clock): off; a touch alone no longer inks.
    let until = Date().addingTimeInterval(3.4)
    while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    _ = r.apply(.write(.at(0)), place: word(0.8)); r.tick(0.3); strokes.append(r.canvas.doc.strokes.count)
    check(strokes == [0, 0, 0, 1, 2, 2],
          "click to draw on: 3 touches alone ink nothing; after a click a touch inks, and the next one too with no click; 3 s after the last lift a touch alone inks nothing again (strokes after each: \(strokes))")
    CanvasView.clickToDraw = saved

    // ⌘0: animated (not at once), ends at exactly 100% about the same centre; zoom locked: unchanged.
    let a = WReal(waitMs: 400, widthIdx: 0, zoom: 0.4, viewX: 0)
    let c = a.canvas; c.drawMode = false
    c.setVisibleForReplay(x: -2600, y: -900, w: wPage.width / 0.4, z: 0.4)
    let c0 = c.camera.center
    c.resetZoom()
    let started = c.slidingForTest == "zoomToPage" && abs(c.camera.zoom - 0.4) < 1e-9
    c.flushInputForTest()
    check(started && abs(c.camera.zoom - 1) < 1e-12 && hypot(c.camera.center.x - c0.x, c.camera.center.y - c0.y) < 1e-9,
          String(format: "⌘0: animated (still at 40%% right after: %@), ends at exactly 100%% (%.6f) about the same centre (moved %.2g)", started ? "yes" : "NO", c.camera.zoom, hypot(c.camera.center.x - c0.x, c.camera.center.y - c0.y)))
    // Interrupted: 0.1 s in, an arrow key (a hand move) stops it where it is; no jump to 100%.
    c.setVisibleForReplay(x: -2600, y: -900, w: wPage.width / 0.4, z: 0.4)
    c.resetZoom()
    let t0 = Date(); while Date().timeIntervalSince(t0) < 0.1 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    c.panByArrow(dx: 1, dy: 0, screen: false)
    let zi = c.camera.zoom
    c.flushInputForTest()
    check(c.slidingForTest == nil && zi > 0.4 + 1e-3 && zi < 1 - 1e-3 && abs(c.camera.zoom - zi) < 1e-12,
          String(format: "⌘0 interrupted 0.1 s in by an arrow key: stops where it was (zoom %.3f, between 40%% and 100%%; after: %.3f, no jump to the end)", zi, c.camera.zoom))
    var t = c.tools; t.zoomLocked = true; c.tools = t
    c.setVisibleForReplay(x: 0, y: 0, w: wPage.width / 2.5, z: 2.5); c.resetZoom(); c.flushInputForTest()
    check(abs(c.camera.zoom - 2.5) < 1e-12, "⌘0 with the zoom locked: unchanged (\(c.camera.zoom))")
    t.zoomLocked = false; c.tools = t
    _ = a
}
