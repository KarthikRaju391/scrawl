// What the app tells Analytics (docs/analytics.md has the list and why). Every call here is an append to an
// in-memory queue: nothing on the drawing path waits for it.
import AppKit

final class UsageState {
    let launchedAt = Date()
    var firstStrokeSent = false
    var strokesThisSpan = 0
    var spanStart: Date?
    var undoTimes: [Double] = []
    var burstCounted = false
    var manualNewLine = false
    var modeSource = "key"
}

extension AppDelegate {
    var usage: Analytics { Analytics.shared }

    /// From Canvas.act (every logged action).
    func usageAct(_ name: String, _ extra: [String: Any]) {
        let u = usageState
        switch name {
        case "commit":
            u.strokesThisSpan += 1
            if !u.firstStrokeSent { u.firstStrokeSent = true; usage.record("first_stroke", ["seconds": Int(Date().timeIntervalSince(u.launchedAt))]) }
        case "drawMode":
            let on = extra["on"] as? Bool ?? false
            usage.record("draw_mode", ["on": on, "source": u.modeSource]); u.modeSource = "key"
            if on { u.spanStart = Date(); u.strokesThisSpan = 0 }
            else if let s = u.spanStart {
                if u.strokesThisSpan == 0 { usage.record("draw_mode_empty", ["seconds": Int(Date().timeIntervalSince(s))]) }
                else { usage.record("strokes", ["count": u.strokesThisSpan]) }
                u.spanStart = nil
            }
        case "gestureUndo": usage.record("undo", ["source": "gesture"])
        case "gestureRedo": usage.record("redo", ["source": "gesture"])
        case "undo":
            let t = CACurrentMediaTime()
            u.undoTimes = u.undoTimes.filter { t - $0 < 2 } + [t]
            if u.undoTimes.count >= 3 && !u.burstCounted { u.burstCounted = true; usage.record("undo_burst", ["count": u.undoTimes.count]) }
            if u.undoTimes.count == 1 { u.burstCounted = false }
        case "scrubEnd": usage.record("undo_scrub", ["steps": extra["steps"] as? Int ?? 0])
        case "scratchOut": usage.record("scratch_out", ["strokes": (extra["ids"] as? [Int])?.count ?? 0])
        case "newLineByHand": u.manualNewLine = true
        case "newLine": usage.record("new_line", ["kind": u.manualNewLine ? "manual" : "auto"]); u.manualNewLine = false
        case "autoPan": usage.record("auto_pan")
        case "newPage": usage.record("new_page", ["pages": canvas.pages.count])
        case "resume": usage.record("resume")
        default: break
        }
    }

    /// A mode or tool changed through the shared rules (keys, toolbar, menu, hotkey).
    func usageMode(old: ModeState, new: ModeState, source: String) {
        usageState.modeSource = source
        if new.tool != old.tool { usage.record("tool", ["tool": new.tool.rawValue, "source": source]) }
        if new.writing != old.writing { usage.record("writing_mode", ["on": new.writing, "source": source]) }
        if new.locked != old.locked { usage.record("zoom_lock", ["on": new.locked, "source": source]) }
    }

    func usageLaunch() {
        usage.record("session_start")
        if previousCrash { usage.record("crash_detected") }
        if notebookStatus.hasPrefix("failed") || notebookStatus.contains("unreadable") { usage.record("error", ["category": "load_failed"]) }
    }
    func usageQuit() {
        usage.record("session_end", ["minutes": Int(Date().timeIntervalSince(usageState.launchedAt) / 60)])
        usage.flushBeforeQuit()
    }

    /// The one-time notice. New users read it in the welcome window; people updating get a small window once.
    func showUsageNoticeIfNeeded(firstRun: Bool) {
        guard !usage.noticeShown else { return }
        usage.noticeShown = true
        usage.record("notice_shown")
        guard !firstRun, !Launch.background else { return }   // the welcome window carries it
        let a = NSAlert()
        a.messageText = "Anonymous usage counts"
        a.informativeText = Analytics.noticeText
        a.addButton(withTitle: "Keep On"); a.addButton(withTitle: "Turn Off")
        a.beginSheetModal(for: window) { [weak self] r in
            if r == .alertSecondButtonReturn { self?.usage.enabled = false; self?.settingsWindow.refresh() }
        }
    }
}
