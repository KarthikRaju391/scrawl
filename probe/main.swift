// Phase 1 probe: what does this trackpad give us for stroke width?
// Logs three sources side by side to a JSONL file while a guided script runs:
//   nstouch  - public NSTouch (indirect) events on the view
//   pressure - public NSEvent pressure/stage (pressureChange)
//   mt       - private MultitouchSupport per-finger frames (total, pressure, density, axes)
// Build: ./build.sh   Run: ./probe-bin [out.jsonl]
import AppKit
import Darwin

// MARK: - Logger (thread-safe, JSONL)

final class Log {
    static let shared = Log()
    private let q = DispatchQueue(label: "log")
    private var fh: FileHandle?
    var step = "idle"
    var mouseDown = false
    let t0 = ProcessInfo.processInfo.systemUptime

    func open(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        fh = FileHandle(forWritingAtPath: path)
    }
    func write(_ src: String, _ fields: [String: Any]) {
        let now = ProcessInfo.processInfo.systemUptime - t0
        q.async {
            var d = fields
            d["src"] = src; d["t"] = now; d["step"] = self.step; d["down"] = self.mouseDown
            if let data = try? JSONSerialization.data(withJSONObject: d), let fh = self.fh {
                fh.write(data); fh.write("\n".data(using: .utf8)!)
            }
        }
    }
    func flush() { q.sync { try? fh?.synchronize() } }
}

// MARK: - MultitouchSupport (private, loaded with dlopen; layout from OpenMultitouchSupport)

struct MTPoint { var x: Float; var y: Float }
struct MTVector { var position: MTPoint; var velocity: MTPoint }
struct MTTouch {
    var frame: Int32; var timestamp: Double; var identifier: Int32; var state: Int32
    var fingerId: Int32; var handId: Int32; var normalized: MTVector
    var total: Float; var pressure: Float; var angle: Float; var majorAxis: Float; var minorAxis: Float
    var absolute: MTVector; var field14: Int32; var field15: Int32; var density: Float
}
// Touches arrive as a raw pointer (Swift structs aren't C-representable); same layout as the C struct, stride 96.
typealias MTFrameCB = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

let mtCallback: MTFrameCB = { _, raw, n, ts, frame in
    guard let raw else { Log.shared.write("mt", ["n": 0, "ts": ts, "frame": frame]); return }
    let touches = raw.assumingMemoryBound(to: MTTouch.self)
    var fingers: [[String: Any]] = []
    for i in 0..<Int(n) {
        let t = touches[i]
        fingers.append([
            "id": t.identifier, "state": t.state, "finger": t.fingerId,
            "x": t.normalized.position.x, "y": t.normalized.position.y,
            "vx": t.normalized.velocity.x, "vy": t.normalized.velocity.y,
            "total": t.total, "pressure": t.pressure, "density": t.density,
            "major": t.majorAxis, "minor": t.minorAxis, "angle": t.angle,
            "ax": t.absolute.position.x, "ay": t.absolute.position.y,
            "f14": t.field14, "f15": t.field15,
        ])
    }
    // Physical button state from the window server, so passive listening also knows click vs no click.
    let btn = CGEventSource.buttonState(.combinedSessionState, button: .left)
    Log.shared.write("mt", ["n": n, "ts": ts, "frame": frame, "f": fingers, "btn": btn])
}

func startMT() -> String {
    precondition(MemoryLayout<MTTouch>.stride == 96, "MTTouch layout mismatch")
    guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
        return "dlopen failed"
    }
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer?, MTFrameCB) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias Dims = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias BuiltIn = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    guard let createList = sym("MTDeviceCreateList", CreateList.self),
          let register = sym("MTRegisterContactFrameCallback", Register.self),
          let start = sym("MTDeviceStart", Start.self),
          let list = createList()?.takeRetainedValue() else { return "symbols missing" }
    let dims = sym("MTDeviceGetSensorSurfaceDimensions", Dims.self)
    let builtIn = sym("MTDeviceIsBuiltIn", BuiltIn.self)
    var out: [String] = []
    for i in 0..<CFArrayGetCount(list) {
        let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))
        var w: Int32 = 0, hgt: Int32 = 0
        _ = dims?(dev, &w, &hgt)
        let bi = builtIn?(dev) ?? false
        register(dev, mtCallback)
        let rc = start(dev, 0)
        out.append("dev\(i) builtIn=\(bi) surface=\(w)x\(hgt) (1/100 mm) start=\(rc)")
        Log.shared.write("mtdevice", ["i": i, "builtIn": bi, "w": w, "h": hgt, "start": rc])
    }
    return out.joined(separator: "; ")
}

// MARK: - Guided script

struct Step { let key: String; let text: String; let secs: Double }
let steps: [Step] = [
    Step(key: "rest_light", text: "Rest ONE fingertip lightly on the trackpad. Don't move, don't click.", secs: 5),
    Step(key: "press_noclick", text: "Same finger: press slowly harder, up to just BEFORE it clicks. Then ease off. Repeat. No click.", secs: 8),
    Step(key: "click_deep", text: "Click and HOLD, then press deeper (force click) and back, a few times.", secs: 8),
    Step(key: "flat_vs_tip", text: "Alternate: fingertip (2s) → flat finger pad (2s) → fingertip. Light touch, no click.", secs: 8),
    Step(key: "draw_slow_fast", text: "Draw with one finger, no click: a few SLOW strokes, then FAST strokes.", secs: 8),
    Step(key: "two_fingers", text: "Two fingers resting. Press LEFT finger harder (no click), then RIGHT finger harder.", secs: 8),
    Step(key: "palm_plus_finger", text: "Rest your palm/thumb edge on the pad AND draw with one finger.", secs: 6),
    Step(key: "hold_still", text: "One finger, held perfectly STILL (jitter check).", secs: 4),
]

final class ProbeView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    var onKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
        label.font = .systemFont(ofSize: 26, weight: .medium)
        label.alignment = .center
        label.frame = bounds.insetBy(dx: 40, dy: 40)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func logTouches(_ e: NSEvent, _ phase: String) {
        let ts = e.touches(matching: .any, in: self).map { t -> [String: Any] in
            ["id": "\(t.identity.hash)", "x": t.normalizedPosition.x, "y": t.normalizedPosition.y,
             "resting": t.isResting, "phase": t.phase.rawValue,
             "devW": t.deviceSize.width, "devH": t.deviceSize.height]
        }
        Log.shared.write("nstouch", ["phase": phase, "ts": e.timestamp, "touches": ts])
    }
    override func touchesBegan(with e: NSEvent) { logTouches(e, "began") }
    override func touchesMoved(with e: NSEvent) { logTouches(e, "moved") }
    override func touchesEnded(with e: NSEvent) { logTouches(e, "ended") }
    override func touchesCancelled(with e: NSEvent) { logTouches(e, "cancelled") }

    override func pressureChange(with e: NSEvent) {
        Log.shared.write("pressure", ["p": e.pressure, "stage": e.stage, "trans": e.stageTransition, "ts": e.timestamp])
    }
    override func mouseDown(with e: NSEvent) {
        Log.shared.mouseDown = true
        Log.shared.write("mouse", ["type": "down", "p": e.pressure, "stage": e.stage])
    }
    override func mouseUp(with e: NSEvent) {
        Log.shared.mouseDown = false
        Log.shared.write("mouse", ["type": "up"])
    }
    override func mouseDragged(with e: NSEvent) {
        Log.shared.write("mouse", ["type": "drag", "p": e.pressure, "stage": e.stage])
    }
    override func keyDown(with e: NSEvent) { onKey?(e) }
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: ProbeView!
    var idx = -1
    var timer: Timer?
    var remaining = 0.0
    let outPath: String
    var mtStatus = ""

    init(outPath: String) { self.outPath = outPath }

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.shared.open(outPath)
        let screen = NSScreen.main!.visibleFrame
        window = NSWindow(contentRect: screen.insetBy(dx: screen.width * 0.15, dy: screen.height * 0.15),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Trackpad probe (Phase 1)"
        view = ProbeView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        mtStatus = startMT()
        Log.shared.write("meta", ["mt": mtStatus, "os": ProcessInfo.processInfo.operatingSystemVersionString])
        view.label.stringValue = "Trackpad probe — \(steps.count) short steps, about 1 minute.\n\nKeep this window in front. Follow each prompt.\n\nPress SPACE to start.  (Esc quits.)\n\nMT: \(mtStatus)"
        view.onKey = { [weak self] e in
            guard let self else { return }
            if e.keyCode == 53 { self.finish(aborted: true) }
            else if e.keyCode == 49 && self.idx == -1 { self.next() }
        }
    }

    func next() {
        idx += 1
        if idx >= steps.count { finish(aborted: false); return }
        let s = steps[idx]
        Log.shared.step = "gap"
        remaining = 2.0
        view.label.stringValue = "Lift your fingers.\n\nNext (\(idx + 1)/\(steps.count)): \(s.text)"
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in self?.run(s) }
    }

    func run(_ s: Step) {
        Log.shared.step = s.key
        remaining = s.secs
        let render = { [weak self] in
            guard let self else { return }
            self.view.label.stringValue = "Step \(self.idx + 1)/\(steps.count) — NOW\n\n\(s.text)\n\n\(Int(ceil(self.remaining)))s"
        }
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { return }
            self.remaining -= 0.25
            if self.remaining <= 0 { t.invalidate(); self.next() } else { render() }
        }
    }

    func finish(aborted: Bool) {
        timer?.invalidate()
        Log.shared.step = "done"
        Log.shared.write("meta", ["finished": !aborted])
        Log.shared.flush()
        view.label.stringValue = aborted ? "Aborted. Partial log saved:\n\(outPath)" : "Done — thanks! Log saved:\n\(outPath)\n\nYou can close this window."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    }
}

// --selftest: load MultitouchSupport, list devices, exit (no window, no focus steal).
if CommandLine.arguments.contains("--selftest") {
    print("MTTouch stride:", MemoryLayout<MTTouch>.stride)
    print(startMT())
    exit(0)
}

// --listen N out.jsonl: passive MT capture for N seconds during normal use (no window).
if let i = CommandLine.arguments.firstIndex(of: "--listen"), CommandLine.arguments.count > i + 2 {
    Log.shared.open(CommandLine.arguments[i + 2])
    Log.shared.step = "passive"
    print(startMT())
    RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments[i + 1]) ?? 30))
    Log.shared.flush()
    exit(0)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "probe-\(Int(Date().timeIntervalSince1970)).jsonl"
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App(outPath: out)
app.delegate = delegate
app.run()
