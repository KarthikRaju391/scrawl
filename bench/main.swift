// Offline checks of the ink core (app/Ink.swift) against recorded trackpad data.
// Usage: bench <probe-log.jsonl> [screen points per mm]
import CoreGraphics
import Foundation
import Metal

Diagnostics.off = true
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

// 3) Render cost of the app's Metal path, offscreen at 1500x900 pt @2x with 4x MSAA:
//    a page of 200 committed strokes + a 600-point live stroke rebuilt every frame.
do {
    let dev = MTLCreateSystemDefaultDevice()!
    let r = Renderer(device: dev)!
    let w = 3000, h = 1800
    func tex(_ f: MTLPixelFormat, ms: Bool) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .private
        if ms { d.textureType = .type2DMultisample; d.sampleCount = Renderer.sampleCount }
        return dev.makeTexture(descriptor: d)!
    }
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = tex(.bgra8Unorm, ms: true)
    rpd.colorAttachments[0].resolveTexture = tex(.bgra8Unorm, ms: false)
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .multisampleResolve
    rpd.stencilAttachment.texture = tex(.stencil8, ms: true)
    rpd.stencilAttachment.loadAction = .clear
    rpd.stencilAttachment.clearStencil = 0
    rpd.stencilAttachment.storeAction = .dontCare
    let page = CGRect(x: 0, y: 0, width: 1600, height: 985)
    var items: [Renderer.DrawItem] = []
    for k in 0..<200 {
        var sp: [StrokePoint] = []
        for i in 0..<150 { sp.append(StrokePoint(p: CGPoint(x: Double(k % 20) * 78 + Double(i) / 3, y: Double(k / 20) * 95 + sin(Double(i) / 10) * 20 + 40), pressure: 0.5)) }
        let br = Brush.of(k % 10 == 0 ? .highlighter : .pen)
        items.append(.init(mesh: r.makeMesh(strokeMesh(sp, radii: strokeRadii(sp, size: k % 10 == 0 ? 14 : 3, brush: br))), verts: nil, color: SIMD4(0, 0, 0, 1)))
    }
    // GPU union check: one highlighter hairpin stroke over white; overlaps must not darken.
    do {
        let sw = 400, sh = 200
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sw, height: sh, mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .shared
        let out = dev.makeTexture(descriptor: d)!
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sw, height: sh, mipmapped: false)
        md.usage = .renderTarget; md.storageMode = .private; md.textureType = .type2DMultisample; md.sampleCount = Renderer.sampleCount
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: sw, height: sh, mipmapped: false)
        sd.usage = .renderTarget; sd.storageMode = .private; sd.textureType = .type2DMultisample; sd.sampleCount = Renderer.sampleCount
        let p2 = MTLRenderPassDescriptor()
        p2.colorAttachments[0].texture = dev.makeTexture(descriptor: md)
        p2.colorAttachments[0].resolveTexture = out
        p2.colorAttachments[0].loadAction = .clear
        p2.colorAttachments[0].storeAction = .multisampleResolve
        p2.stencilAttachment.texture = dev.makeTexture(descriptor: sd)
        p2.stencilAttachment.loadAction = .clear
        var hp: [StrokePoint] = []
        for i in 0...40 { hp.append(StrokePoint(p: CGPoint(x: 20 + Double(i) * 4, y: 50 + sin(Double(i) / 4) * 15), pressure: 0.5)) }
        hp.append(StrokePoint(p: CGPoint(x: 100, y: 52), pressure: 0.5))
        let a: Float = 0.35
        let m = r.makeMesh(strokeMesh(hp, radii: strokeRadii(hp, size: 12, brush: Brush.of(.highlighter))))
        let cb = r.queue.makeCommandBuffer()!
        r.encode(cb, p2, visible: CGRect(x: 0, y: 0, width: 200, height: 100), background: 0, spacing: 48, pxPerUnit: 2,
                 items: [.init(mesh: m, verts: nil, color: SIMD4(0, 0, 0, a))])
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: sw * sh * 4)
        out.getBytes(&px, bytesPerRow: sw * 4, from: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0)
        let darkest = stride(from: 0, to: px.count, by: 4).map { px[$0] }.min()!
        check(darkest == UInt8((1 - a) * 255 + 0.5) || darkest == UInt8((1 - a) * 255), "GPU highlighter applies alpha once per stroke (darkest \(darkest), want \(UInt8((1 - a) * 255 + 0.5)); double-applied would be \(UInt8((1 - a) * (1 - a) * 255)))")
    }
    var live: [StrokePoint] = []
    for i in 0..<600 { let a = Double(i) / 20; live.append(StrokePoint(p: CGPoint(x: 800 + cos(a) * Double(i) / 2, y: 490 + sin(a) * Double(i) / 2), pressure: 0.5 + 0.4 * sin(a))) }
    var cpu: [Double] = [], gpu: [Double] = []
    for frame in 0..<60 {
        let t0 = CFAbsoluteTimeGetCurrent()
        let radii = strokeRadii(live, size: 3, brush: Brush.of(.pen), live: true)
        let verts = strokeMesh(live, radii: radii)
        let cb = r.queue.makeCommandBuffer()!
        r.encode(cb, rpd, visible: frame % 2 == 0 ? page : page.insetBy(dx: 300, dy: 180), background: 2, spacing: 48, pxPerUnit: 3.75,
                 items: items + [.init(mesh: Mesh(), verts: verts, color: SIMD4(0, 0, 0, 1))])
        cb.commit()
        cpu.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        cb.waitUntilCompleted()
        gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }
    func p(_ v: [Double], _ q: Double) -> Double { let s = v.sorted(); return s[Int(q * Double(s.count - 1))] }
    let total = items.reduce(0) { $0 + $1.mesh.count }
    print(String(format: "Metal frame, 200 strokes (%d vertices) + live 600-pt stroke, zoom alternating 1x/2x:", total))
    check(p(cpu, 0.95) < 4, String(format: "  CPU (live mesh + encode): p50 %.2f ms, p95 %.2f ms (budget 4 ms)", p(cpu, 0.5), p(cpu, 0.95)))
    check(p(gpu, 0.95) < 6, String(format: "  GPU: p50 %.2f ms, p95 %.2f ms (budget 6 ms of an 8.3 ms frame)", p(gpu, 0.5), p(gpu, 0.95)))
}

gestureChecks(check)
smoothingTable(check)
meshEquivalence(check, strokesPath: ProcessInfo.processInfo.environment["STROKES"])
writingLayoutChecks(check)
settingsChecks(check)
notebookChecks(check)
exportChecks(check)
inputChecks(check)
updateChecks(check)
displayChecks(check)

// Prediction must point ahead along the motion: sine path like the UI test, at several phases.
do {
    var bad = 0, n = 0
    var b = StrokeBuilder(model: MTPressureModel(), minCutoff: 1.0, beta: 0.05, toCanvas: { $0 })
    for k in 0...150 {
        let x = 20 + Double(k) * 0.55, y = 38 + sin(Double(k) / 12) * 14
        b.add(InputSample(mm: CGPoint(x: x, y: y), t: Double(k) * 0.008, pressure: 30, size: 0.5))
        guard k > 10, let p = b.predicted(ahead: 0.02), let last = b.points.last else { continue }
        let vx = 0.55, vy = cos(Double(k) / 12) * 14 / 12   // true direction per frame
        let dx = p.p.x - last.p.x, dy = p.p.y - last.p.y
        n += 1
        if (dx * vx + dy * vy) / max(hypot(dx, dy) * hypot(vx, vy), 1e-9) < 0.5 { bad += 1 }  // > 60 degrees off
    }
    check(bad == 0, "predicted tip points along the motion (\(bad) of \(n) frames > 60 degrees off)")
}

// Interpolation: 12 samples on a circle of radius 50 (fast stroke). Polyline vs Catmull-Rom
// worst deviation from the true circle.
do {
    let raw = (0...12).map { i -> StrokePoint in let a = Double(i) / 12 * 2 * .pi; return StrokePoint(p: CGPoint(x: 50 * cos(a), y: 50 * sin(a)), pressure: 0.5) }
    func worst(_ pts: [StrokePoint]) -> Double {
        var w = 0.0
        for i in 1..<pts.count { for k in 0...10 {
            let t = Double(k) / 10, x = pts[i - 1].p.x + (pts[i].p.x - pts[i - 1].p.x) * t, y = pts[i - 1].p.y + (pts[i].p.y - pts[i - 1].p.y) * t
            w = max(w, abs(hypot(x, y) - 50)) } }
        return w
    }
    let smooth = catmullRom(raw, maxStep: 1)
    // Interior only (between samples 1 and 11): the end segments have no outer neighbour.
    let a = 2 * .pi / 12 * 1.0, b = 2 * .pi / 12 * 11.0
    let interior = smooth.filter { var t = atan2($0.p.y, $0.p.x); if t < 0 { t += 2 * .pi }; return t >= a - 1e-9 && t <= b + 1e-9 }
    check(worst(interior) < 0.5 && worst(Array(raw[1...11])) > 1.5, String(format: "Catmull-Rom: circle from 12 samples deviates %.2f units (polyline %.2f, radius 50); %d points", worst(interior), worst(Array(raw[1...11])), smooth.count))
}

// Default window: canvas ~1368 pt wide for a 124.8 mm pad = ~10.96 pt/mm.
let st = Settings()
jitterModel(ptPerMM: 10.96, backing: 2, minCutoff: st.minCutoff, beta: st.beta, writeLog: ProcessInfo.processInfo.environment["JITTER_LOG"])

exit(failures == 0 ? 0 : 1)
