// The recordings the bench reads: only those committed to the repo (`git ls-files data`). data/ also holds whatever
// was recorded locally since, and results changed with it (30 Oct: two checks failed on new local recordings).
import Foundation

enum CommittedData {
    static let files: [String] = {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["ls-files", "data"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("data/") }.map { String($0.dropFirst(5)) }.filter { !$0.contains("/") }
    }()
    /// Committed recordings in data/ named `prefix…suffix`, sorted.
    static func names(_ prefix: String, _ suffix: String = ".jsonl") -> [String] { files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted() }
}

/// A check that can't run: printed as SKIP with the reason (never counted as a pass).
func skip(_ msg: String) { print("SKIP", msg) }
