// --test-jitter: the ink stays steady while you write and autosave runs. A feeder thread pushes touch frames
// like the trackpad driver (Multitouch.onFrame, 8 ms apart): slow, steady strokes (6 mm/s) one after another,
// so a save happens every half second. Every display refresh samples the ink tip; a steady pipeline moves it
// the same small step every frame, so jitter = how far a frame's step differs from that (screen pt): a
// main-thread stall shows as frozen frames and then one big jump.
// The notebook is generated (~9,000 strokes), or TRACKPAD_DRAW_JITTER_NOTEBOOK=<file> loads a copy of a real one.
import AppKit

enum TestJitter {
    final class Box: @unchecked Sendable {
        var samples: [(Double, Double, Int)] = []; var stroke = -1; var done = false; var lastTick = 0.0; var maxGap = 0.0
    }

    static func run(app: AppDelegate) {
        let canvas = app.canvas, dir = AppPaths.dataDir, pad = Multitouch.padMM
        if let p = ProcessInfo.processInfo.environment["TRACKPAD_DRAW_JITTER_NOTEBOOK"], let d = FileManager.default.contents(atPath: p), let f = try? NotebookFile.decode(d) {
            canvas.load(f)
        } else {
            canvas.clearPage()
            for k in 0..<20 {
                if k > 0 { canvas.newPage() }
                for j in 0..<450 {
                    canvas.testAddStroke((0..<60).map { StrokePoint(p: CGPoint(x: 60 + Double(j % 15) * 100 + Double($0) * 1.2, y: 940 - Double(j / 15) * 30 + sin(Double($0) / 3) * 10), pressure: 0.6) })
                }
            }
        }
        canvas.goToPage(0)
        canvas.autosaver.saveNow(sync: true)
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: AppPaths.notebookPath)[.size] as? Int) ?? 0
        let strokesTotal = canvas.pages.reduce(0) { $0 + $1.strokes.count }
        let t0 = CACurrentMediaTime(); _ = try? canvas.notebookFile().encoded(); let encodeMs = (CACurrentMediaTime() - t0) * 1000
        app.enterDrawMode(lock: false)
        canvas.setVisibleForReplay(x: 0, y: 0, w: canvas.camera.page.width, z: 1)
        canvas.flushInputForTest()
        let savesBefore = canvas.autosaver.mainThreadMs.count
        let box = Box()
        let k = canvas.ptPerUnit * canvas.camera.zoom
        TransitionDriver.start(on: app.container) {
            let now = CACurrentMediaTime()
            if box.lastTick > 0 { box.maxGap = max(box.maxGap, now - box.lastTick) }
            box.lastTick = now
            if let tip = canvas.liveTipForTest, box.stroke >= 0 { box.samples.append((now, tip.x * k, box.stroke)) }
        }
        // Feeder: 6 strokes of 1.6 s at 6 mm/s (long enough that saves land mid-stroke), 80 ms apart, on its own thread like the driver.
        let strokes = 6, dur = 1.6, speed = 6.0
        Thread.detachNewThread {
            var sensorT = 0.0
            for s in 0..<strokes {
                box.stroke = s   // (the main queue must stay free: autosave runs there, as in the app)
                let start = CACurrentMediaTime(), y = 60.0 - Double(s) * 6
                var n = 0
                while true {
                    let t = Double(n) * 0.008
                    if t > dur { break }
                    while CACurrentMediaTime() < start + t { usleep(300) }
                    sensorT += 0.008
                    let x = 25 + speed * t
                    Multitouch.onFrame?([Contact(id: Int32(500 + s), state: 4, norm: CGPoint(x: x / pad.width, y: y / pad.height), mm: CGPoint(x: x, y: y),
                                                 pressure: 30, size: 0.5, major: 7.5)], CACurrentMediaTime(), sensorT)
                    n += 1
                }
                for _ in 0..<3 { sensorT += 0.008; Multitouch.onFrame?([], CACurrentMediaTime(), sensorT); usleep(8000) }
                box.stroke = -1
                usleep(80_000)
            }
            box.done = true
        }
        // Return now and finish from a run-loop timer: the main queue stays free, as when the app runs normally.
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard box.done || Date().timeIntervalSince(started) > 20 else { return }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                TransitionDriver.stop()
                var perStroke: [[String: Any]] = [], all: [Double] = []
                for s in 0..<strokes {
                    let pts = box.samples.filter { $0.2 == s }
                    guard pts.count > 20 else { continue }
                    let a = pts.first!.0, b = pts.last!.0
                    let mid = pts.filter { $0.0 > a + 0.1 && $0.0 < b - 0.05 }
                    guard mid.count > 10 else { continue }
                    let n = Double(mid.count), mt = mid.map(\.0).reduce(0, +) / n, mx = mid.map(\.1).reduce(0, +) / n
                    let slope = mid.reduce(0.0) { $0 + ($1.0 - mt) * ($1.1 - mx) } / mid.reduce(0.0) { $0 + ($1.0 - mt) * ($1.0 - mt) }
                    // What you see: the tip's step from one displayed frame to the next vs the steady step.
                    let dts = zip(mid, mid.dropFirst()).map { $1.0 - $0.0 }.sorted()
                    let frame = dts[dts.count / 2]
                    let dev = zip(mid, mid.dropFirst()).map { abs(($1.1 - $0.1) - slope * frame) }
                    all += dev
                    perStroke.append(["max": dev.max() ?? 0, "speedPtPerS": slope, "frameMs": frame * 1000, "samples": mid.count])
                }
                let sorted = all.sorted()
                let p99 = sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(0.99 * Double(sorted.count - 1)))]
                let saves = Array(canvas.autosaver.mainThreadMs.dropFirst(savesBefore))
                let r: [String: Any] = ["jitterP99": p99, "jitterMax": sorted.last ?? -1, "perStroke": perStroke, "maxTickGapMs": box.maxGap * 1000,
                                        "savesDuringWriting": saves.count, "saveMainThreadMs": saves, "encodeMs": encodeMs, "fileMB": Double(fileBytes) / 1e6,
                                        "strokes": strokesTotal]
                try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-jitter.json"))
                try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
            }
        }
    }
}
