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

    static func run(path: String, onFrame: @escaping ([Contact], Double) -> Void, done: @escaping (Int, Double, Double) -> Void) {
        let fs = frames(from: path)
        let t = Thread {
            Thread.sleep(forTimeInterval: 0.5)
            // Absolute deadlines so sleep overshoot doesn't accumulate.
            var deadline = CACurrentMediaTime()
            let start = deadline
            for f in fs {
                deadline += f.dt
                let wait = deadline - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                onFrame(f.contacts, CACurrentMediaTime())
            }
            let wall = CACurrentMediaTime() - start, planned = fs.reduce(0) { $0 + $1.dt }
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async { done(fs.count, wall, planned) }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }
}
