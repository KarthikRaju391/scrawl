// Replay a recorded session: what the page looked like at each moment, with the fingers on it.
// Usage: replay <session.jsonl> <strokes.jsonl> <out dir> [--undos | --from s --to s] [--fps n]
//   --undos: a clip around every undo (3 s before, 1 s after), one mp4 per undo
// Draws the visible page area, the ink present then (undone strokes removed), the stroke in progress,
// a dot for each finger (blue = one finger drawing, orange = two fingers), and labels for actions.
import AppKit
import Foundation

let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: replay session.jsonl strokes.jsonl outdir [--undos | --from s --to s] [--fps n]"); exit(2) }
func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
let fps = Double(arg("--fps") ?? "20") ?? 20
func lines(_ p: String) -> [[String: Any]] {
    (try? String(contentsOfFile: p, encoding: .utf8))?.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
}
let sess = lines(a[1]), strokeRecs = lines(a[2]).filter { $0["kind"] == nil }
let outDir = a[3]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Clocks: session records carry m (media clock) and t (sensor clock); stroke samples use t.
let offsets = sess.filter { $0["k"] as? String == "touch" }.compactMap { r -> Double? in
    guard let m = r["m"] as? Double, let t = r["t"] as? Double else { return nil }; return m - t }.sorted()
let tToM = offsets.isEmpty ? 0 : offsets[offsets.count / 2]
let m0 = (sess.first?["m"] as? Double) ?? 0

// Strokes: k-th strokeBegin in the session = k-th record in the stroke log. The page contents are
// rebuilt exactly like the app's Document: commits, eraser removals, snapshots for undo/redo/clear.
struct S { var pts: [(m: Double, x: Double, y: Double)]; var committed: Bool; var tool: String; var beginM: Double; var endM = Double.infinity }
var strokes: [S] = []
var idToStroke: [Int: Int] = [:]
var page = 0
var docs: [Int: [Int]] = [:], undo: [Int: [[Int]]] = [:], redo: [Int: [[Int]]] = [:]
var timeline: [(m: Double, page: Int, ids: [Int])] = []
func changed(_ m: Double) { timeline.append((m, page, docs[page] ?? [])) }
func snapshot() { undo[page, default: []].append(docs[page] ?? []); redo[page] = [] }
var eraserSnapshotTaken = false, eraserRemoved = false
for r in sess where r["k"] as? String == "act" {
    let m = r["m"] as? Double ?? 0
    switch r["a"] as? String {
    case "newPage": page = (docs.keys.max() ?? 0) + 1; docs[page] = []; changed(m)
    case "goToPage": page = r["page"] as? Int ?? page; changed(m)
    case "strokeBegin":
        let k = strokes.count
        let rec = k < strokeRecs.count ? strokeRecs[k] : [:]
        let sm = (rec["samples"] as? [[Double]]) ?? []
        strokes.append(S(pts: sm.map { ($0[0] + tToM, $0[5], $0[6]) }, committed: rec["committed"] as? Bool ?? false, tool: rec["tool"] as? String ?? "pen", beginM: m))
        if strokes.last!.tool == "eraser" { snapshot(); eraserSnapshotTaken = true; eraserRemoved = false }
    case "strokeEnd":
        if !strokes.isEmpty { strokes[strokes.count - 1].endM = m }
        if eraserSnapshotTaken, !eraserRemoved { _ = undo[page]?.popLast() }   // app: dropEmptyUndo
        eraserSnapshotTaken = false
    case "commit":
        let id = r["id"] as? Int ?? 0
        idToStroke[id] = strokes.count - 1
        snapshot(); docs[page, default: []].append(id); changed(m)
    case "erase":
        let ids = Set((r["ids"] as? [Int]) ?? []); docs[page] = (docs[page] ?? []).filter { !ids.contains($0) }; eraserRemoved = true; changed(m)
    case "undo":
        if let prev = undo[page]?.popLast() { redo[page, default: []].append(docs[page] ?? []); docs[page] = prev; changed(m) }
    case "redo":
        if let next = redo[page]?.popLast() { undo[page, default: []].append(docs[page] ?? []); docs[page] = next; changed(m) }
    case "clear":
        if !(docs[page] ?? []).isEmpty { snapshot(); docs[page] = []; changed(m) }
    default: break
    }
}
let views = sess.filter { $0["k"] as? String == "view" }
let touches = sess.filter { $0["k"] as? String == "touch" }
let acts = sess.filter { $0["k"] as? String == "act" && !["strokeBegin", "strokeEnd"].contains($0["a"] as? String ?? "") }

func last(_ arr: [[String: Any]], before m: Double) -> [String: Any]? {
    var lo = 0, hi = arr.count - 1, best: Int? = nil
    while lo <= hi { let mid = (lo + hi) / 2; if (arr[mid]["m"] as? Double ?? 0) <= m { best = mid; lo = mid + 1 } else { hi = mid - 1 } }
    return best.map { arr[$0] }
}
func pageAt(_ m: Double) -> Int {
    var p = 0, maxP = 0
    for r in sess where r["k"] as? String == "act" { if (r["m"] as? Double ?? 0) > m { break }
        if r["a"] as? String == "newPage" { maxP += 1; p = maxP } else if r["a"] as? String == "goToPage" { p = r["page"] as? Int ?? p } }
    return p
}

let W = 1200.0
func render(_ m: Double, _ file: String, label: String) {
    guard let v = last(views, before: m) ?? views.first else { return }
    let vx = v["x"] as! Double, vy = v["y"] as! Double, vw = v["w"] as! Double, vh = v["h"] as! Double
    let H = W * vh / vw
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    func sp(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: (x - vx) / vw * W, y: (y - vy) / vh * H) }
    let pg = pageAt(m)
    var ids: [Int] = []
    for e in timeline where e.m <= m && e.page == pg { ids = e.ids }
    func draw(_ s: S, upTo: Double) {
        let pts = s.pts.filter { $0.m <= upTo }
        guard pts.count > 1 else { return }
        let path = NSBezierPath(); path.lineWidth = s.tool == "highlighter" ? 10 : (s.tool == "marker" ? 5 : 2.5)
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: sp(pts[0].x, pts[0].y)); for p in pts.dropFirst() { path.line(to: sp(p.x, p.y)) }
        (s.tool == "eraser" ? NSColor.systemPink.withAlphaComponent(0.4) : NSColor.black).setStroke(); path.stroke()
    }
    for id in ids { if let k = idToStroke[id] { draw(strokes[k], upTo: .infinity) } }
    for s in strokes where s.beginM <= m && m < s.endM { draw(s, upTo: m) }   // in progress (grey if later discarded)
    if let t = last(touches, before: m), m - (t["m"] as? Double ?? 0) < 0.06, let cs = t["c"] as? [[Double]] {
        let down = cs.filter { $0[1] == 3 || $0[1] == 4 }
        for c in down {
            let p = NSPoint(x: c[2] * W, y: c[3] * H)   // the view is the pad: pad 0...1 = view 0...1
            (down.count >= 2 ? NSColor.orange : NSColor.systemBlue).withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)).fill()
        }
    }
    let recent = acts.filter { let am = $0["m"] as? Double ?? 0; return am <= m && m - am < 0.8 }.compactMap { $0["a"] as? String }
    let txt = String(format: "t=%.2fs  zoom %.2f  page %d  view: %@  %@ %@", m - m0, v["z"] as? Double ?? 0, pg + 1, v["src"] as? String ?? "", recent.joined(separator: " "), label)
    NSAttributedString(string: txt, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
        .foregroundColor: recent.contains("undo") ? NSColor.systemRed : NSColor.darkGray]).draw(at: NSPoint(x: 12, y: H - 30))
    NSGraphicsContext.current = nil
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}
func clip(_ from: Double, _ to: Double, _ name: String) {
    let dir = outDir + "/" + name
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var i = 0, m = from
    while m <= to { render(m, String(format: "%@/f%05d.png", dir, i), label: ""); i += 1; m += 1 / fps }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    p.arguments = ["-loglevel", "error", "-y", "-framerate", String(Int(fps)), "-i", dir + "/f%05d.png", "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", outDir + "/" + name + ".mp4"]
    try? p.run(); p.waitUntilExit()
    print("\(name): \(i) frames -> \(outDir)/\(name).mp4")
}
if a.contains("--undos") {
    let undos = acts.filter { $0["a"] as? String == "undo" }.compactMap { $0["m"] as? Double }
    for (k, u) in undos.enumerated() { clip(u - 3, u + 1, String(format: "undo%03d", k + 1)) }
    print("\(undos.count) undo clips")
} else {
    let from = m0 + (Double(arg("--from") ?? "0") ?? 0)
    let endM = (sess.last?["m"] as? Double) ?? from
    let to = arg("--to").flatMap(Double.init).map { m0 + $0 } ?? endM
    clip(from, to, "replay")
}
