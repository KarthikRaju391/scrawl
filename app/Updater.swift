// In-app updater: Check for Updates finds a newer release; with the user's go-ahead it downloads the DMG, checks it
// (SHA-256 from the release's SHA256SUMS.txt, an Ed25519 signature against the key in Info.plist, the bundle inside:
// id, a newer version, codesign), stages the new app next to this one and, on "Restart to Update", quits normally (the
// notebook saves as usual) while a small helper swaps the apps, registers the new one and opens it. If the new app
// doesn't confirm it started, the helper puts the old one back. No request is made unless the user asks, and the
// notebook's folder is never touched.
import AppKit
import CryptoKit

/// The parts of a GitHub release the updater needs.
struct UpdateRelease: Equatable {
    var version: String, notes: String, page: String
    var dmg: URL?, sums: URL?, sig: URL?
    var dmgName: String

    static func parse(_ j: [String: Any]) -> UpdateRelease? {
        guard let tag = j["tag_name"] as? String, let page = j["html_url"] as? String else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        var r = UpdateRelease(version: version, notes: (j["body"] as? String) ?? "", page: page, dmgName: "")
        for a in (j["assets"] as? [[String: Any]]) ?? [] {
            guard let name = a["name"] as? String, let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { continue }
            if name.hasSuffix(".dmg") { r.dmg = u; r.dmgName = name }
            else if name.hasSuffix(".dmg.sig") { r.sig = u }
            else if name == "SHA256SUMS.txt" { r.sums = u }
        }
        return r
    }
}

/// Checks on a downloaded update, in order; each failure names its step (also the usage event's failed_step).
enum UpdateVerify {
    enum Failure: Error, Equatable { case step(String, String) }   // step, message for the user

    static func sha256(of path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// The checksum for `name` in a SHA256SUMS.txt ("<hex>  <name>" per line).
    static func expected(in sums: String, for name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts.last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name { return String(parts[0]).lowercased() }
        }
        return nil
    }
    static var publicKey: String { Bundle.main.object(forInfoDictionaryKey: "ScrawlUpdatePublicKey") as? String ?? "" }
    static func signatureOK(file: String, signature: String, publicKey: String) -> Bool {
        guard let pk = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe) else { return false }
        return key.isValidSignature(sig, for: data)
    }
    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit(); return (p.terminationStatus, out)
    }

    /// Everything after the download: checksum, signature, then the app inside the DMG, copied to `stageAt` (which must
    /// not exist yet). Throws the first failing step; leaves nothing behind but a staged app on success.
    static func verifyAndStage(dmg: String, sums: String, sig: String?, dmgName: String, publicKey: String,
                               bundleId: String, current: String, stageAt: String) throws -> String {
        guard let want = expected(in: sums, for: dmgName) else { throw Failure.step("checksum", "The release has no checksum for \(dmgName).") }
        guard sha256(of: dmg) == want else { throw Failure.step("checksum", "The download doesn't match the release's checksum.") }
        guard let sig, !publicKey.isEmpty, signatureOK(file: dmg, signature: sig, publicKey: publicKey) else {
            throw Failure.step("signature", "The download isn't signed by Scrawl's release key.")
        }
        let mnt = NSTemporaryDirectory() + "scrawl-update-mnt-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: mnt, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mnt, dmg]).0 == 0 else {
            throw Failure.step("dmg", "The disk image couldn't be opened.")
        }
        defer { run("/usr/bin/hdiutil", ["detach", "-quiet", mnt]); try? FileManager.default.removeItem(atPath: mnt) }
        guard let appName = (try? FileManager.default.contentsOfDirectory(atPath: mnt))?.first(where: { $0.hasSuffix(".app") }) else {
            throw Failure.step("bundle", "There's no app in the disk image.")
        }
        let app = mnt + "/" + appName
        let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == bundleId else { throw Failure.step("bundle", "The app in the update isn't Scrawl.") }
        let v = info["CFBundleShortVersionString"] as? String ?? ""
        guard UpdateChecker.isNewer(v, than: current) else { throw Failure.step("version", "The update (\(v)) isn't newer than this version (\(current)).") }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]).0 == 0 else { throw Failure.step("codesign", "The app's code signature doesn't check out.") }
        guard run("/usr/bin/ditto", [app, stageAt]).0 == 0 else {
            try? FileManager.default.removeItem(atPath: stageAt)
            throw Failure.step("stage", "The new version couldn't be copied next to this one.")
        }
        return v
    }
}

/// Where the app is and whether it can replace itself there.
enum UpdateLocation {
    static var bundle: String { Bundle.main.bundlePath }
    /// /Applications, or (tests only, with their own data folder) SCRAWL_UPDATE_APPS_DIR.
    static var appsDir: String {
        if AppPaths.override != nil, let d = ProcessInfo.processInfo.environment["SCRAWL_UPDATE_APPS_DIR"] { return d }
        return "/Applications"
    }
    /// Nil if the app can update itself; otherwise why not.
    static func problem() -> String? {
        let dir = (bundle as NSString).deletingLastPathComponent
        guard (dir as NSString).standardizingPath == (appsDir as NSString).standardizingPath else {
            return "Scrawl can only update itself when it's in your Applications folder (it's running from \(dir))."
        }
        guard FileManager.default.isWritableFile(atPath: dir), FileManager.default.isWritableFile(atPath: bundle) else {
            return "Scrawl can't replace itself in \(dir) (no permission to write there)."
        }
        return nil
    }
    static var staged: String { ((bundle as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".Scrawl-update.app") }
    /// Remove a staged copy and make LaunchServices forget it (Spotlight registers it while it waits in the folder).
    static func discardStaged() {
        try? FileManager.default.removeItem(atPath: staged)
        forget(staged)
    }
    /// lsregister -u for a path that may be gone: LaunchServices matches a missing bundle only by its resolved path
    /// (/private/tmp, not /tmp), so resolve the folder it was in.
    static func forget(_ path: String) {
        let p = ((path as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath + "/" + (path as NSString).lastPathComponent
        UpdateVerify.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", p])
    }
}

/// Downloads one file to a temp folder, with progress and cancel.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private let progress: (Double) -> Void
    private let done: (Result<String, UpdateVerify.Failure>) -> Void
    private var finished = false

    init(_ url: URL, progress: @escaping (Double) -> Void, done: @escaping (Result<String, UpdateVerify.Failure>) -> Void) {
        self.progress = progress; self.done = done
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("TrackpadDraw/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        task = session.downloadTask(with: req)
        task?.resume()
    }
    func cancel() { finish(.failure(.step("cancelled", "Download cancelled."))); task?.cancel() }

    private func finish(_ r: Result<String, UpdateVerify.Failure>) {
        guard !finished else { return }
        finished = true; done(r); session.finishTasksAndInvalidate()
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        if e > 0 { progress(Double(w) / Double(e)) }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { finish(.failure(.step("download", "The download failed (the server answered \(status))."))); return }
        let expected = t.response?.expectedContentLength ?? -1
        if expected > 0, t.countOfBytesReceived != expected { finish(.failure(.step("download", "The download was incomplete."))); return }
        let dir = NSTemporaryDirectory() + "scrawl-update-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = dir + "/" + (t.originalRequest?.url?.lastPathComponent ?? "update.dmg")
        do { try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: dest)); finish(.success(dest)) }
        catch { finish(.failure(.step("download", "The download couldn't be saved."))) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(.step("download", (error as NSError).code == NSURLErrorCancelled ? "Download cancelled." : "The download failed (\(error.localizedDescription))."))) }
    }
}

/// The swap: a shell helper that outlives the app. Waits for this process to quit, moves the app aside, moves the
/// staged one in, registers it and opens it; if the new version doesn't write its "started" marker within 20 s, it
/// puts the old app back and opens that.
enum UpdateInstaller {
    static var markerPath: String { AppPaths.logsDir + "/update-started" }
    static var pendingPath: String { AppPaths.logsDir + "/update-pending" }
    static var logPath: String { AppPaths.logsDir + "/update.log" }

    /// At launch: if an update is waiting to be confirmed, confirm it (the helper is watching for this file).
    static func confirmIfPending() {
        guard let want = try? String(contentsOfFile: pendingPath, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: pendingPath)
        try? "\(getpid()) \(AppInfo.version)".write(toFile: markerPath, atomically: true, encoding: .utf8)
        // The helper of the version we updated from may predate forgetting these (0.1.6's does): forget them here too.
        for p in [UpdateLocation.staged, UpdateLocation.bundle + ".old-update"] where !FileManager.default.fileExists(atPath: p) {
            UpdateLocation.forget(p)
        }
        NSLog("Scrawl: started after an update to \(want.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    static func script() -> String {
        #"""
        #!/bin/sh
        # Scrawl's update helper: <old pid> <app> <staged app> <new version> <marker> <log>
        PID=$1; APP=$2; STAGED=$3; VER=$4; MARKER=$5; LOG=$6
        LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }
        forget() { "$LS" -u "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1")" >/dev/null 2>&1; }   # a path that's gone (or moved) mustn't stay registered
        launch() { if [ -n "$TRACKPAD_DRAW_DATA" ]; then "$1/Contents/MacOS/TrackpadDraw" $LAUNCH_ARGS >/dev/null 2>&1 & else /usr/bin/open -n "$1"; fi; }
        i=0; while kill -0 "$PID" 2>/dev/null; do sleep 0.2; i=$((i+1)); [ $i -gt 600 ] && { say "old app still running after 120 s; update abandoned"; rm -rf "$STAGED"; forget "$STAGED"; exit 1; }; done
        BACKUP="$APP.old-update"
        rm -rf "$BACKUP"
        mv "$APP" "$BACKUP" || { say "couldn't move the old app aside"; rm -rf "$STAGED"; forget "$STAGED"; launch "$APP"; exit 1; }
        if ! mv "$STAGED" "$APP"; then say "couldn't move the new app in; old one back"; mv "$BACKUP" "$APP"; forget "$BACKUP"; launch "$APP"; exit 1; fi
        forget "$STAGED"; forget "$BACKUP"
        "$LS" -f "$APP" >/dev/null 2>&1
        rm -f "$MARKER"
        launch "$APP"
        i=0; while [ $i -lt 100 ]; do [ -f "$MARKER" ] && grep -q " $VER\$" "$MARKER" && break; sleep 0.2; i=$((i+1)); done
        if [ -f "$MARKER" ] && grep -q " $VER\$" "$MARKER"; then say "updated to $VER"; rm -rf "$BACKUP"; forget "$BACKUP"; exit 0; fi
        say "the new version ($VER) didn't start; putting the old one back"
        pkill -f "$APP/Contents/MacOS/TrackpadDraw" 2>/dev/null
        rm -rf "$APP"; mv "$BACKUP" "$APP"; forget "$BACKUP"; "$LS" -f "$APP" >/dev/null 2>&1
        launch "$APP"
        exit 1
        """#
    }

    /// Start the helper, mark the update pending, and quit normally (the notebook saves on the way out).
    static func restart(into version: String, launchArgs: [String] = []) throws {
        AppPaths.ensure()
        let dir = NSTemporaryDirectory() + "scrawl-update-helper-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sh = dir + "/update.sh"
        try script().write(toFile: sh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh)
        try version.write(toFile: pendingPath, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [sh, String(getpid()), UpdateLocation.bundle, UpdateLocation.staged, version, markerPath, logPath]
        // A copy run with its own data folder is relaunched with the arguments it was started with (e.g. -analyticsEnabled NO).
        let args = launchArgs.isEmpty && AppPaths.override != nil ? Array(CommandLine.arguments.dropFirst()) : launchArgs
        var env = ProcessInfo.processInfo.environment; env["LAUNCH_ARGS"] = args.joined(separator: " ")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
    }
}

/// The update sheet: what's new, then download with progress, then Restart to Update.
final class UpdatePanel: NSObject {
    enum State: Equatable { case offer, downloading, verifying, ready, failed(String), unsupported(String) }
    let release: UpdateRelease
    let window: NSPanel
    private let title = NSTextField(labelWithString: ""), status = NSTextField(wrappingLabelWithString: "")
    private let notes = NSTextView(), bar = NSProgressIndicator()
    private let primary = NSButton(title: "Download and Install", target: nil, action: nil)
    private let secondary = NSButton(title: "Later", target: nil, action: nil)
    private(set) var state: State = .offer { didSet { layoutState(); onState?(state) } }
    private var download: UpdateDownload?
    private(set) var downloadsStarted = 0
    var onState: ((State) -> Void)?
    var onFinished: ((_ installed: Bool, _ failedStep: String?) -> Void)?
    var launchArgsForRestart: [String] = []

    init(release: UpdateRelease) {
        self.release = release
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let v = NSView(frame: window.contentRect(forFrameRect: window.frame)); window.contentView = v
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.stringValue = "Scrawl \(release.version) is available"
        title.frame = NSRect(x: 20, y: 316, width: 420, height: 22)
        status.frame = NSRect(x: 20, y: 280, width: 420, height: 32)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 100, width: 420, height: 172))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        notes.isEditable = false; notes.font = .systemFont(ofSize: 12); notes.textContainerInset = NSSize(width: 6, height: 6)
        notes.string = release.notes.isEmpty ? "No release notes." : release.notes
        notes.autoresizingMask = [.width]; notes.frame = scroll.contentView.bounds
        scroll.documentView = notes
        bar.frame = NSRect(x: 20, y: 66, width: 420, height: 20); bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
        primary.frame = NSRect(x: 260, y: 16, width: 180, height: 32); primary.bezelStyle = .rounded; primary.keyEquivalent = "\r"
        primary.target = self; primary.action = #selector(primaryClicked)
        secondary.frame = NSRect(x: 150, y: 16, width: 104, height: 32); secondary.bezelStyle = .rounded
        secondary.target = self; secondary.action = #selector(secondaryClicked)
        for x in [title, status, scroll, bar, primary, secondary] as [NSView] { v.addSubview(x) }
        if let why = UpdateLocation.problem() { state = .unsupported(why) } else { layoutState() }
    }

    private func layoutState() {
        bar.isHidden = true; primary.isEnabled = true; secondary.isEnabled = true
        switch state {
        case .offer:
            status.stringValue = "You have \(AppInfo.version). Your notebook stays as it is; Scrawl restarts once to finish."
            primary.title = "Download and Install"; secondary.title = "Later"
        case .downloading:
            status.stringValue = "Downloading…"; bar.isHidden = false
            primary.title = "Download and Install"; primary.isEnabled = false; secondary.title = "Cancel"
        case .verifying:
            status.stringValue = "Checking the download…"; bar.isHidden = false; bar.doubleValue = 1
            primary.isEnabled = false; secondary.isEnabled = false
        case .ready:
            status.stringValue = "Scrawl \(release.version) is ready. Scrawl will quit (your notebook is saved) and open again."
            primary.title = "Restart to Update"; secondary.title = "Later"
        case .failed(let why):
            status.stringValue = why + " Nothing was changed."
            primary.title = "Open Release Page"; secondary.title = "Close"
        case .unsupported(let why):
            status.stringValue = why
            primary.title = "Open Release Page"; secondary.title = "Close"
        }
    }

    @objc func primaryClicked() {
        switch state {
        case .offer: startDownload()
        case .ready: restart()
        case .failed, .unsupported:
            if let u = URL(string: release.page) { NSWorkspace.shared.open(u) }
            window.close()
        default: break
        }
    }
    @objc func secondaryClicked() {
        if state == .downloading { download?.cancel(); return }
        if state == .ready { UpdateLocation.discardStaged() }
        window.close()
    }

    /// Download and Install: once only (a second click while it runs does nothing).
    func startDownload() {
        guard state == .offer else { return }
        guard let dmg = release.dmg, let sumsURL = release.sums else { fail("download", "The release has no disk image to install."); return }
        downloadsStarted += 1
        state = .downloading; bar.doubleValue = 0
        download = UpdateDownload(dmg, progress: { [weak self] p in self?.bar.doubleValue = p }) { [weak self] r in
            guard let self else { return }
            self.download = nil
            switch r {
            case .failure(.step(let step, let msg)): self.fail(step, msg)
            case .success(let path): self.verify(path, sumsURL: sumsURL)
            }
        }
    }
    private func fetchText(_ u: URL?) -> String? {
        guard let u else { return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("TrackpadDraw/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        var out: String?; let sem = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200, let d { out = String(data: d, encoding: .utf8) }
            sem.signal()
        }.resume()
        sem.wait(); return out
    }
    private func verify(_ dmg: String, sumsURL: URL) {
        state = .verifying
        let rel = release, key = UpdateVerify.publicKey, bundleId = Bundle.main.bundleIdentifier ?? "", current = AppInfo.version
        let stage = UpdateLocation.staged
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<String, UpdateVerify.Failure>
            if let sums = self?.fetchText(sumsURL) {
                let sig = self?.fetchText(rel.sig)
                try? FileManager.default.removeItem(atPath: stage)
                do { result = .success(try UpdateVerify.verifyAndStage(dmg: dmg, sums: sums, sig: sig, dmgName: rel.dmgName, publicKey: key, bundleId: bundleId, current: current, stageAt: stage)) }
                catch let e as UpdateVerify.Failure { result = .failure(e) }
                catch { result = .failure(.step("stage", "\(error)")) }
            } else { result = .failure(.step("checksum", "The release's checksums couldn't be downloaded.")) }
            try? FileManager.default.removeItem(atPath: (dmg as NSString).deletingLastPathComponent)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.state = .ready
                case .failure(.step(let step, let msg)): self.fail(step, msg)
                }
            }
        }
    }
    private func fail(_ step: String, _ msg: String) {
        UpdateLocation.discardStaged()
        state = .failed(msg)
        onFinished?(false, step)
    }
    func restart() {
        guard state == .ready else { return }
        onFinished?(true, nil)
        do { try UpdateInstaller.restart(into: release.version, launchArgs: launchArgsForRestart) }
        catch { fail("install", "The update couldn't start (\(error.localizedDescription)).") }
    }
    func show() { window.center(); window.orderFrontRegardless() }
}
