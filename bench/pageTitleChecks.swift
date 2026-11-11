// The overview's titles and ⌘F read the page's handwriting with Vision (PageTitles.read). 0.1.7.1: the ink is read wherever
// it is on the infinite canvas (v0.1.7 cut it to the page's column: writing beside or above the column was missed), the
// title is the topmost line. Text written here with a Hershey single-stroke font (robot/fonts/rowmans.jhf, as the robot
// writes), in page units, no app state beyond PageTitles.read: the same file runs against v0.1.7.
import AppKit

private func hersheyFont(_ path: String) -> [Character: (Double, Double, [[CGPoint]])] {
    guard let s = try? String(contentsOfFile: path, encoding: .ascii) else { return [:] }
    var out: [Character: (Double, Double, [[CGPoint]])] = [:]
    for (k, line) in s.split(separator: "\n", omittingEmptySubsequences: false).prefix(96).enumerated() {
        let b = Array(line.utf8); guard b.count >= 10 else { continue }
        let d = Array(b[8...]); var strokes: [[CGPoint]] = [[]], i = 2
        while i + 1 < d.count {
            if d[i] == 32 && d[i + 1] == 82 { strokes.append([]) } else { strokes[strokes.count - 1].append(CGPoint(x: Double(d[i]) - 82, y: -(Double(d[i + 1]) - 82))) }
            i += 2
        }
        out[Character(UnicodeScalar(32 + k)!)] = (Double(d[0]) - 82, Double(d[1]) - 82, strokes.filter { !$0.isEmpty })
    }
    return out
}

func pageTitleChecks(_ check: (Bool, String) -> Void) {
    let font = hersheyFont("robot/fonts/rowmans.jhf")
    guard !font.isEmpty else { check(false, "page titles: robot/fonts/rowmans.jhf not found (run the bench from the repo)"); return }
    let page = CGSize(width: 1600, height: 984.6)
    /// `text` with its left baseline at (x, y), letters `h` units tall (handwriting at 100% is ~40).
    func write(_ text: String, _ x0: Double, _ y: Double, h: Double = 40) -> [Stroke] {
        let s = h / 21; var x = x0, out: [Stroke] = []
        for c in text {
            guard let (l, r, strokes) = font[c] else { continue }
            for st in strokes where st.count >= 2 {
                let pts = st.map { StrokePoint(p: CGPoint(x: x + ($0.x - l) * s, y: y + $0.y * s), pressure: 0.6) }
                out.append(Stroke(tool: .pen, color: SIMD4(0, 0, 0, 1), size: 3, points: pts, maxStep: 0.5))
            }
            x += (r - l) * s
        }
        return out
    }
    func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ") }
    let top = page.height
    let cases: [(String, [Stroke], String, [String])] = [
        ("in the column (as before)", write("meeting notes", 120, top - 150) + write("buy milk today", 120, top - 260), "meeting notes", ["buy milk"]),
        ("left of the column (Karthik's 6 Nov block at -1056)", write("infinite canvas", -1056, 500) + write("trying it out", -1056, 380), "infinite canvas", ["trying it out"]),
        ("right of the column", write("right margin idea", 1900, 600) + write("second thought", 1900, 480), "right margin idea", ["second thought"]),
        ("above the page's top", write("heading above", 300, top + 300) + write("body below it", 300, top + 180), "heading above", ["body below"]),
        ("spread over 3 page widths", write("first line far left", -1500, 700) + write("middle words", 600, 450) + write("far right words", 3000, 200), "first line far left", ["middle words", "far right words"]),
    ]
    for (name, strokes, title, words) in cases {
        let (t, all) = PageTitles.read(strokes, page: page)
        let ok = norm(t) == norm(title) && words.allSatisfy { norm(all).contains(norm($0)) }
        check(ok, "page titles, ink \(name): title \"\(t)\" (want \"\(title)\"), ⌘F finds \(words.map { "\"\($0)\": \(norm(all).contains(norm($0)) ? "yes" : "NO")" }.joined(separator: ", ")) [read: \"\(all.prefix(80))\"]")
    }
    // ⌘F through the overview's cache (PageTitles.refresh / matches), for the page left of the column.
    let titles = PageTitles(), doc = Document.new()
    for s in write("infinite canvas", -1056, 500) + write("trying it out", -1056, 380) { doc.add(s) }
    var done = false
    titles.refresh([doc], page: page) { done = true }
    let until = Date().addingTimeInterval(30)
    while !done && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(done && titles.matches(doc, "trying") && titles.matches(doc, "canvas") && !titles.matches(doc, "zebra"),
          "page titles: ⌘F finds a page by writing left of the column (\"trying\": \(titles.matches(doc, "trying")), \"canvas\": \(titles.matches(doc, "canvas")); title \"\(titles.title(doc))\")")
}
