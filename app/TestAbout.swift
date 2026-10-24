// --test-about [--check-updates] [--start-mt]: version, menus, About text, the update check (against
// TRACKPAD_DRAW_UPDATE_URL), and optionally whether MultitouchSupport loads in this build (hardened
// runtime). Writes test-about.json; checks/release.sh reads it.
import AppKit

enum TestAbout {
    static func run(app: AppDelegate) {
        let dir = AppPaths.dataDir
        var r: [String: Any] = ["version": AppInfo.version, "build": AppInfo.build, "bundleId": Bundle.main.bundleIdentifier ?? "",
                                "config": AppInfo.info("TDBuildConfig"), "diagnosticsEnabled": Diagnostics.enabled,
                                "updateURL": UpdateChecker.url?.absoluteString ?? "",
                                "welcomeWouldShow": !UserDefaults.standard.bool(forKey: "welcomed"),
                                "migrationRanInTest": UserDefaults.standard.object(forKey: Migration.doneKey) != nil || !app.migrationNotes.isEmpty]
        var menus: [[String: Any]] = []
        for top in NSApp.mainMenu?.items ?? [] {
            for i in top.submenu?.items ?? [] where !i.isSeparatorItem {
                let ok = i.action.map { a in (i.target as AnyObject?)?.responds(to: a) ?? NSApp.target(forAction: a) != nil } ?? false
                menus.append(["menu": top.submenu?.title ?? "", "title": i.title, "key": i.keyEquivalent,
                              "mods": i.keyEquivalent.isEmpty ? "" : modString(i.keyEquivalentModifierMask), "wired": ok])
            }
        }
        r["menus"] = menus
        r["about"] = app.aboutOptions.reduce(into: [String: String]()) { d, kv in
            d[kv.key.rawValue] = (kv.value as? NSAttributedString)?.string ?? "\(kv.value)"
        }
        if Launch.args.contains("--start-mt") {
            r["mtStart"] = Multitouch.start() ?? "ok"
            r["mtSummary"] = Multitouch.summary
        }
        func finish() {
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-about.json"))
            try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
        }
        guard Launch.args.contains("--check-updates") else { finish(); return }
        UpdateChecker.check(current: Launch.args.firstIndex(of: "--as-version").map { Launch.args[$0 + 1] } ?? AppInfo.version) { res in
            switch res {
            case .upToDate(let v): r["update"] = ["result": "upToDate", "version": v]
            case .available(let v, let p): r["update"] = ["result": "available", "version": v, "page": p]
            case .failed(let why): r["update"] = ["result": "failed", "why": why]
            }
            finish()
        }
    }
    static func modString(_ m: NSEvent.ModifierFlags) -> String {
        (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
    }
}
