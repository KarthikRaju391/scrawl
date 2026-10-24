// Offline checks of the ink core (app/Ink.swift) against recorded trackpad data.
// Usage: bench <probe-log.jsonl> [screen points per mm]
import CoreGraphics
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failures += 1 } }

// 1) Union fill: a highlighter stroke must not have holes where circles and quads overlap,
//    and overlaps must not darken (one fill = alpha applied once).
do {
    let w = 200, h = 100
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var pts: [StrokePoint] = []
    for i in 0...40 { pts.append(StrokePoint(p: CGPoint(x: 20 + Double(i) * 4, y: 50 + sin(Double(i) / 4) * 15), pressure: 0.5)) }
    // A sharp hairpin back over itself, the usual self-intersection case.
    pts.append(StrokePoint(p: CGPoint(x: 100, y: 52), pressure: 0.5))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(strokePath(pts, size: 12, brush: Brush.of(.highlighter)))
    ctx.fillPath(using: .winding)
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var alphas = Set<UInt8>()
    for y in 0..<h { for x in 0..<w { let a = data[(y * w + x) * 4 + 3]; if a > 0 { alphas.insert(a) } } }
    check(alphas.max()! == 89, "highlighter alpha applied once, overlaps don't darken (max alpha \(alphas.max()!), want 89)")
    // Sample along the centerline: every pixel must be filled (no winding holes).
    var holes = 0
    for p in pts { let x = Int(p.p.x), row = h - 1 - Int(p.p.y); if data[(row * w + x) * 4 + 3] < 80 { holes += 1 } }  // bitmap rows run top-down
    check(holes == 0, "no holes on the centerline (\(holes) found)")
}

// 2) Replay recorded finger tracks through the filter. Jitter: windows where the raw finger
//    barely moved for >= 0.5 s; compare raw vs filtered spread in screen points.
let args = CommandLine.arguments
let ptPerMM = args.count > 2 ? Double(args[2])! : 9.0  // ~ page frame width / pad width on a 14" MBP at 100% zoom
if args.count > 1 {
    struct S { var t: Double; var mm: CGPoint; var p: Double; var size: Double }
    var tracks: [[S]] = []
    var live: [Int: Int] = [:]  // contact id -> index in tracks
    let padW = 124.8, padH = 76.8
    for line in try! String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n") {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              o["src"] as? String == "mt" else { continue }
        let ts = o["ts"] as! Double
        let fs = (o["f"] as? [[String: Any]]) ?? []
        var seen = Set<Int>()
        for f in fs {
            let id = f["id"] as! Int, st = f["state"] as! Int
            guard st == 3 || st == 4 else { continue }
            seen.insert(id)
            let s = S(t: ts, mm: CGPoint(x: (f["x"] as! Double) * padW, y: (f["y"] as! Double) * padH),
                      p: f["pressure"] as! Double, size: f["total"] as! Double)
            if let i = live[id] { tracks[i].append(s) } else { live[id] = tracks.count; tracks.append([s]) }
        }
        for id in live.keys where !seen.contains(id) { live[id] = nil }
    }
    print("tracks: \(tracks.count), samples: \(tracks.map(\.count).reduce(0, +))")

    func spread(_ ps: [CGPoint]) -> Double {
        let xs = ps.map(\.x), ys = ps.map(\.y)
        return max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    }
    var rawSpreads: [Double] = [], filtSpreads: [Double] = [], windowSecs: [Double] = []
    var lagMM: [Double] = []
    for tr in tracks where tr.count > 10 {
        var b = StrokeBuilder(model: MTPressureModel(), minCutoff: 1.0, beta: 0.05, toCanvas: { $0 })
        var filtered: [CGPoint] = []
        for s in tr {
            b.add(InputSample(mm: s.mm, t: s.t, pressure: s.p, size: s.size))
            filtered.append(b.lastFiltered!)
        }
        for (i, s) in tr.enumerated() { lagMM.append(hypot(filtered[i].x - s.mm.x, filtered[i].y - s.mm.y)) }
        // Still windows: greedy, raw spread < 0.4 mm, duration >= 0.5 s; skip the first 0.15 s (settling).
        var i = 0
        while i < tr.count {
            var j = i
            while j + 1 < tr.count && spread(tr[i...(j + 1)].map(\.mm)) < 0.4 { j += 1 }
            if tr[j].t - tr[i].t >= 0.5 {
                let k = tr[i...j].firstIndex { $0.t - tr[i].t >= 0.15 } ?? i
                rawSpreads.append(spread(tr[k...j].map(\.mm)) * ptPerMM)
                filtSpreads.append(spread(Array(filtered[k...j])) * ptPerMM)
                windowSecs.append(tr[j].t - tr[k].t)
            }
            i = j + 1
        }
    }
    func pct(_ v: [Double], _ q: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(q * Double(s.count - 1) + 0.5))] }
    if rawSpreads.isEmpty {
        print("no still windows >= 0.5 s in this log (needs the guided hold_still step)")
    } else {
        print(String(format: "still windows: %d (%.1f-%.1f s). spread at %.1f pt/mm, 100%% zoom:", rawSpreads.count, windowSecs.min()!, windowSecs.max()!, ptPerMM))
        print(String(format: "  raw      p50 %.2f pt  max %.2f pt", pct(rawSpreads, 0.5), rawSpreads.max()!))
        print(String(format: "  filtered p50 %.2f pt  max %.2f pt", pct(filtSpreads, 0.5), filtSpreads.max()!))
    }
    print(String(format: "filter lag behind raw (all samples): p50 %.2f mm, p95 %.2f mm", pct(lagMM, 0.5), pct(lagMM, 0.95)))
}

// 3) Render cost: rebuilding + filling a long active stroke every frame on the CPU.
do {
    let scale = 2, w = 1500 * scale, h = 900 * scale
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    var pts: [StrokePoint] = []
    for i in 0..<600 { let a = Double(i) / 20; pts.append(StrokePoint(p: CGPoint(x: 750 + cos(a) * Double(i) / 2, y: 450 + sin(a) * Double(i) / 2), pressure: 0.5 + 0.4 * sin(a))) }
    let n = 120
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<n {
        ctx.addPath(strokePath(pts, size: 6, brush: Brush.of(.pen)))
        ctx.fillPath(using: .winding)
    }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
    check(ms < 4, String(format: "600-point stroke build+fill: %.2f ms/frame (budget 4 ms of an 8.3 ms frame)", ms))
}

exit(failures == 0 ? 0 : 1)
