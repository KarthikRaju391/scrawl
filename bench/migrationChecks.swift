// Trackpad Draw -> Scrawl: pages, logs and settings move over once; nothing is overwritten.
import Foundation

func migrationChecks(_ check: (Bool, String) -> Void) {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "td-migrate-\(getpid())"
    let sup = root + "/Application Support", logs = root + "/Logs"
    try? fm.removeItem(atPath: root)
    try! fm.createDirectory(atPath: sup + "/Trackpad Draw", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: logs + "/Trackpad Draw", withIntermediateDirectories: true)
    let pages = Data("notebook-bytes".utf8)
    fm.createFile(atPath: sup + "/Trackpad Draw/Notebook.tdnb", contents: pages)
    fm.createFile(atPath: logs + "/Trackpad Draw/watchdog.log", contents: Data("log".utf8))
    let suite = "bench.migrate.\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    // Old settings, as Karthik's dev build stored them (keys from Settings / ToolState).
    let old: [String: Any] = ["smoothing": 0.6, "predictMs": 14.0, "pauseBeforeMoveMs": 400.0, "welcomed": true,
                              "NSWindow Frame main": "0 0 100 100", "toolState": Data([1, 2, 3])]
    let notes = Migration.run(supportBase: sup, logsBase: logs, newFolder: "Scrawl", defaults: d, ownDomain: "com.karthikraju.scrawl",
                              readDomain: { $0 == "local.trackpad-draw" ? old : nil })
    let moved = fm.contents(atPath: sup + "/Scrawl/Notebook.tdnb") == pages && !fm.fileExists(atPath: sup + "/Trackpad Draw")
        && fm.fileExists(atPath: logs + "/Scrawl/watchdog.log")
    check(moved, "rename: pages and logs move from \"Trackpad Draw\" to \"Scrawl\" folders (\(notes.joined(separator: "; ")))")
    check(d.double(forKey: "smoothing") == 0.6 && d.double(forKey: "predictMs") == 14 && d.data(forKey: "toolState") == Data([1, 2, 3])
          && d.object(forKey: "welcomed") == nil && d.object(forKey: "NSWindow Frame main") == nil,
          "rename: settings copied; \"welcomed\" not copied, so the welcome window shows once under the new name")
    // Second launch: nothing happens; an old folder reappearing (old app run again) is not merged over the new one.
    try! fm.createDirectory(atPath: sup + "/Trackpad Draw", withIntermediateDirectories: true)
    fm.createFile(atPath: sup + "/Trackpad Draw/Notebook.tdnb", contents: Data("older".utf8))
    d.set(0.2, forKey: "smoothing")
    let again = Migration.run(supportBase: sup, logsBase: logs, newFolder: "Scrawl", defaults: d, ownDomain: "com.karthikraju.scrawl",
                              readDomain: { _ in old })
    check(again.isEmpty && fm.contents(atPath: sup + "/Scrawl/Notebook.tdnb") == pages && d.double(forKey: "smoothing") == 0.2,
          "rename: runs once; never overwrites the new pages or settings changed since")
    d.removePersistentDomain(forName: suite)
    try? fm.removeItem(atPath: root)
}
