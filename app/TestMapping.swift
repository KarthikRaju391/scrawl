// --test-mapping: the trackpad maps onto the whole writing area (window, or screen in full screen).
// For the real window and for full-screen sizes (the container resized to a screen, without taking a
// Space): the canvas fills the container, the toolbar is hidden in draw mode, and pad corners / edge
// midpoints land on the view's corners / edges at zoom 1 and zoomed in and panned. Also real strokes
// through the input path from each corner. checks/mapping.sh reads test-mapping.json.
import AppKit

enum TestMapping {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, container = app.container!, dir = AppPaths.dataDir
        var r: [String: Any] = ["padAspect": AppDelegate.padAspect]
        let cr = app.window.contentRect(forFrameRect: app.window.frame)
        r["windowContentAspect"] = cr.width / cr.height
        r["fullScreenPrimary"] = app.window.collectionBehavior.contains(.fullScreenPrimary)
        r["edgeGuard"] = canvas.edgeGuardFraction
        app.enterDrawMode(lock: false)
        /// View point (pt, origin bottom-left) the pad point (raw 0...1) lands on.
        func view(_ n: CGPoint) -> CGPoint {
            let c = canvas.camera.canvas(fromPad: n), v = canvas.camera.visible
            return CGPoint(x: (c.x - v.minX) / v.width * canvas.bounds.width, y: (c.y - v.minY) / v.height * canvas.bounds.height)
        }
        var scenarios: [[String: Any]] = []
        let sizes: [(String, CGSize?)] = [("window", nil), ("full screen 1512x950 (built-in, below the notch)", CGSize(width: 1512, height: 950)),
                                          ("full screen 1920x1080", CGSize(width: 1920, height: 1080)), ("full screen 2560x1440", CGSize(width: 2560, height: 1440))]
        for (name, size) in sizes {
            if let size { container.setFrameSize(size) }
            container.needsLayout = true; container.layoutSubtreeIfNeeded()
            canvas.setNeedsRender()
            let g = canvas.edgeGuardFraction
            let a = g, b = 1 - g   // the active area's edges on the pad
            let probes: [(String, CGPoint, CGPoint)] = [   // name, pad point, expected view point as fraction of the view
                ("bottom-left", CGPoint(x: a, y: a), CGPoint(x: 0, y: 0)), ("top-right", CGPoint(x: b, y: b), CGPoint(x: 1, y: 1)),
                ("top-left", CGPoint(x: a, y: b), CGPoint(x: 0, y: 1)), ("bottom-right", CGPoint(x: b, y: a), CGPoint(x: 1, y: 0)),
                ("left middle", CGPoint(x: a, y: 0.5), CGPoint(x: 0, y: 0.5)), ("top middle", CGPoint(x: 0.5, y: b), CGPoint(x: 0.5, y: 1)),
                ("centre", CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)),
            ]
            var worst = 0.0
            var zooms: [String: Double] = [:]
            for (zname, zoom, pan) in [("zoom 1", 1.0, CGPoint.zero), ("zoom 3 panned", 3.0, CGPoint(x: 230, y: -140))] {
                var t = canvas.tools; t.zoomLocked = false; canvas.tools = t
                canvas.setVisibleForReplay(x: pan.x, y: canvas.camera.page.height - canvas.camera.page.height / zoom + pan.y, w: canvas.camera.page.width / zoom, z: zoom)
                var err = 0.0
                for (_, p, want) in probes {
                    let got = view(p), w = CGPoint(x: want.x * canvas.bounds.width, y: want.y * canvas.bounds.height)
                    err = max(err, hypot(got.x - w.x, got.y - w.y))
                }
                zooms[zname] = err; worst = max(worst, err)
            }
            let f = canvas.frame, bnd = container.bounds
            scenarios.append(["name": name, "container": [bnd.width, bnd.height], "canvas": [f.minX, f.minY, f.width, f.height],
                              "gapPt": max(abs(f.minX), abs(f.minY), abs(bnd.width - f.maxX), abs(bnd.height - f.maxY)),
                              "cornerErrorPt": zooms, "toolbarHiddenInDrawMode": container.toolbar.isHidden,
                              "stretch": (bnd.width / bnd.height) / AppDelegate.padAspect])
            _ = worst
        }
        r["scenarios"] = scenarios
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-mapping.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
