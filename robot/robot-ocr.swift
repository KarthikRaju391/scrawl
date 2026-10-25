// robot-ocr: what Vision reads in a screenshot or exported page.
//   robot-ocr <png> "<expected text>"   {"accuracy": 0..1, "text": "..."}  (character accuracy vs expected)
//   robot-ocr <png> --ink               {"ink": n}  pixels that aren't paper, ruling or grey desk (rough)
import AppKit
import Vision

let a = CommandLine.arguments
guard a.count > 2, let img = NSImage(contentsOfFile: a[1]), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("{}"); exit(2) }
func emit(_ d: [String: Any]) { print(String(data: try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), encoding: .utf8)!) }

if a[2] == "--ink" {
    let rep = NSBitmapImageRep(cgImage: cg)
    var n = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            // Ink: dark, or clearly coloured. Paper, ruling (light grey-blue) and the desk (mid grey) aren't.
            if c.brightnessComponent < 0.45 || c.saturationComponent > 0.45 { n += 1 }
        }
    }
    emit(["ink": n]); exit(0)
}

func norm(_ s: String) -> [Character] { Array(s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")) }
func lev(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
    var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
        swap(&prev, &cur)
    }
    return prev[b.count]
}
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = true
try? VNImageRequestHandler(cgImage: cg).perform([req])
// Reading order: top to bottom, then left to right.
let obs = (req.results ?? []).sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
let exp = norm(a[2])
let got = norm(text)
let acc = exp.isEmpty ? 0 : max(0, 1 - Double(lev(got, exp)) / Double(exp.count))
emit(["accuracy": acc, "text": text])
