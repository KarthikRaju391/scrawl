// Check 1 (OCR): Vision text recognition on an exported page vs the fixed sentence.
// Usage: swift ocr_check.swift <page.png> ["expected sentence"]
// Character accuracy per line = 1 - Levenshtein(recognized, expected) / len(expected), case-insensitive,
// whitespace collapsed. The page should hold the sentence written 5 times; each expected line is
// matched to its best recognized line, and a missing line scores 0.
import AppKit
import Vision

let args = CommandLine.arguments
guard args.count > 1, let img = NSImage(contentsOfFile: args[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: swift ocr_check.swift page.png [sentence]"); exit(2)
}
let expected = args.count > 2 ? args[2] : "The quick brown fox jumps over the lazy dog"
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

for correction in [false, true] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = correction
    req.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cg).perform([req])
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let e = norm(expected)
    var scores = lines.map { l -> (String, Double) in (l, max(0, 1 - Double(lev(norm(l), e)) / Double(e.count))) }
    scores.sort { $0.1 > $1.1 }
    let top5 = Array(scores.prefix(5)) + Array(repeating: ("(missing)", 0.0), count: max(0, 5 - scores.count))
    let mean = top5.map(\.1).reduce(0, +) / 5
    print("language correction \(correction ? "ON" : "OFF"): \(lines.count) lines recognized")
    for (l, s) in top5 { print(String(format: "  %5.1f%%  %@", s * 100, l)) }
    print(String(format: "  mean character accuracy (5 lines): %.1f%%  -> %@ (target >= 90%%)", mean * 100, mean >= 0.9 ? "PASS" : "FAIL"))
}
