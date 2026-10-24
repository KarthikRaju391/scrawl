// --test-hand <hershey dir> [--rejoin on|off] [--seed n] [--sigma mm]: a simulated hand writes
// "The quick brown fox jumps over the lazy dog" twice at zoom 1 (page = pad) through the real
// input path. Words are cursive (Hershey script, letters joined) or print (Hershey roman), mixed;
// cursive words are often lifted and rejoined mid-word, like Karthik does. Every touch-down lands
// off its intended spot by Karthik's measured scatter (1.9 mm per axis, +0.5 mm drift in x); the
// motion within a stroke is exact. Writes the intended start of every stroke so the app's drawn
// starts can be scored exactly, plus the page PNG for OCR.
import AppKit
import QuartzCore

enum TestHand {
    struct Glyph { var left: Double; var right: Double; var strokes: [[CGPoint]] }
    static func font(_ path: String) -> [Character: Glyph] {
        var out: [Character: Glyph] = [:]
        guard let text = try? String(contentsOfFile: path, encoding: .ascii) else { return out }
        for (k, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where k < 96 {
            let b = Array(line.utf8)
            guard b.count >= 10 else { continue }
            let d = Array(b[8...])
            var strokes: [[CGPoint]] = [[]]
            var i = 2
            while i + 1 < d.count {
                if d[i] == 32 && d[i + 1] == 82 { strokes.append([]) }   // " R" = pen up
                else { strokes[strokes.count - 1].append(CGPoint(x: Double(Int(d[i]) - 82), y: -Double(Int(d[i + 1]) - 82))) }
                i += 2
            }
            out[Character(UnicodeScalar(32 + k)!)] = Glyph(left: Double(Int(d[0]) - 82), right: Double(Int(d[1]) - 82), strokes: strokes.filter { !$0.isEmpty })
        }
        return out
    }

    static func run(canvas: CanvasView, fontDir: String, seed: UInt64, sigma: Double, dir: String, done: @escaping () -> Void) {
        let script = font(fontDir + "/scripts.jhf"), roman = font(fontDir + "/rowmans.jhf")
        let words = Array(repeating: "The quick brown fox jumps over the lazy dog".split(separator: " ").map(String.init), count: 2).flatMap { $0 }
        let pad = Multitouch.padMM
        let H = 5.0, s = H / 21          // cap height 5 mm on the pad; Hershey cap height ~21 units
        var rng = TestRNG(s: seed)
        func gauss() -> Double { sqrt(-2 * log(max(rng.next(), 1e-12))) * cos(2 * .pi * rng.next()) }
        var plan: [[String: Any]] = []   // per stroke: intended start (pad mm), context
        let t = Thread {
            var deadline = CACurrentMediaTime(), sensorT = 0.0, id: Int32 = 20000
            func emit(_ c: [Contact]) {
                deadline += 0.008; sensorT += 0.008
                preciseWait(until: deadline)
                Multitouch.onFrame?(c, CACurrentMediaTime(), sensorT)
            }
            func pause(_ sec: Double) { for _ in 0..<max(1, Int(sec / 0.008)) { emit([]) } }
            func stroke(_ pts: [CGPoint]) {
                id += 1
                var path: [CGPoint] = []
                for (a, b) in zip(pts, pts.dropFirst()) {
                    let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / (45 * 0.008)))
                    for k in 0..<n { let u = Double(k) / Double(n); path.append(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)) }
                }
                path.append(pts.last!)
                if path.count < 4 { path += Array(repeating: path.last!, count: 4 - path.count) }
                for (k, p) in path.enumerated() {
                    let pr = 10 + 25 * sin(Double.pi * Double(k + 1) / Double(path.count + 1))
                    emit([Contact(id: id, state: 4, norm: CGPoint(x: p.x / pad.width, y: p.y / pad.height), mm: p, pressure: pr, size: 0.5, major: 7.5)])
                }
                emit([])
            }
            var penX = 8.0, baseY = pad.height - 10 - H
            for w in words {
                let cursive = rng.next() < 0.5
                let f = cursive ? script : roman
                let width = w.reduce(0.0) { $0 + ((f[$1]?.right ?? 0) - (f[$1]?.left ?? 0)) * s }
                if penX + width > pad.width - 6 { penX = 8; baseY -= H * 2.6; pause(0.7) }
                var x = penX
                var planned: [[CGPoint]] = []
                for ch in w {
                    guard let g = f[ch] else { continue }
                    for stg in g.strokes { planned.append(stg.map { CGPoint(x: x + ($0.x - g.left) * s, y: baseY + ($0.y + 9) * s) }) }
                    x += (g.right - g.left) * s
                }
                var strokes: [(pts: [CGPoint], ctx: String)] = []
                for (k, st) in planned.enumerated() {
                    if cursive, let last = strokes.last?.pts.last, hypot(st[0].x - last.x, st[0].y - last.y) < H * 0.5 {
                        strokes[strokes.count - 1].pts += st
                    } else { strokes.append((st, k == 0 ? "newWord" : "inWord")) }
                }
                // Cursive: often lift mid-word and rejoin exactly where the ink stopped.
                if cursive, rng.next() < 0.7, let longest = strokes.indices.max(by: { strokes[$0].pts.count < strokes[$1].pts.count }),
                   strokes[longest].pts.count > 20 {
                    let cut = Int(Double(strokes[longest].pts.count) * (0.35 + rng.next() * 0.3))
                    let a = Array(strokes[longest].pts[...cut]), b = Array(strokes[longest].pts[cut...])
                    strokes[longest] = (a, strokes[longest].ctx)
                    strokes.insert((b, "rejoin"), at: longest + 1)
                }
                for (i, st) in strokes.enumerated() {
                    let e = CGPoint(x: 0.5 + gauss() * sigma, y: gauss() * sigma)   // landing error, mm
                    plan.append(["x": st.pts[0].x, "y": st.pts[0].y, "ex": st.pts.last!.x, "ey": st.pts.last!.y, "ctx": st.ctx, "word": w, "cursive": cursive])
                    stroke(st.pts.map { CGPoint(x: $0.x + e.x, y: $0.y + e.y) })
                    pause(i + 1 < strokes.count && strokes[i + 1].ctx == "rejoin" ? 0.10 + rng.next() * 0.06 : 0.12 + rng.next() * 0.1)
                }
                penX = x + H * 0.8
                pause(0.35 + rng.next() * 0.15)
            }
            pause(0.5)
            DispatchQueue.main.async {
                canvas.flushInputForTest()
                // Drawn start of each stroke, back in pad mm (zoom 1: page = pad).
                let v = canvas.camera.visible
                func mm(_ p: CGPoint) -> [Double] { [(p.x - v.minX) / v.width * pad.width, (p.y - v.minY) / v.height * pad.height] }
                let drawn = canvas.doc.strokes.map { mm($0.points.first!.p) + mm($0.points.last!.p) }
                let r: [String: Any] = ["seed": seed, "sigma": sigma, "rejoin": canvas.settings.rejoinSnap, "snapped": canvas.rejoinCount,
                                        "plan": plan, "drawn": drawn, "text": words.joined(separator: " ")]
                try? JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: dir + "/test-hand.json"))
                try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/page.png"), pxPerUnit: 2)
                done()
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }
}
