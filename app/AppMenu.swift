// Menu bar, About box, the Check for Updates alert, diagnostics and touch-input switches.
import AppKit

// MARK: - Menus

extension AppDelegate {
    func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(); let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            top.submenu = m; main.addItem(top)
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.target = target ?? self
            return i
        }
        let name = AppInfo.name
        menu(name, [
            item("About \(name)", #selector(showAbout)),
            item("Check for Updates…", #selector(checkForUpdates)),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        menu("File", [
            item("New Page", #selector(newPageAction), "n"),
            .separator(),
            item("Export All Pages as PDF…", #selector(exportPDF), "e"),
            item("Export Page as PNG…", #selector(exportPNG), "e", [.command, .shift]),
        ])
        menu("Edit", [
            item("Undo", #selector(undo), "z"),
            item("Redo", #selector(redoAction), "z", [.command, .shift]),
            .separator(),
            item("Clear Page", #selector(clearPage), "\u{8}"),
        ])
        let basic = item("Use Basic Touch Input (no pressure)", #selector(toggleBasicInput))
        basic.state = Settings().inputSource == "nstouch" ? .on : .off
        menu("View", [
            item("Draw Mode  (⌃⌥D, Esc to leave)", #selector(toggleDrawModeAction)),   // the global hotkey owns ⌃⌥D
            item("Writing Mode  (W)", #selector(toggleWritingAction)),
            item("Zoom Lock  (L)", #selector(toggleZoomLockAction)),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command], target: window),
            item("Pages Overview  (G)", #selector(toggleGalleryAction)),
            item("Zoom to Whole Page", #selector(resetZoom), "0"),
            item("Previous Page", #selector(prevPageAction), "["),
            item("Next Page", #selector(nextPageAction), "]"),
            .separator(),
            basic,
        ])
        menu("Tools", [
            item("Pen  (P)", #selector(penAction)),
            item("Marker  (M)", #selector(markerAction)),
            item("Highlighter  (H)", #selector(highlighterAction)),
            item("Eraser  (E)", #selector(eraserAction)),
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: window),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: window),
        ])
        let diag = item("Record Touch Diagnostics", #selector(toggleDiagnostics))
        diag.state = Diagnostics.enabled ? .on : .off
        menu("Help", [
            item("\(name) Help", #selector(showHelp), "?"),
            item("Keyboard Shortcuts", #selector(showHelp)),
            .separator(),
            diag,
            item("Show Logs in Finder", #selector(showLogs)),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.first { $0.submenu?.title == "Window" }?.submenu
        NSApp.helpMenu = main.items.last?.submenu
    }

    var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let credits = """
        Write and sketch with a finger on your trackpad.
        Uses Apple's private MultitouchSupport framework for touch pressure, with the public touch API as a fallback.
        Your pages stay on this Mac.
        MIT License.
        """
        return [.applicationName: AppInfo.name, .applicationVersion: AppInfo.version, .version: "build \(AppInfo.build)",
                .credits: NSAttributedString(string: credits, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])]
    }
    @objc func showAbout() { exitDrawMode("about"); NSApp.orderFrontStandardAboutPanel(options: aboutOptions); NSApp.activate(ignoringOtherApps: true) }

    @objc func checkForUpdates() {
        exitDrawMode("updates")
        UpdateChecker.check { [weak self] r in self?.showUpdateResult(r) }
    }
    func showUpdateResult(_ r: UpdateChecker.Result) {
        let a = NSAlert()
        switch r {
        case .upToDate(let v): a.messageText = "You're up to date"; a.informativeText = "\(AppInfo.name) \(v) is the latest version."
        case .available(let v, _): a.messageText = "\(AppInfo.name) \(v) is available"; a.informativeText = "You have \(AppInfo.version). Open the release page to download it."
            a.addButton(withTitle: "Open Release Page"); a.addButton(withTitle: "Later")
        case .failed(let why): a.messageText = "Couldn't check for updates"; a.informativeText = why
        }
        if a.runModal() == .alertFirstButtonReturn, case .available(_, let page) = r, let u = URL(string: page) { NSWorkspace.shared.open(u) }
    }

    @objc func toggleDiagnostics(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!Diagnostics.enabled, forKey: "diagnosticLogs")
        sender.state = Diagnostics.enabled ? .on : .off
    }
    @objc func showLogs() { AppPaths.ensure(); NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.logsDir)) }
    @objc func toggleBasicInput(_ sender: NSMenuItem) {
        let basic = Settings().inputSource != "nstouch"
        UserDefaults.standard.set(basic ? "nstouch" : "mt", forKey: "inputSource")
        sender.state = basic ? .on : .off
        let a = NSAlert(); a.messageText = "Reopen \(AppInfo.name) to switch touch input"
        a.informativeText = basic ? "Basic touch input uses only public macOS APIs. There's no pressure: line width follows speed."
                                  : "Full touch input adds pressure (MultitouchSupport)."
        a.runModal()
    }
    @objc func toggleWritingAction() { apply(.writing, from: "menu") }

    /// ⌘[ / ⌘] are disabled (so the shortcuts do nothing) when the page arrows are dimmed.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // The mode items show a checkmark while their mode is on.
        if item.action == #selector(toggleDrawModeAction) { item.state = canvas.drawMode ? .on : .off }
        if item.action == #selector(toggleWritingAction) { item.state = canvas.writingMode ? .on : .off }
        if item.action == #selector(toggleZoomLockAction) { item.state = canvas.tools.zoomLocked ? .on : .off }
        let tools: [Selector: ToolKind] = [#selector(penAction): .pen, #selector(markerAction): .marker, #selector(highlighterAction): .highlighter, #selector(eraserAction): .eraser]
        if let a = item.action, let k = tools[a] { item.state = canvas.tools.tool == k ? .on : .off }
        if item.action == #selector(prevPageAction) { return canvas.pageIndex > 0 && !galleryShown }
        if item.action == #selector(nextPageAction) { return canvas.pageIndex < canvas.pages.count - 1 && !galleryShown }
        return true
    }
}
