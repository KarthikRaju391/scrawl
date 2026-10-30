// --test-menus: every menu item as the app shows it (title, shortcut, enabled), on a page and with the overview's
// search field focused; ⌘A there selects its text and ⌘C becomes Copy (text). checks/menus.sh reads test-menus.json.
import AppKit

enum TestMenus {
    static func run(app: AppDelegate) {
        let dir = AppPaths.dataDir
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func waitTransition() { let d = Date().addingTimeInterval(8); spin(0.02); while app.transitionView != nil && Date() < d { spin(0.02) } }
        func dump() -> [[String: Any]] {
            var out: [[String: Any]] = []
            for top in NSApp.mainMenu?.items ?? [] {
                guard let m = top.submenu else { continue }
                m.update()
                for i in m.items where !i.isSeparatorItem {
                    var mods = ""
                    if i.keyEquivalentModifierMask.contains(.control) { mods += "⌃" }
                    if i.keyEquivalentModifierMask.contains(.option) { mods += "⌥" }
                    if i.keyEquivalentModifierMask.contains(.shift) { mods += "⇧" }
                    if i.keyEquivalentModifierMask.contains(.command) { mods += "⌘" }
                    let k = i.keyEquivalent == "\u{8}" ? "⌫" : i.keyEquivalent.uppercased()
                    out.append(["menu": m.title, "title": i.title, "key": i.keyEquivalent.isEmpty ? "" : mods + k, "enabled": i.isEnabled,
                                "on": i.state == .on, "action": i.action.map(NSStringFromSelector) ?? ""])
                }
            }
            return out
        }
        func cmd(_ ch: String) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                           characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 0) else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
        }
        var r: [String: Any] = [:]
        if app.canvas.drawMode { app.exitDrawMode("test") }
        app.window.makeFirstResponder(app.canvas)
        r["onPage"] = dump()
        let vm = NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu
        r["fullScreenItems"] = (vm?.items ?? []).filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
            .map { "\($0 === app.ownFullScreenItem ? "ours" : "system") key=\($0.keyEquivalent) mask=\($0.keyEquivalentModifierMask.rawValue)" }
        app.showGallery(); waitTransition()
        app.window.makeKey()   // what a person's click into the field does (the app stays in the background)
        r["keyWindowIsMain"] = NSApp.keyWindow === app.window
        app.gallery?.focusSearch(); spin(0.1)
        app.gallery?.search.stringValue = "hello world"
        if let t = app.window.firstResponder as? NSTextView { t.string = "hello world"; t.setSelectedRange(NSRange(location: 0, length: 0)) }
        r["inSearch"] = dump()
        // A background app has no key window, so the menu can't route to the field here: send each item's action to
        // the field editor, as AppKit does for the key window's first responder.
        let fe = app.window.firstResponder as? NSTextView
        let edit = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        r["editItems"] = (edit?.items ?? []).filter { ["cut:", "paste:", "selectAll:"].contains($0.action.map(NSStringFromSelector) ?? "") }
            .map { ["action": NSStringFromSelector($0.action!), "toFirstResponder": $0.target == nil, "fieldTakesIt": fe?.validateUserInterfaceItem($0) ?? false] }
        if let fe, let sa = edit?.items.first(where: { $0.action == #selector(NSText.selectAll(_:)) }) { NSApp.sendAction(sa.action!, to: fe, from: sa) }
        r["selectAllHandled"] = fe != nil
        r["selected"] = fe.map { NSStringFromRange($0.selectedRange()) } ?? "no field editor"
        app.dropSystemFullScreenItem()
        try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/test-menus.json"))
        try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
    }
}
