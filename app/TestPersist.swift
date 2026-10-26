// --test-persist write|read|stream|bigsave: the notebook survives a crash or kill -9. Always run with
// TRACKPAD_DRAW_DATA=<scratch dir> (the notebook is never touched otherwise). checks/persist.sh drives it.
//   write   : draw on 2 pages through the real input path, undo once, change page 2's view, wait for
//             the autosave, record what's expected, then start a stroke and stay mid-stroke (crash
//             with --crash, or wait for the script's kill -9).
//   stream  : keep writing a stroke every 0.12 s, logging each commit time, until killed.
//   bigsave : 2,500 strokes, then save over and over until killed (atomic write under kill -9).
//   read    : report what the reopened notebook holds.
import AppKit
import CryptoKit

enum TestPersist {
    static var dir: String { AppPaths.dataDir }

    /// What a notebook holds, for comparing before the crash with after reopening.
    static func summary(_ canvas: CanvasView) -> [String: Any] {
        var f = canvas.notebookFile(); f.appVersion = ""
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        let hash = SHA256.hash(data: (try? e.encode(f)) ?? Data()).map { String(format: "%02x", $0) }.joined()
        return ["pages": f.pages.map { ["strokes": $0.strokes.count, "undo": $0.undo.count, "redo": $0.redo.count, "zoom": $0.zoom] },
                "pageIndex": f.pageIndex, "strokeTable": f.strokes.count, "points": f.strokes.reduce(0) { $0 + $1.points.count / 12 },
                "sha256": hash]
    }
    static func write(_ obj: Any, _ name: String) {
        try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/" + name))
    }

    /// Feeds touch frames in real time (8 ms apart) through Multitouch.onFrame, like the trackpad.
    final class Pen {
        let canvas: CanvasView
        var id: Int32 = 40000
        var t = 0.0
        init(canvas: CanvasView) { self.canvas = canvas }
        func frame(_ mm: CGPoint?, p: Double = 30) {
            t += 0.008
            let pad = Multitouch.padMM
            let cs = mm.map { [Contact(id: id, state: 4, norm: CGPoint(x: $0.x / pad.width, y: $0.y / pad.height), mm: $0, pressure: p, size: 0.5, major: 7.5)] } ?? []
            canvas.handle(cs, arrival: CACurrentMediaTime(), sensorT: t)
        }
        /// One wavy stroke, frames 8 ms apart on the main queue, then `then`.
        func stroke(at y: Double, x0: Double, len: Int = 40, lift: Bool = true, then: @escaping () -> Void) {
            var k = 0
            func step() {
                if k <= len {
                    frame(CGPoint(x: x0 + Double(k) * 0.5, y: y + sin(Double(k) / 5) * 3)); k += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.008, execute: step)
                } else if lift {
                    for _ in 0..<3 { frame(nil) }
                    id += 1; then()
                } else { then() }
            }
            step()
        }
        func strokes(_ n: Int, y0: Double, then: @escaping () -> Void) {
            guard n > 0 else { then(); return }
            stroke(at: y0, x0: 15 + Double(n % 4) * 25) { self.strokes(n - 1, y0: y0 + 4, then: then) }
        }
    }

    /// Until the autosave has written every change so far (on its own timer: nothing forces it).
    /// Gives up after 5 s (a broken autosave then fails the check instead of hanging it).
    static func waitForSave(_ canvas: CanvasView, deadline: Double = CACurrentMediaTime() + 5, then: @escaping () -> Void) {
        let a = canvas.autosaver
        if (a.changes > 0 && a.savedThrough == a.changes) || CACurrentMediaTime() > deadline { then() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForSave(canvas, deadline: deadline, then: then) } }
    }

    static func run(_ mode: String, canvas: CanvasView, app: AppDelegate) {
        let pen = Pen(canvas: canvas)
        switch mode {
        case "write":
            app.enterDrawMode(lock: false)
            pen.strokes(6, y0: 15) {
                canvas.undo()
                canvas.newPage()
                var t = canvas.tools; t.tool = .highlighter; canvas.tools = t
                pen.strokes(3, y0: 30) {
                    t.tool = .pen; canvas.tools = t
                    canvas.setVisibleForReplay(x: 300, y: 200, w: 600, z: 2.5)
                    if Launch.args.contains("--quit") {   // one more stroke, then quit at once: the quit saves it
                        pen.stroke(at: 70, x0: 20) {
                            write(summary(canvas), "expected.json")
                            NSApp.terminate(nil)
                        }
                        return
                    }
                    waitForSave(canvas) {
                        do {
                            write(summary(canvas), "expected.json")
                            try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/before.png"), pxPerUnit: 1)
                            // Finger down, ink on the page, never lifted.
                            pen.stroke(at: 60, x0: 20, len: 60, lift: false) {
                                write(["inFlightPoints": canvas.liveStrokePointCountForTest], "midstroke.json")
                                if Launch.args.contains("--crash") {
                                    TestCrash.now()
                                }
                                // Otherwise hold the finger down until the script's kill -9.
                                Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in pen.frame(CGPoint(x: 50, y: 60)) }
                            }
                        }
                    }
                }
            }
        case "stream":
            app.enterDrawMode(lock: false)
            let fh = FileHandle(forWritingAtPath: { let p = dir + "/commits.log"; FileManager.default.createFile(atPath: p, contents: nil); return p }())!
            var n = 0
            func next() {
                pen.stroke(at: 10 + Double(n % 12) * 5, x0: 15 + Double(n % 5) * 18, len: 14) {
                    n += 1
                    // Wall-clock time of each commit; written straight to the kernel, survives kill -9.
                    fh.write(Data("\(n) \(Date().timeIntervalSince1970) \(canvas.doc.strokes.count)\n".utf8))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: next)
                }
            }
            next()
        case "bigsave":
            for k in 0..<2500 {
                canvas.testAddStroke((0..<150).map { StrokePoint(p: CGPoint(x: Double(k % 50) * 30 + Double($0), y: 900 - Double(k / 50) * 15), pressure: 0.5) })
            }
            write(summary(canvas), "expected.json")
            canvas.autosaver.saveNow(sync: true)
            try? "ready".write(toFile: dir + "/bigsave-ready.txt", atomically: true, encoding: .utf8)
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in canvas.autosaver.saveNow(sync: false) }
        default:   // read
            var s = summary(canvas)
            s["loadStatus"] = app.notebookStatus
            s["previousCrash"] = app.previousCrash
            s["hint"] = app.container.hint.stringValue
            write(s, "actual.json")
            try? canvas.exportPNG(to: URL(fileURLWithPath: dir + "/after.png"), pxPerUnit: 1)
            try? "done".write(toFile: dir + "/ui-step.txt", atomically: true, encoding: .utf8)
        }
    }
}

/// A real crash for tests (an out-of-range index, SIGTRAP), without a "quit unexpectedly" dialog on
/// the user's screen: the process leaves the Dock and drops its crash-report exception port first.
enum TestCrash {
    /// No crash report and no "quit unexpectedly" dialog if this process crashes from now on (test runs only:
    /// a dialog would land on the screen of the person using the Mac).
    static func noReports() {
        // EXC_MASK_ALL incl. EXC_MASK_CORPSE_NOTIFY (the macros aren't imported into Swift)
        for mask in [0x3FFE, 0x1FFE] where task_set_exception_ports(mach_task_self_, exception_mask_t(mask), mach_port_t(MACH_PORT_NULL), EXCEPTION_DEFAULT, THREAD_STATE_NONE) == KERN_SUCCESS { break }
    }
    static func now() -> Never {
        NSApp.setActivationPolicy(.prohibited)
        noReports()
        let a: [Int] = []
        _ = a[Int(getpid()) > 0 ? 1 : 0]
        fatalError()
    }
}
