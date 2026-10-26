// Usage counts must never affect drawing: recording is an append, everything else runs on the analytics
// queue; a full queue drops instead of blocking; off means nothing is kept, written or sent; props are
// filtered to small allow-listed scalars; no remote sink without an app ID; a failing sink backs off and
// gives up instead of looping.
import Foundation

final class FakeSink: AnalyticsSink {
    var calls = 0, events = 0, onMain = 0, fail = false, stall = 0.0
    func send(_ batch: [AnalyticsEvent], context: Analytics.Context) -> Bool {
        if stall > 0 { Thread.sleep(forTimeInterval: stall) }
        calls += 1; events += batch.count; if Thread.isMainThread { onMain += 1 }
        return !fail
    }
}

func analyticsChecks(_ check: (Bool, String) -> Void) {
    // 1. The cost on the calling (main) thread: 100,000 events, per-call time, and no sink ran there.
    let a = Analytics(testing: true, appID: "", flushInterval: 0.05)
    let sink = FakeSink(); a.setSinksForTest([sink])
    var worst = 0.0, total = 0.0
    var samples: [Double] = []
    for i in 0..<100_000 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        a.record("strokeCommitted", ["tool": "pen", "count": i])
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        total += dt; worst = max(worst, dt); if i % 10 == 0 { samples.append(dt) }
    }
    samples.sort()
    let p99 = samples[Int(Double(samples.count) * 0.99)]
    a.flushAndWait()
    check(p99 < 5 && sink.onMain == 0 && a.sinkCallsOnMain == 0,
          String(format: "analytics: record() from the main thread costs p99 %.2f µs (mean %.2f, worst %.0f µs); the sink never ran on the calling thread (%d calls off it)", p99, total / 100_000, worst, sink.calls))
    check(a.dropped > 0 && sink.events + a.dropped >= 100_000 - Analytics.maxQueue,
          "analytics: a full queue drops events instead of blocking (\(a.dropped) dropped, \(sink.events) delivered)")

    // 2. A stalled sink doesn't slow recording.
    let b = Analytics(testing: true, appID: "", flushInterval: 0.01)
    let slow = FakeSink(); slow.stall = 0.3; b.setSinksForTest([slow])
    b.record("x"); b.flushSoon(); Thread.sleep(forTimeInterval: 0.05)
    let t0 = Date(); for _ in 0..<10_000 { b.record("y") }
    let ms = Date().timeIntervalSince(t0) * 1000
    check(ms < 20, String(format: "analytics: recording 10,000 events while the sink is stalled takes %.1f ms", ms))

    // 3. Off: the queue is cleared, nothing recorded or sent.
    let c = Analytics(testing: true, appID: "", flushInterval: 10)
    let cs = FakeSink(); c.setSinksForTest([cs])
    c.record("a"); c.record("b"); c.enabled = false; c.record("c"); c.flushAndWait()
    check(c.queued == 0 && cs.events == 0, "analytics: turning it off clears the queue and sends nothing (\(cs.events) sent)")

    // 4. Only small allow-listed scalars get through.
    let d = Analytics(testing: true, appID: "", flushInterval: 10)
    final class Capture: AnalyticsSink { var last: [AnalyticsEvent] = []; func send(_ b: [AnalyticsEvent], context: Analytics.Context) -> Bool { last += b; return true } }
    let cap = Capture(); d.setSinksForTest([cap])
    d.record("e", ["tool": "pen", "count": 3, "text": "my secret words", "file": "/Users/x/notes.pdf", "points": [1, 2, 3], "category": String(repeating: "x", count: 50), "on": true])
    d.flushAndWait()
    let props = cap.last.first?.props ?? [:]
    check(props == ["tool": "pen", "count": "3", "on": "true"], "analytics: unknown keys, arrays and long strings are dropped (kept \(props.keys.sorted()))")

    // 5. No remote sink without an app ID (and none in tests at all).
    check(!Analytics(testing: false, defaults: UserDefaults(suiteName: "scrawl.bench.analytics")!, appID: "", flushInterval: 10).hasRemote
          && Analytics(testing: false, defaults: UserDefaults(suiteName: "scrawl.bench.analytics")!, appID: "abc", flushInterval: 10).hasRemote,
          "analytics: the remote sink exists only when release.conf sets an app ID")
    UserDefaults().removePersistentDomain(forName: "scrawl.bench.analytics")

    // 6. A failing sink backs off (30 s, 60 s, ...) and gives up after 6 tries: no tight loop.
    let e = Analytics(testing: true, appID: "", flushInterval: 10)
    let bad = FakeSink(); bad.fail = true; e.setSinksForTest([bad])
    var now = Date(); e.clock = { now }
    e.record("x"); e.flushAndWait()
    for _ in 0..<200 { e.flushAndWait() }               // 200 drains at the same moment: no retries yet
    let early = bad.calls
    for _ in 0..<20 { now = now.addingTimeInterval(3600); e.flushAndWait() }
    check(early == 1 && bad.calls == Analytics.maxAttempts && e.pendingRetries == 0,
          "analytics: a failing sink is tried once, then backs off and gives up after \(Analytics.maxAttempts) tries (\(early) call in 200 immediate drains, \(bad.calls) in total)")
}

/// The PostHog body, as their SDK builds it: anonymous (no person profiles, no GeoIP), hashed ID, only the
/// filtered props. With POSTHOG_FIXTURE_URL set (checks/posthog.sh), also a real POST to a local server.
func postHogChecks(_ check: (Bool, String) -> Void) {
    let ctx = Analytics.Context(installID: "11111111-2222-3333-4444-555555555555", sessionID: "S1", appVersion: "0.1.0", build: "2", macOS: "26")
    let ev = [AnalyticsEvent(name: "undo", props: ["source": "gesture"], time: Date(timeIntervalSince1970: 1_800_000_000))]
    let b = PostHogSink.body(ev, context: ctx, token: "phc_test")
    let e = (b["batch"] as? [[String: Any]])?.first ?? [:]
    let p = e["properties"] as? [String: Any] ?? [:]
    let raw = String(data: (try? JSONSerialization.data(withJSONObject: b)) ?? Data(), encoding: .utf8) ?? ""
    check(b["api_key"] as? String == "phc_test" && e["event"] as? String == "undo" && (e["distinct_id"] as? String)?.count == 64
          && p["$process_person_profile"] as? Bool == false && p["$geoip_disable"] as? Bool == true && p["source"] as? String == "gesture"
          && e["timestamp"] is String && e["uuid"] is String && !raw.contains(ctx.installID),
          "PostHog: batch body as their SDK sends it; anonymous (no person profile, no GeoIP), hashed ID (raw install ID never sent)")
    if let url = ProcessInfo.processInfo.environment["POSTHOG_FIXTURE_URL"] {
        let ok = PostHogSink(token: "phc_test", host: url).send(ev, context: ctx)
        check(ok, "PostHog: a real POST to the local fixture server (\(url)) succeeds")
    }
}
