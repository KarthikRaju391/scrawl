// Scratch-out: every committed stroke Karthik recorded must stay ink (0 false scratch-outs, with the ink
// already on the page as it was), the letters people write fast (m, w, n, z, cursive) must stay ink at any
// size and speed, circles must stay ink, and synthetic scratches over words must erase exactly those words.
import Foundation

func scratchChecks(_ check: (Bool, String) -> Void) {
    // 1. Every recorded stroke, against the strokes before it in the same file (canvas coordinates; undos are
    //    ignored, so there's more ink than there was: a harder test).
    let files = CommittedData.names("strokes-")
    var real = 0, shape = 0, falseErase: [String] = []
    for f in files {
        guard let text = try? String(contentsOfFile: "data/" + f, encoding: .utf8) else { continue }
        var prev: [Stroke] = []
        for line in text.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], d["committed"] as? Bool == true,
                  let sm = d["samples"] as? [[Double]], sm.count >= 6, sm.allSatisfy({ $0.count >= 7 }) else { continue }
            real += 1
            let tool = ToolKind(rawValue: d["tool"] as? String ?? "pen") ?? .pen
            let canvasPts = sm.map { CGPoint(x: $0[5], y: $0[6]) }
            let ft = ScratchOut.features(mm: sm.map { CGPoint(x: $0[1], y: $0[2]) }, t: sm.map { $0[0] })
            if ScratchOut.shapeMatches(ft) {
                shape += 1
                let mm = hypot(sm.last![1] - sm[0][1], sm.last![2] - sm[0][2]), cv = hypot(sm.last![5] - sm[0][5], sm.last![6] - sm[0][6])
                let k = mm > 0 ? cv / mm : 1
                if tool == .pen || tool == .marker, let gone = ScratchOut.covered(scratch: canvasPts, in: prev, reach: ScratchOut.reachMM * k) {
                    falseErase.append("\(f): would erase \(gone.count)")
                }
            }
            let s = Stroke(tool: tool, color: SIMD4(0, 0, 0, 1), size: 2, points: canvasPts.map { StrokePoint(p: $0, pressure: 0.6) }, maxStep: 1)
            prev.append(s); if prev.count > 400 { prev.removeFirst() }
        }
    }
    // (4,919 strokes are committed.)
    check(real > 4000 && falseErase.isEmpty, "scratch-out: 0 of \(real) recorded strokes would erase anything (\(shape) zig-zag-shaped, all on blank paper, highlighter or circling)\(falseErase.isEmpty ? "" : ": \(falseErase.prefix(5))")")

    // 2. Fast letters, Hershey script and roman, 3-12 mm tall, 40-160 mm/s: never a scratch.
    let fonts = ["robot/fonts/scripts.jhf", "robot/fonts/rowmans.jhf"].map { TestHand.font($0) }
    var letters = 0, letterHits: [String] = []
    for font in fonts where !font.isEmpty {
        for word in ["m", "mm", "mmm", "w", "ww", "www", "n", "nn", "z", "zz", "minimum", "wavy", "zigzag", "summer", "mummy", "w m n", "lll", "ill", "nnn", "uuu", "vvv"] {
            for h in [3.0, 6.0, 12.0] {
                for speed in [40.0, 90.0, 160.0] {
                    let s = h / 21
                    var x = 0.0
                    for ch in word {
                        guard let g = font[ch] else { x += 8 * s; continue }
                        for st in g.strokes {
                            let pts = st.map { CGPoint(x: x + ($0.x - g.left) * s, y: $0.y * s) }
                            var dense: [CGPoint] = [], ts: [Double] = [], t = 0.0
                            for (a, b) in zip(pts, pts.dropFirst()) {
                                let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / (speed * 0.008)))
                                for i in 0..<n { let u = Double(i) / Double(n); dense.append(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)); ts.append(t); t += 0.008 }
                            }
                            if let l = pts.last { dense.append(l); ts.append(t) }
                            letters += 1
                            if ScratchOut.shapeMatches(ScratchOut.features(mm: dense, t: ts)) { letterHits.append("\(word) \(h)mm \(speed)mm/s") }
                        }
                        x += (g.right - g.left) * s
                    }
                }
            }
        }
    }
    check(letters > 500 && letterHits.isEmpty, "scratch-out: \(letters) fast letter strokes (m, w, n, z, cursive; 3-12 mm, 40-160 mm/s) are never a scratch\(letterHits.isEmpty ? "" : ": \(letterHits.prefix(5))")")

    // 3. Circling (a wheel drawn round and round, an O gone over again) is not a scratch.
    var circles = 0, circleHits = 0
    for loops in [2.0, 3.0, 5.0] { for r in [3.0, 8.0, 20.0] { for flat in [1.0, 0.35] {
        let n = Int(loops * 80)
        let pts = (0...n).map { i -> CGPoint in let a = Double(i) / 80 * 2 * .pi; return CGPoint(x: r * cos(a), y: r * flat * sin(a) + Double(i) * 0.01) }
        circles += 1
        if ScratchOut.shapeMatches(ScratchOut.features(mm: pts, t: pts.indices.map { Double($0) * 0.008 })) { circleHits += 1 }
    }}}
    check(circleHits == 0, "scratch-out: \(circles) circling strokes (2-5 loops, round and flat) are not scratches (\(circleHits) were)")

    // 4. Synthetic scratches (4-9 legs, 5-30 mm, 70-220 mm/s, tilted, wobbly): detected.
    var rng = TestRNG(s: 11)
    func gauss() -> Double { sqrt(-2 * log(max(rng.next(), 1e-12))) * cos(2 * .pi * rng.next()) }
    var syn = 0, found = 0
    for _ in 0..<500 {
        let legs = 4 + Int(rng.next() * 6), amp = 5 + rng.next() * 25, spd = 70 + rng.next() * 150, ang = (rng.next() - 0.5) * 1.2, drift = 0.2 + rng.next()
        var pts: [CGPoint] = [], x = 0.0, y = 0.0
        for k in 0..<legs {
            let tx = (k % 2 == 0 ? amp : 0) + gauss() * amp * 0.08, ty = Double(k) * drift + gauss() * 0.3
            let steps = max(3, Int(abs(tx - x) / (spd * 0.008)))
            for i in 1...steps { let u = Double(i) / Double(steps); pts.append(CGPoint(x: x + (tx - x) * u + gauss() * 0.05, y: y + (ty - y) * u + gauss() * 0.05)) }
            x = tx; y = ty
        }
        pts = pts.map { CGPoint(x: $0.x * cos(ang) - $0.y * sin(ang), y: $0.x * sin(ang) + $0.y * cos(ang)) }
        syn += 1
        if ScratchOut.shapeMatches(ScratchOut.features(mm: pts, t: pts.indices.map { Double($0) * 0.008 })) { found += 1 }
    }
    check(Double(found) / Double(syn) >= 0.95, "scratch-out: \(found) of \(syn) synthetic scratches detected (\(Int(Double(found) / Double(syn) * 100))%, bar 95%)")

    // 5. What a scratch erases: the word under it, not the word next to it or a line running through.
    func word(_ x0: Double) -> [Stroke] {
        (0..<4).map { i in Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 1.5, points: (0..<20).map { j in StrokePoint(p: CGPoint(x: x0 + Double(i) * 6 + Double(j) * 0.25, y: 100 + sin(Double(j) / 3) * 4), pressure: 0.6) }, maxStep: 1) }
    }
    let target = word(100), neighbour = word(160)
    let rule = Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 1.5, points: (0..<200).map { StrokePoint(p: CGPoint(x: 50 + Double($0), y: 99), pressure: 0.6) }, maxStep: 1)
    let scratch = (0...6).flatMap { k -> [CGPoint] in (0..<12).map { i in let u = Double(i) / 12; return CGPoint(x: k % 2 == 0 ? 98 + 26 * u : 124 - 26 * u, y: 95 + Double(k) * 1.5) } }
    let gone = ScratchOut.covered(scratch: scratch, in: target + neighbour + [rule], reach: 2) ?? []
    check(Set(gone.map { ObjectIdentifier($0) }) == Set(target.map { ObjectIdentifier($0) }),
          "scratch-out: a scratch over a word erases its \(target.count) strokes, not the next word or a line through it (erased \(gone.count))")
    check(ScratchOut.covered(scratch: scratch.map { CGPoint(x: $0.x, y: $0.y + 60) }, in: target + neighbour, reach: 2) == nil, "scratch-out: a zig-zag on blank paper erases nothing (it stays as ink)")
    // A zig-zag just under the word, only grazing it (well under 60% on ink), is drawing, not a scratch-out.
    // (a tall zig-zag drawn across a small word: only where it crosses the word is on ink).
    let grazing = (0...6).flatMap { k -> [CGPoint] in (0..<12).map { i in let u = Double(i) / 12; return CGPoint(x: 98 + Double(k) * 4.5, y: k % 2 == 0 ? 60 + 80 * u : 140 - 80 * u) } }
    let onInk = grazing.filter { p in target.contains { $0.hit(p, r: 2) } }.count
    check(onInk > 0 && Double(onInk) / Double(grazing.count) < 0.6 && ScratchOut.covered(scratch: grazing, in: target + neighbour, reach: 2) == nil,
          "scratch-out: a tall zig-zag across a word (\(onInk) of \(grazing.count) points on ink) erases nothing")

    // 6. One undo brings back what a scratch erased, and removes nothing else.
    let doc = Document()
    for s in target + neighbour { doc.add(s) }
    let before = doc.strokes.map { ObjectIdentifier($0) }
    let zig = Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 1.5, points: scratch.map { StrokePoint(p: $0, pressure: 0.6) }, maxStep: 1)
    _ = zig; doc.scratchOut(erasing: target)
    check(doc.strokes.count == neighbour.count, "scratch-out: the scratch and the word go, the next word stays (\(doc.strokes.count) left)")
    doc.undo()
    check(doc.strokes.map { ObjectIdentifier($0) } == before, "scratch-out: one undo brings the word back exactly (and no scratch stroke)")
    doc.redo()
    check(doc.strokes.count == neighbour.count, "scratch-out: redo scratches it out again")
}

/// The page map shows only for moves made by hand: replay every view change in Karthik's recorded sessions
/// through its rule. Auto-pans and new lines (writing) must show it 0 times; his pinches and pans do.
func pageMapRevealChecks(_ check: (Bool, String) -> Void) {
    let files = CommittedData.names("session-2026")
    var bySource: [String: Int] = [:]
    for f in files {
        guard let text = try? String(contentsOfFile: "data/" + f, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") where line.contains("\"view\"") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let src = d["src"] as? String else { continue }
            bySource[src, default: 0] += 1
        }
    }
    let writing = ["autopan", "newLine", "resume"].reduce(0) { $0 + (bySource[$1] ?? 0) }
    let writingShown = ["autopan", "newLine", "resume"].filter { PageMapView.revealSources.contains($0) }.reduce(0) { $0 + (bySource[$1] ?? 0) }
    let handShown = bySource.filter { PageMapView.revealSources.contains($0.key) }.values.reduce(0, +)
    check(writing > 100 && writingShown == 0 && handShown > 100,
          "page map: replaying the recorded sessions, \(writing) writing moves (auto-pans, new lines) show it 0 times; \(handShown) hand moves (pinch, scroll) show it")
}

/// Thumbnails: one full page (450 handwriting-sized strokes) at thumbnail size, exact outlines vs the fast path.
func thumbnailSpeedChecks(_ check: (Bool, String) -> Void) {
    var strokes: [Stroke] = []
    for j in 0..<450 {
        let x0 = 60 + Double(j % 15) * 100, y0 = 940 - Double(j / 15) * 30
        var pts: [StrokePoint] = []
        for i in 0..<60 { let u = Double(i); pts.append(StrokePoint(p: CGPoint(x: x0 + u * 1.2, y: y0 + sin(u / 3) * 10), pressure: 0.6)) }
        strokes.append(Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 3, points: pts, maxStep: 0.5))
    }
    let page = CGSize(width: 1600, height: 984), rect = ThumbnailCache.region(strokes, page: page)
    let px = CGSize(width: ThumbnailCache.pixelWidth, height: ThumbnailCache.pixelWidth * page.height / page.width)
    func time(_ fast: Bool) -> Double { let t = Date(); _ = PageImage.render(strokes, rect: rect, pageWidth: page.width, pageTop: page.height, px: px, fast: fast); return Date().timeIntervalSince(t) * 1000 }
    _ = time(true)
    let exact = time(false), fast = time(true)
    check(fast < 40 && fast * 4 < exact, String(format: "thumbnails: a full page (450 strokes) renders in %.0f ms at thumbnail size (exact outlines: %.0f ms)", fast, exact))
}
