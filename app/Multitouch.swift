// Private MultitouchSupport.framework access (may break on macOS updates; rules out the Mac App Store).
// Layout of MTTouch from OpenMultitouchSupport; verified stride 96 on macOS 26.6 in Phase 1.
// Every trackpad is registered (built-in and Magic Trackpads, e.g. a closed-lid MacBook); the one being
// touched owns the input until all its fingers lift, so two pads never interleave.
import CoreGraphics
import Darwin
import Foundation
import QuartzCore

struct MTPoint { var x: Float; var y: Float }
struct MTVector { var position: MTPoint; var velocity: MTPoint }
struct MTTouch {
    var frame: Int32; var timestamp: Double; var identifier: Int32; var state: Int32
    var fingerId: Int32; var handId: Int32; var normalized: MTVector
    var total: Float; var pressure: Float; var angle: Float; var majorAxis: Float; var minorAxis: Float
    var absolute: MTVector; var field14: Int32; var field15: Int32; var density: Float
}

/// One finger in one frame, copied out of the framework's buffer.
struct Contact {
    var id: Int32
    var state: Int32       // 3 MakeTouch, 4 Touching, 5 BreakTouch, 6/7 lifting
    var norm: CGPoint      // 0...1, origin bottom-left
    var mm: CGPoint        // normalized * pad size, origin bottom-left
    var pressure: Double
    var size: Double       // `total`
    var major: Double

    var isDown: Bool { state == 3 || state == 4 }
}

// Raw pointer for touches: Swift structs aren't C-representable in @convention(c).
typealias MTFrameCB = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

enum Multitouch {
    /// Pad size in mm (from MTDeviceGetSensorSurfaceDimensions), set by start().
    static var padMM = CGSize(width: 124.8, height: 76.8)
    /// Called on the framework's thread with all contacts of a frame, the arrival time
    /// (CACurrentMediaTime, for latency) and the sensor's frame timestamp (its own clock, steady
    /// 8 ms steps; used to time the filter so delivery hiccups don't distort strokes).
    /// Pad y assumed to grow upward (bottom-left origin). If strokes come out upside down:
    /// `defaults write local.trackpad-draw padFlipY -bool true`.
    nonisolated(unsafe) static var flipY = UserDefaults.standard.bool(forKey: "padFlipY")
    nonisolated(unsafe) static var onFrame: (([Contact], Double, Double) -> Void)?

    /// Devices and their pad sizes; which one is being touched.
    struct Pad { var mm: CGSize; var builtIn: Bool }
    nonisolated(unsafe) static var pads: [UnsafeMutableRawPointer: Pad] = [:]
    nonisolated(unsafe) static var arbiter = DeviceArbiter()
    static let lock = NSLock()
    /// What start() found, for the welcome window and Help.
    nonisolated(unsafe) static var summary = ""

    static let callback: MTFrameCB = { dev, raw, n, sensorT, _ in
        let arrival = CACurrentMediaTime()
        lock.lock()
        let accept = arbiter.accept(device: dev.map { Int(bitPattern: $0) } ?? 0, touches: Int(n), now: arrival)
        if accept, arbiter.switched, let dev, let pad = pads[dev] { padMM = pad.mm }
        lock.unlock()
        guard accept else { return }
        var out: [Contact] = []
        if let raw, n > 0 {
            let touches = raw.assumingMemoryBound(to: MTTouch.self)
            out.reserveCapacity(Int(n))
            for i in 0..<Int(n) {
                let t = touches[i]
                let nx = CGFloat(t.normalized.position.x)
                let ny = Multitouch.flipY ? 1 - CGFloat(t.normalized.position.y) : CGFloat(t.normalized.position.y)
                out.append(Contact(id: t.identifier, state: t.state, norm: CGPoint(x: nx, y: ny),
                                   mm: CGPoint(x: nx * Multitouch.padMM.width, y: ny * Multitouch.padMM.height),
                                   pressure: Double(t.pressure), size: Double(t.total), major: Double(t.majorAxis)))
            }
        }
        Multitouch.onFrame?(out, arrival, sensorT)
    }

    /// Starts every built-in multitouch device. Returns nil on success, else why it failed.
    static func start() -> String? {
        guard MemoryLayout<MTTouch>.stride == 96 else { return "MTTouch layout mismatch" }
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            return "MultitouchSupport not loadable"
        }
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias Register = @convention(c) (UnsafeMutableRawPointer?, MTFrameCB) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        typealias Dims = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
        typealias BuiltIn = @convention(c) (UnsafeMutableRawPointer?) -> Bool
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let createList = sym("MTDeviceCreateList", CreateList.self),
              let register = sym("MTRegisterContactFrameCallback", Register.self),
              let start = sym("MTDeviceStart", Start.self),
              let list = createList()?.takeRetainedValue() else { return "MultitouchSupport symbols missing" }
        let dims = sym("MTDeviceGetSensorSurfaceDimensions", Dims.self)
        let builtIn = sym("MTDeviceIsBuiltIn", BuiltIn.self)
        var started: [String] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i)) else { continue }
            var w: Int32 = 0, hgt: Int32 = 0
            // Only devices with a touch surface (trackpads); size in 1/100 mm.
            guard dims?(dev, &w, &hgt) == 0, w > 0, hgt > 0 else { continue }
            let pad = Pad(mm: CGSize(width: Double(w) / 100, height: Double(hgt) / 100), builtIn: builtIn?(dev) ?? false)
            lock.lock(); pads[dev] = pad; lock.unlock()
            register(dev, callback)
            if start(dev, 0) == 0 {
                started.append(String(format: "%@ %.0f × %.0f mm", pad.builtIn ? "built-in trackpad" : "external trackpad", pad.mm.width, pad.mm.height))
                if pad.builtIn || started.count == 1 { padMM = pad.mm }   // until a pad is touched
            }
        }
        summary = started.joined(separator: ", ")
        return started.isEmpty ? "no trackpad found" : nil
    }
}

/// With several trackpads, the first one touched owns the input until it reports no fingers.
struct DeviceArbiter {
    private(set) var active: Int?
    private(set) var switched = false   // the last accepted frame made a new device active
    private var lastAt = 0.0

    mutating func accept(device: Int, touches: Int, now: Double) -> Bool {
        switched = false
        if active != nil, device != active, now - lastAt > 0.5 { active = nil }   // its final empty frame never came
        if active == nil {
            guard touches > 0 else { return false }   // idle pads' empty frames
            active = device; switched = true
        }
        guard device == active else { return false }
        lastAt = now
        if touches == 0 { active = nil }               // all fingers up: this empty frame still goes through
        return true
    }
}
