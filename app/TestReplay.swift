// End-to-end test mode: replays recorded strokes (data/strokes-*.jsonl) plus a synthetic pinch
// through the same entry point as the MultitouchSupport callback (Multitouch.onFrame), with real
// timing, so filtering, gestures, rendering and presentation all run as with a finger.
//   --test-replay <strokes.jsonl>   replay, then write <data>/test-replay-done.json and keep running
//   --test-lock                     also really freeze/hide the cursor while replaying
// Everything before the onFrame callback (sensor, driver) is not exercised.
import AppKit
import QuartzCore

/// Wait until `deadline` (CACurrentMediaTime) with sub-ms accuracy, like the driver's 8 ms clock.
/// Spins: on this Mac a 6.5 ms Thread.sleep wakes a median 6.5 ms late (max 24 ms, timer
/// coalescing), which made test input bursty, unlike the real driver thread (real sessions: 8.08 ms
/// median spacing, p5-p95 7.96-8.21 ms). Costs one core while a test feeds input.
func preciseWait(until deadline: Double) {
    while CACurrentMediaTime() < deadline {}
}

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
                preciseWait(until: deadline)
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

/// --test-writing [--writing-off]: a simulated writer writes 16 four-letter "words" of small loops
/// through the real input path. With writing mode it starts each word at the caret (as a person
/// would aim for it); with --writing-off there is no caret, so it continues right of its previous
/// word on the pad, as far as the pad goes. Reports where on the pad each word started and where
/// it landed on the page.
enum TestWriting {
    static func run(canvas: CanvasView, writing: Bool, dir: String, done: @escaping () -> Void) {
        let pad = Multitouch.padMM
        var word = 0, starts: [[String: Double]] = []
        var prevEndX = 0.25, id: Int32 = 100
        func writeWord() {
            guard word < 16 else { finish(); return }
            var start = writing ? canvas.caretPad() : CGPoint(x: word == 0 ? 0.25 : prevEndX + 0.05, y: 0.5)
            var overflow = false
            if start.x > 0.78 { start.x = 0.78; overflow = true }  // no room left on the pad for 4 letters
            starts.append(["word": Double(word), "padX": start.x, "padY": start.y, "overflow": overflow ? 1 : 0])
            var seq: [[Contact]] = []
            for k in 0..<4 {
                id += 1
                let cx = start.x * pad.width + 3 + Double(k) * 7, cy = start.y * pad.height
                for j in 0...20 {
                    let a = Double(j) / 20 * 2 * .pi * 1.1
                    let x = cx + 2.5 * cos(a + .pi), y = cy + 2.5 * sin(a + .pi)
                    seq.append([Contact(id: id, state: 4, norm: CGPoint(x: x / pad.width, y: y / pad.height), mm: CGPoint(x: x, y: y), pressure: 25, size: 0.5, major: 7.5)])
                }
                seq.append([])
                for _ in 0..<15 { seq.append([]) }  // ~120 ms between letters
            }
            prevEndX = (start.x * pad.width + 3 + 3 * 7 + 2.5) / pad.width
            var sensorT = Double(word) * 10
            for (j, f) in seq.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(j) * 0.008) {
                    sensorT += 0.008
                    canvas.handle(f, arrival: CACurrentMediaTime(), sensorT: sensorT)
                }
            }
            word += 1
            // Pause between words, longer than advanceDelayMs + the slide.
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(seq.count) * 0.008 + 0.85) { writeWord() }
        }
        func finish() {
            let strokes = canvas.doc.strokes
            var words: [[String: Double]] = []
            for w in 0..<(strokes.count / 4) {
                let b = strokes[(w * 4)..<(w * 4 + 4)].map(\.bounds).reduce(CGRect.null) { $0.union($1) }
                words.append(["minX": b.minX, "maxX": b.maxX, "midY": b.midY])
            }
            let r: [String: Any] = ["writing": writing, "starts": starts, "words": words, "strokes": strokes.count]
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: dir + "/test-writing.json"))
            done()
        }
        writeWord()
    }
}

/// --test-stress <strokes.jsonl>: fills the page with N strokes of real handwriting shape (the
/// recorded strokes, scaled down and tiled like lines of text), then draws one 4-second live stroke
/// through the input path while recording per-frame CPU/GPU time and gaps between presented frames.
enum TestStress {
    static func run(canvas: CanvasView, path: String, count: Int, dir: String, done: @escaping () -> Void) {
        var shapes: [[CGPoint]] = []
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let s = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      s["committed"] as? Bool == true, let sm = s["samples"] as? [[Double]], sm.count > 2 else { continue }
                let pts = sm.map { CGPoint(x: $0[1], y: $0[2]) }
                let minX = pts.map(\.x).min()!, minY = pts.map(\.y).min()!
                let w = max(pts.map(\.x).max()! - minX, pts.map(\.y).max()! - minY, 1)
                shapes.append(pts.map { CGPoint(x: ($0.x - minX) / w, y: ($0.y - minY) / w) })  // unit box
            }
        }
        let page = canvas.camera.page
        let cell = 26.0, cols = Int(page.width / cell)
        for i in 0..<count {
            let sh = shapes[i % shapes.count]
            let ox = Double(i % cols) * cell + 3, oy = page.height - 30 - Double(i / cols) * 34
            canvas.testAddStroke(sh.enumerated().map { j, p in StrokePoint(p: CGPoint(x: ox + p.x * 20, y: oy + p.y * 20), pressure: 0.4 + 0.2 * sin(Double(j) / 5)) })
        }
        canvas.setNeedsRender()
        let pad = Multitouch.padMM
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            canvas.resetPerf()
            // Feed like the real driver: a dedicated thread on an 8 ms clock, through Multitouch.onFrame.
            let t = Thread {
                let n = 500
                var deadline = CACurrentMediaTime()
                for j in 0...n {
                    deadline += 0.008
                    preciseWait(until: deadline)
                    let a = Double(j) / 40, r = 5 + Double(j) / 20
                    let x = pad.width / 2 + cos(a) * r, y = pad.height / 2 + sin(a) * r * 0.6
                    let c = j < n ? [Contact(id: 77, state: 4, norm: CGPoint(x: x / pad.width, y: y / pad.height), mm: CGPoint(x: x, y: y), pressure: 25, size: 0.5, major: 7.5)] : []
                    Multitouch.onFrame?(c, CACurrentMediaTime(), Double(j) * 0.008)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { report() }
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
        func report() {
            func q(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(p * Double(s.count - 1)))] }
            let pf = canvas.perf
            let r: [String: Any] = [
                "strokes": canvas.doc.strokes.count,
                "vertsP50": q(pf.verts.map(Double.init), 0.5), "vertsMax": pf.verts.max() ?? 0,
                "cpuP50": q(pf.cpu, 0.5), "cpuP95": q(pf.cpu, 0.95), "cpuMax": pf.cpu.max() ?? 0,
                "gpuP50": q(pf.gpu, 0.5), "gpuP95": q(pf.gpu, 0.95), "gpuMax": pf.gpu.max() ?? 0,
                "frames": pf.gaps.count + 1, "gapP50": q(pf.gaps, 0.5), "gapP95": q(pf.gaps, 0.95), "gapMax": pf.gaps.max() ?? 0,
                "gapsOver12_5ms": pf.gaps.filter { $0 > 12.5 }.count,
                "inputsPerTickHistogram": Dictionary(grouping: pf.inputsPerTick, by: { $0 }).mapValues(\.count).map { "\($0.key):\($0.value)" }.sorted(),
                "ticks": pf.ticks, "ticksIdle": pf.ticksIdle, "tickMaxGapMs": pf.tickMaxGap,
            ]
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-stress.json"))
            done()
        }
    }
}
