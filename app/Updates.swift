// Version info, Check for Updates (one GitHub request, only when asked), and the local note after an
// unexpected quit.
import AppKit

enum AppInfo {
    static func info(_ k: String) -> String { Bundle.main.object(forInfoDictionaryKey: k) as? String ?? "" }
    static var name: String { info("CFBundleName").isEmpty ? "Scrawl" : info("CFBundleName") }
    static var version: String { info("CFBundleShortVersionString").isEmpty ? "dev" : info("CFBundleShortVersionString") }
    static var build: String { info("CFBundleVersion") }
}

// MARK: - Updates

/// Check for Updates: one GET to the latest GitHub release, only when the user asks. No download,
/// no background checks: a newer version opens its release page.
enum UpdateChecker {
    enum Result: Equatable { case upToDate(String), available(version: String, page: String), failed(String) }

    static var url: URL? {
        let s = ProcessInfo.processInfo.environment["TRACKPAD_DRAW_UPDATE_URL"] ?? AppInfo.info("TDUpdateURL")
        return s.isEmpty ? nil : URL(string: s)
    }

    /// Numeric dotted compare, ignoring a leading "v" ("v1.10.0" > "1.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// GitHub "Get the latest release" response (docs.github.com/rest/releases/releases#get-the-latest-release):
    /// tag_name, html_url, draft, prerelease. The endpoint never returns drafts or prereleases.
    static func parse(status: Int, data: Data?, current: String) -> Result {
        guard status == 200 else { return .failed(status == 404 ? "No published release found." : "The update server answered \(status).") }
        guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, let page = j["html_url"] as? String else { return .failed("The update information couldn't be read.") }
        if (j["draft"] as? Bool) == true || (j["prerelease"] as? Bool) == true { return .upToDate(current) }
        return isNewer(tag, than: current) ? .available(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page: page) : .upToDate(current)
    }

    static func check(current: String = AppInfo.version, done: @escaping (Result) -> Void) {
        guard let url else { done(.failed("No update address is set in this build.")); return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("TrackpadDraw/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, resp, err in
            let r: Result = err != nil ? .failed("Couldn't reach the update server (\(err!.localizedDescription)).")
                : parse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data, current: current)
            DispatchQueue.main.async { done(r) }
        }.resume()
    }
}

// MARK: - Unexpected quits (local note only)

enum CrashNote {
    static var markerPath: String { AppPaths.logsDir + "/running.pid" }
    static var logPath: String { AppPaths.logsDir + "/crashes.log" }

    /// At launch: was the last session still marked running (killed or crashed)? Writes a local note.
    static func checkAndMark() -> Bool {
        var crashed = false
        if let s = try? String(contentsOfFile: markerPath, encoding: .utf8), let pid = Int32(s.split(separator: " ").first ?? ""),
           pid != getpid(), kill(pid, 0) != 0 {
            crashed = true
            let line = "\(ISO8601DateFormatter().string(from: Date())) previous session (pid \(s.trimmingCharacters(in: .whitespacesAndNewlines))) ended without quitting; pages restored from the last autosave\n"
            if let fh = FileHandle(forWritingAtPath: logPath) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)) }
            else { FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8)) }
        }
        try? "\(getpid()) \(AppInfo.version) (\(AppInfo.build))".write(toFile: markerPath, atomically: true, encoding: .utf8)
        return crashed
    }
    static func clear() { try? FileManager.default.removeItem(atPath: markerPath) }
}

