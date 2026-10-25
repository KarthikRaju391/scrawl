// Usage counts: which features get used, how long sessions last, whether people come back. Never ink, page
// images, text or file names: only event names and a few small, allow-listed numbers and words. It must
// never affect drawing:
//   record() only appends to a bounded in-memory queue under a tiny lock (drops the event when it's full);
//   a background queue writes batches to a local log (always, while on) and to a remote sink (only when an
//   app ID is set in release.conf) every 30 s and at quit, with capped backoff and no retry loops.
// Settings › Share anonymous usage counts turns it all off; off clears the queue and stops writing and sending.
// docs/analytics.md lists every event and the question it answers.
import Foundation
import CryptoKit
import os

struct AnalyticsEvent {
    var name: String
    var props: [String: String]
    var time: Date
}

/// Where batches go. Called on the analytics queue; return false if it should be tried again later.
protocol AnalyticsSink: AnyObject { func send(_ batch: [AnalyticsEvent], context: Analytics.Context) -> Bool }

final class Analytics: @unchecked Sendable {
    static let shared = Analytics()

    struct Context { var installID: String; var sessionID: String; var appVersion: String; var build: String; var macOS: String }

    /// The prop keys an event may carry, and nothing else (so ink, text or file names can't slip in).
    static let allowedKeys: Set<String> = ["source", "tool", "on", "kind", "steps", "count", "seconds", "pages", "strokes", "zoom", "tip", "step",
                                           "key", "format", "result", "category", "minutes", "words", "page"]
    static let maxQueue = 2000, maxString = 32

    // The queue: appended under an unfair lock (held for one append), drained in the background.
    private var lock = os_unfair_lock()
    private var buffer: [AnalyticsEvent] = []
    private(set) var dropped = 0
    private let work = DispatchQueue(label: "scrawl.analytics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var sinks: [AnalyticsSink] = []
    private var started = false
    /// Tests: which thread each sink call ran on.
    private(set) var sinkCallsOnMain = 0
    private(set) var context: Context

    private let store: UserDefaults?   // nil in test mode: nothing touches the real settings
    private var memory: [String: Any] = [:]
    private func get(_ k: String) -> Any? { store?.object(forKey: k) ?? memory[k] }
    private func set(_ k: String, _ v: Any) { if let store { store.set(v, forKey: k) } else { memory[k] = v } }

    init(testing: Bool = Launch.testing, defaults: UserDefaults = .standard, appID: String? = Bundle.main.object(forInfoDictionaryKey: "TDTelemetryAppID") as? String,
         flushInterval: Double = 30) {
        store = testing ? nil : defaults
        self.flushInterval = flushInterval
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        context = Context(installID: "", sessionID: UUID().uuidString, appVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
                          build: info["CFBundleVersion"] as? String ?? "0", macOS: "\(v.majorVersion)")
        if let id = get("analyticsInstallID") as? String { context.installID = id }
        else { let u = UUID().uuidString; set("analyticsInstallID", u); context.installID = u }
        sinks = [LocalLogSink(path: AppPaths.logsDir + "/events.jsonl")]
        if !testing, let appID, !appID.isEmpty { sinks.append(TelemetryDeckSink(appID: appID)) }
    }
    private let flushInterval: Double

    // MARK: on / off, and the first-launch notice

    var enabled: Bool {
        get { get("analyticsEnabled") as? Bool ?? true }
        set {
            set("analyticsEnabled", newValue)
            if !newValue { os_unfair_lock_lock(&lock); buffer.removeAll(); os_unfair_lock_unlock(&lock); work.async { [weak self] in self?.timer?.cancel(); self?.timer = nil; self?.started = false } }
        }
    }
    var noticeShown: Bool { get { get("analyticsNoticeShown") as? Bool ?? false } set { set("analyticsNoticeShown", newValue) } }
    static let noticeText = "Scrawl counts which features you use (like undo or writing mode) and how long you write, with a random ID that isn't tied to you. Never your ink, pages, text or file names. Turn it off any time in Settings."
    var hasRemote: Bool { sinks.contains { $0 is TelemetryDeckSink } }

    // MARK: recording (any thread, never blocks for more than an append)

    func record(_ name: String, _ props: [String: Any] = [:]) {
        guard enabled else { return }
        var clean: [String: String] = [:]
        for (k, v) in props where Self.allowedKeys.contains(k) {
            switch v {
            case let b as Bool: clean[k] = b ? "true" : "false"
            case let i as Int: clean[k] = String(i)
            case let d as Double where d.isFinite: clean[k] = String((d * 100).rounded() / 100)
            case let s as String where s.count <= Self.maxString: clean[k] = s
            default: break   // not a small scalar: dropped
            }
        }
        let e = AnalyticsEvent(name: String(name.prefix(Self.maxString)), props: clean, time: Date())
        os_unfair_lock_lock(&lock)
        if buffer.count < Self.maxQueue { buffer.append(e) } else { dropped += 1 }
        let start = !started; started = true
        os_unfair_lock_unlock(&lock)
        if start { work.async { [weak self] in self?.startTimer() } }   // lazily: nothing at launch
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume(); timer = t
    }
    /// Send what's queued soon (quit, going to the background); returns at once.
    func flushSoon() { work.async { [weak self] in self?.drain() } }
    /// At quit: drain and wait at most `timeout` (quitting, never drawing; a slow network just loses the batch).
    func flushBeforeQuit(timeout: Double = 0.5) {
        let done = DispatchSemaphore(value: 0)
        work.async { [weak self] in self?.drain(); done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
    /// Tests: drain now and wait for it (never on the drawing path).
    func flushAndWait() {   // async + wait: work.sync would run the drain on the calling thread
        let done = DispatchSemaphore(value: 0)
        work.async { [weak self] in self?.drain(); done.signal() }
        done.wait()
    }

    // MARK: the background side

    private var retry: [(batch: [AnalyticsEvent], sink: ObjectIdentifier, attempts: Int, next: Date)] = []
    static let maxAttempts = 6, maxPendingBatches = 5
    var clock: () -> Date = { Date() }
    private(set) var attempts = 0

    private func drain() {
        guard enabled else { return }
        os_unfair_lock_lock(&lock); let batch = buffer; buffer.removeAll(); os_unfair_lock_unlock(&lock)
        let now = clock()
        // Earlier failures whose time has come (backoff 30 s, 60 s, ... capped at an hour; dropped after 6 tries).
        var keep: [(batch: [AnalyticsEvent], sink: ObjectIdentifier, attempts: Int, next: Date)] = []
        for r in retry {
            guard let sink = sinks.first(where: { ObjectIdentifier($0) == r.sink }) else { continue }
            if r.next > now { keep.append(r); continue }
            attempts += 1
            if Thread.isMainThread { sinkCallsOnMain += 1 }
            if !sink.send(r.batch, context: context), r.attempts + 1 < Self.maxAttempts {
                keep.append((r.batch, r.sink, r.attempts + 1, now.addingTimeInterval(min(30 * pow(2, Double(r.attempts + 1)), 3600))))
            }
        }
        retry = Array(keep.suffix(Self.maxPendingBatches))
        guard !batch.isEmpty else { return }
        for sink in sinks {
            attempts += 1
            if Thread.isMainThread { sinkCallsOnMain += 1 }
            if !sink.send(batch, context: context) {
                retry.append((batch, ObjectIdentifier(sink), 1, now.addingTimeInterval(30)))
                retry = Array(retry.suffix(Self.maxPendingBatches))
            }
        }
    }
    /// Tests: swap the sinks (a fake that fails, one that records its thread).
    func setSinksForTest(_ s: [AnalyticsSink]) { work.sync { sinks = s; retry = [] } }
    var pendingRetries: Int { work.sync { retry.count } }
    var queued: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return buffer.count }
}

/// The local event log: JSON lines in ~/Library/Logs/Scrawl/events.jsonl, rotated at 1 MB (two files kept).
final class LocalLogSink: AnalyticsSink {
    let path: String
    static let maxBytes = 1_000_000
    init(path: String) { self.path = path }
    func send(_ batch: [AnalyticsEvent], context: Analytics.Context) -> Bool {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > Self.maxBytes {
            try? fm.removeItem(atPath: path + ".1"); try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return true }   // can't write: drop, never retry a disk
        defer { try? h.close() }
        h.seekToEndOfFile()
        let f = ISO8601DateFormatter()
        for e in batch {
            let d: [String: Any] = ["t": f.string(from: e.time), "event": e.name, "props": e.props, "session": context.sessionID, "v": context.appVersion]
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) { h.write(data); h.write(Data("\n".utf8)) }
        }
        return true
    }
}

/// TelemetryDeck's ingest API, as their Swift SDK sends it (github.com/TelemetryDeck/SwiftSDK,
/// Sources/TelemetryDeck/Signals/SignalManager.swift and Signal.swift, read 2026-10-26): POST a JSON array of
/// signals to https://nom.telemetrydeck.com/v2/ with Content-Type application/json; each signal has appID,
/// clientUser (hashed on the client; they salt and hash again), sessionID, type, payload ([String: String]),
/// isTestMode ("true"/"false") and receivedAt (ISO 8601). Only created when release.conf sets an app ID.
final class TelemetryDeckSink: AnalyticsSink {
    let appID: String
    static let endpoint = URL(string: "https://nom.telemetrydeck.com/v2/")!
    init(appID: String) { self.appID = appID }
    func send(_ batch: [AnalyticsEvent], context: Analytics.Context) -> Bool {
        let user = SHA256.hash(data: Data(context.installID.utf8)).map { String(format: "%02x", $0) }.joined()
        let f = ISO8601DateFormatter()
        let body: [[String: Any]] = batch.map { e in
            var payload = e.props
            payload["appVersion"] = context.appVersion; payload["build"] = context.build; payload["macOS"] = context.macOS
            return ["appID": appID, "clientUser": user, "sessionID": context.sessionID, "type": "Scrawl.\(e.name)",
                    "payload": payload, "isTestMode": "false", "receivedAt": f.string(from: e.time)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return true }
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = data
        // Synchronous on the analytics queue (never the main thread), bounded by the timeout.
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, err in
            ok = err == nil && ((resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false); done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return ok
    }
}
