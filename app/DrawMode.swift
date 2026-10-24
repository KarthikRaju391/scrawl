// Draw mode: frozen + hidden cursor, global hotkey, and making sure the cursor always comes back.
// Layers of cursor safety:
//   1. exit() on Esc, hotkey, app deactivation, window close, quit.
//   2. SIGTERM/SIGINT/SIGHUP -> exit() then terminate; crash signals -> best-effort re-associate.
//   3. A watchdog process (this binary with --watchdog <pid>) that re-associates the mouse and
//      shows the cursor when the app dies by any means, including kill -9.
// The window server also undoes a dead app's cursor hide; the watchdog covers association.
import AppKit
import Carbon.HIToolbox

enum CursorLock {
    nonisolated(unsafe) static var locked = false
    nonisolated(unsafe) static var savedLocation: CGPoint?
    /// TRACKPAD_DRAW_DRYLOCK: tests go through every lock/unlock/watchdog step but never touch the
    /// real cursor (the Mac may be in use). The CG calls are the only thing skipped.
    static let dry = ProcessInfo.processInfo.environment["TRACKPAD_DRAW_DRYLOCK"] != nil

    /// Freeze and hide the cursor at `at` (global display coordinates, top-left origin).
    static func lock(at: CGPoint) {
        guard !locked else { return }
        if !dry {
            savedLocation = CGEvent(source: nil)?.location
            CGWarpMouseCursorPosition(at)
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        }
        locked = true
        Watchdog.mark(locked: true)
        Watchdog.log("cursor locked\(dry ? " (dry run)" : "")")
    }

    static func unlock(reason: String = "exit") {
        guard locked else { return }
        if !dry {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            if let p = savedLocation { CGWarpMouseCursorPosition(p); CGAssociateMouseAndMouseCursorPosition(1) }
        }
        locked = false
        Watchdog.mark(locked: false)
        Watchdog.log("cursor restored: \(reason)\(dry ? " (dry run)" : "")")
    }
}

enum Watchdog {
    static var logPath: String { AppPaths.logsDir + "/watchdog.log" }
    static var statePath: String { NSTemporaryDirectory() + "trackpad-draw-\(getpid()).locked" }

    /// Marker file so the watchdog log can say whether the app died while locked.
    static func mark(locked: Bool) {
        if locked { FileManager.default.createFile(atPath: statePath, contents: nil) } else { try? FileManager.default.removeItem(atPath: statePath) }
    }

    static func spawn() {
        let p = Process()
        p.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--watchdog", "\(getpid())"]
        try? p.run()
    }

    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let fh = FileHandle(forWritingAtPath: logPath) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)) }
        else { FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8)) }
    }

    /// Entry point of the watchdog process. Never returns.
    static func run(parent: pid_t) -> Never {
        setsid()                       // own session: a Ctrl-C to the app's terminal doesn't kill us
        signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN)
        let lockedMarker = NSTemporaryDirectory() + "trackpad-draw-\(parent).locked"
        let src = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        src.setEventHandler {
            let wasLocked = FileManager.default.fileExists(atPath: lockedMarker)
            if !CursorLock.dry {
                CGAssociateMouseAndMouseCursorPosition(1)
                CGDisplayShowCursor(CGMainDisplayID())
            }
            try? FileManager.default.removeItem(atPath: lockedMarker)
            log("app pid \(parent) exited (locked=\(wasLocked)); re-associated mouse and showed cursor\(CursorLock.dry ? " (dry run)" : "")")
            exit(0)
        }
        src.resume()
        log("watching app pid \(parent)")
        if kill(parent, 0) != 0 { if !CursorLock.dry { CGAssociateMouseAndMouseCursorPosition(1) }; exit(0) }  // parent already gone
        dispatchMain()
    }
}

enum Signals {
    nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []

    static func install(onTerminate: @escaping () -> Void) {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { onTerminate() }
            s.resume()
            sources.append(s)
        }
        // Crashes: not async-signal-safe, best effort before the default handler runs.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { s in
                if !CursorLock.dry { CGAssociateMouseAndMouseCursorPosition(1) }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}

/// Global hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed).
enum HotKey {
    nonisolated(unsafe) static var action: (() -> Void)?
    nonisolated(unsafe) static var ref: EventHotKeyRef?

    /// Default ⌃⌥D.
    static func register(keyCode: UInt32 = UInt32(kVK_ANSI_D), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5444_5257), id: 1)  // 'TDRW'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
