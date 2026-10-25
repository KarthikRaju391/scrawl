// Aim-first mode was removed in 0.1.0: settings saved by older builds still load, and it isn't saved again.
import Foundation

func aimRemovedChecks(_ check: (Bool, String) -> Void) {
    let suite = "bench.aim.\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    // As saved by a build with aim-first (shape of ToolState.save before 0.1.0).
    d.set(["tool": "marker", "background": 3, "lineWidthIndex": 2, "zoomLocked": true, "autoPan": 2, "aimFirst": true,
           "colorIndex": ["marker": 4], "sizeIndex": ["marker": 3]], forKey: "toolState")
    let t = ToolState.load(from: d)
    t.save(to: d)
    let saved = d.dictionary(forKey: "toolState") ?? [:]
    check(t.tool == .marker && t.background == 3 && t.lineWidthIndex == 2 && t.zoomLocked && t.autoPan == .left && saved["aimFirst"] == nil,
          "old settings with aimFirst load (tool, background, line width, zoom lock, pan mode kept) and aimFirst isn't saved again")
    d.removePersistentDomain(forName: suite)
}
