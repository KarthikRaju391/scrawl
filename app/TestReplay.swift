// End-to-end test mode: replays recorded strokes (data/strokes-*.jsonl) plus a synthetic pinch
// through the same entry point as the MultitouchSupport callback (Multitouch.onFrame), with real
// timing, so filtering, gestures, rendering and presentation all run as with a finger.
//   --test-replay <strokes.jsonl>   replay, then write <data>/test-replay-done.json and keep running
//   --test-lock                     also really freeze/hide the cursor while replaying
// Everything before the onFrame callback (sensor, driver) is not exercised.
import AppKit
import QuartzCore

enum TestReplay {
    struct Frame { var dt: Double; var contacts: [Contact] }

    static func frames(from path: String) -> [Frame] {
        var out: [Frame] = []
        let pad = Multitouch.padMM
        func c(_ id: Int32, _ x: Double, _ y: Double, _ p: Double, _ size: Double, state: Int32 = 4) -> Contact {
            Contact(id: id, state: state, norm: CGPoint(x: x / pad.width, y: y / pad.height), mm: CGPoint(x: x, y: y), pressure: p, size: size, major: 7.5)
        }
        // Synthetic pinch-in to 2x around the pad centre, then the recorded strokes, then pinch out.
        func pinch(_ from: Double, _ to: Double) {
            for i in 0...50 {
                let d = from + (to - from) * Double(i) / 50
                out.append(Frame(dt: 0.008, contacts: [c(901, pad.width / 2 - d / 2, pad.height / 2, 15, 0.5), c(902, pad.width / 2 + d / 2, pad.height / 2, 15, 0.5)]))
            }
            out.append(Frame(dt: 0.008, contacts: []))
            out.append(Frame(dt: 0.2, contacts: []))
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return out }
        var strokes: [[Frame]] = []
        var id: Int32 = 1
        for line in text.split(separator: "\n") {
            guard let s = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  s["committed"] as? Bool == true, let sm = s["samples"] as? [[Double]], sm.count > 2 else { continue }
            var fs: [Frame] = []
            var prevT = sm[0][0]
            for r in sm {
                fs.append(Frame(dt: max(0.004, min(r[0] - prevT, 0.05)), contacts: [c(id, r[1], r[2], r[3], r[4])]))
                prevT = r[0]
            }
            fs.append(Frame(dt: 0.008, contacts: []))
            fs.append(Frame(dt: 0.15, contacts: []))
            strokes.append(fs)
            id += 1
        }
        // Pinch in to 2x between strokes half-way through, and back out at the end.
        let half = strokes.count / 2
        for s in strokes.prefix(half) { out += s }
        pinch(20, 40)
        for s in strokes.suffix(strokes.count - half) { out += s }
        pinch(40, 20)
        return out
    }

    static func run(path: String, onFrame: @escaping ([Contact], Double, Double) -> Void, done: @escaping (Int, Double, Double) -> Void) {
        let fs = frames(from: path)
        let t = Thread {
            Thread.sleep(forTimeInterval: 0.5)
            // Absolute deadlines so sleep overshoot doesn't accumulate.
            var deadline = CACurrentMediaTime()
            let start = deadline
            var sensorT = 0.0  // recorded timing, like the sensor's own frame clock
            for f in fs {
                deadline += f.dt
                sensorT += f.dt
                let wait = deadline - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                onFrame(f.contacts, CACurrentMediaTime(), sensorT)
            }
            let wall = CACurrentMediaTime() - start, planned = fs.reduce(0) { $0 + $1.dt }
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async { done(fs.count, wall, planned) }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }
}

/// --test-ui: clicks through the toolbar with real NSEvents (window.sendEvent, so AppKit hit-tests
/// as for a real click), writing <data>/ui-step.txt before each pause so a script can screenshot.
enum TestUI {
    static func run(window: NSWindow, toolbar: ToolbarView, dir: String, draw: @escaping () -> Void) {
        func click(_ p: CGPoint?) {
            guard let p else { return }
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
        }
        let steps: [(String, () -> Void)] = [
            ("1-background-panel", { click(toolbar.center(of: .background)) }),
            ("2-dot-background", { click(toolbar.panel.centerOfBackground(2)) }),
            ("3-pen-panel", { click(toolbar.center(of: .tool(.pen))) }),
            ("4-red-size5", { click(toolbar.panel.centerOfColor(2)); click(toolbar.panel.centerOfSize(4)) }),
            ("5-drawn", { toolbar.hidePanel(); draw() }),
            ("6-ruled", { click(toolbar.center(of: .background)); click(toolbar.panel.centerOfBackground(3)); toolbar.hidePanel() }),
            ("7-square", { click(toolbar.center(of: .background)); click(toolbar.panel.centerOfBackground(1)); toolbar.hidePanel() }),
        ]
        var i = 0
        func next() {
            guard i < steps.count else { try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8); return }
            steps[i].1()
            try? steps[i].0.write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
            i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + (steps[i - 1].0 == "5-drawn" ? 3.5 : 1.5)) { next() }
        }
        next()
    }
}
