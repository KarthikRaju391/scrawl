// --test-update: the in-app updater end to end, driven from the outside (checks/updater.sh): checks the update server
// (TRACKPAD_DRAW_UPDATE_URL), opens the sheet, presses its buttons as asked, and writes every state to
// <data>/update-state.json. --test-update-report (passed to the relaunched app): writes the running version and the
// notebook it opened to <data>/update-report.json, then quits. Development builds only.
#if !RELEASE
import AppKit

enum TestUpdate {
    static func run(app: AppDelegate) {
        let a = CommandLine.arguments, dir = AppPaths.dataDir
        func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        var log: [[String: Any]] = []
        func write(_ extra: [String: Any] = [:]) {
            var r: [String: Any] = ["version": AppInfo.version, "states": log]
            if let p = app.updatePanel { r["panelWindow"] = p.window.windowNumber; r["downloadsStarted"] = p.downloadsStarted }
            for (k, v) in extra { r[k] = v }
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/update-state.json"))
        }
        func note(_ s: String) { log.append(["t": CACurrentMediaTime(), "state": s]); write() }
        UpdateChecker.check { r in
            switch r {
            case .upToDate(let v): note("upToDate \(v)"); write(["done": true])
            case .failed(let why): note("checkFailed \(why)"); write(["done": true])
            case .available:
                app.showUpdateResult(r)
                guard let p = app.updatePanel else { note("noPanel"); write(["done": true]); return }
                p.launchArgsForRestart = ["--test-update-report"]
                p.onState = { s in
                    switch s {
                    case .offer: note("offer")
                    case .downloading: note("downloading")
                    case .verifying: note("verifying")
                    case .ready:
                        note("ready")
                        if a.contains("--update-restart") {
                            write(["restarting": true])
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { p.primaryClicked() }
                        } else { write(["done": true]) }
                    case .failed(let why): note("failed \(why)"); write(["done": true])
                    case .unsupported(let why): note("unsupported \(why)"); write(["done": true])
                    }
                }
                if case .unsupported(let why) = p.state { note("unsupported \(why)"); write(["done": true]); return }
                note("offer")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {   // a moment for the screenshot of the offer
                    p.primaryClicked()
                    if a.contains("--update-double") { p.primaryClicked(); p.primaryClicked() }
                    if let c = arg("--update-cancel-after").flatMap(Double.init) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + c) { p.secondaryClicked() }
                    }
                }
            }
        }
    }

    static func report(app: AppDelegate) {
        let c = app.canvas
        let r: [String: Any] = ["version": AppInfo.version, "pid": getpid(), "bundle": Bundle.main.bundlePath,
                                "pages": c.pages.count, "strokes": c.pages.reduce(0) { $0 + $1.strokes.count }]
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: AppPaths.dataDir + "/update-report.json"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    }
}
#endif
