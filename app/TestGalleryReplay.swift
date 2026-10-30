// --test-gallery-replay: Karthik's sequence from his session of 30 Oct 19:54 (d605b6b), at his real speed, on a copy of his
// notebook (TRACKPAD_DRAW_DATA holds it): G (overview), pointer on page 9's tile, G, G, page 10, G, G, page 11, G, G,
// page 7, G. The press times are his, to the millisecond. The check script records the window while it runs.
import AppKit

enum TestGalleryReplay {
    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func key() {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                                        context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5) { _ = app.key(e) }
        }
        /// The pointer over tile i: the highlight moves there (as hovering does; nothing scrolls).
        func hover(_ i: Int) {
            guard let g = app.gallery, app.galleryShown else { return }
            g.selected = i; g.displayGridNow()
        }
        if canvas.drawMode { app.exitDrawMode("test") }
        let start = Int(ProcessInfo.processInfo.environment["REPLAY_START_PAGE"] ?? "17") ?? 17
        canvas.goToPage(min(start, canvas.pages.count - 1))
        spin(1.0)
        try? "ready".write(toFile: dir + "/replay-ready.txt", atomically: true, encoding: .utf8)
        let d = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: dir + "/replay-go.txt") && Date() < d { spin(0.02) }
        spin(0.5)
        // His presses (seconds after the first) and the tile under the pointer before each opening.
        let presses: [(Double, Int?)] = [(0, nil), (0.791, 9), (1.491, nil), (1.908, 10), (2.450, nil), (2.958, 11), (3.491, nil), (4.066, 7), (4.625, nil)]
        let t0 = Date()
        var log: [[String: Any]] = []
        for (t, tile) in presses {
            if let tile {
                while Date().timeIntervalSince(t0) < t - 0.15 { spin(0.002) }
                hover(tile)
            }
            while Date().timeIntervalSince(t0) < t { spin(0.002) }
            key()
            log.append(["t": Date().timeIntervalSince(t0), "tile": tile ?? -1, "shownAfter": app.galleryShown, "page": canvas.pageIndex])
        }
        spin(1.2)
        try? JSONSerialization.data(withJSONObject: ["presses": log], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: dir + "/test-gallery-replay.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
