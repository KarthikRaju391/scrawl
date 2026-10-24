// OCR a whole page and score it against the expected text (character accuracy, case-insensitive,
// whitespace collapsed): lines are read top to bottom, left to right, and joined.
// Usage: ocr_text <page.png> "<expected text>"
import AppKit
import Vision
let a = CommandLine.arguments
let cg = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
func norm(_ s: String) -> [Character] { Array(s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")) }
func lev(_ x: [Character], _ y: [Character]) -> Int {
    if x.isEmpty { return y.count }; if y.isEmpty { return x.count }
    var p = Array(0...y.count), c = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count { c[0] = i; for j in 1...y.count { c[j] = min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }; swap(&p, &c) }
    return p[y.count]
}
for corr in [false, true] {
    let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.usesLanguageCorrection = corr; r.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cg).perform([r])
    let obs = (r.results ?? []).sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
    let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    let e = norm(a[2])
    let acc = max(0, 1 - Double(lev(norm(text), e)) / Double(e.count))
    print(String(format: "language correction %@: character accuracy %.1f%%", corr ? "ON " : "OFF", acc * 100))
    if !corr { print("  read: \(text.prefix(160))") }
}
