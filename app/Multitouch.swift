// Private MultitouchSupport.framework access (personal use only; may break on macOS updates).
// Layout of MTTouch from OpenMultitouchSupport; verified stride 96 on macOS 26.6 in Phase 1.
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
    /// Called on the framework's thread with all contacts of a frame and the arrival time
    /// (CACurrentMediaTime; the framework's own timestamp is on a different clock).
    nonisolated(unsafe) static var onFrame: (([Contact], Double) -> Void)?

    static let callback: MTFrameCB = { _, raw, n, _, _ in
        let arrival = CACurrentMediaTime()
        var out: [Contact] = []
        if let raw, n > 0 {
            let touches = raw.assumingMemoryBound(to: MTTouch.self)
            out.reserveCapacity(Int(n))
            for i in 0..<Int(n) {
                let t = touches[i]
                let nx = CGFloat(t.normalized.position.x), ny = CGFloat(t.normalized.position.y)
                out.append(Contact(id: t.identifier, state: t.state, norm: CGPoint(x: nx, y: ny),
                                   mm: CGPoint(x: nx * Multitouch.padMM.width, y: ny * Multitouch.padMM.height),
                                   pressure: Double(t.pressure), size: Double(t.total), major: Double(t.majorAxis)))
            }
        }
        Multitouch.onFrame?(out, arrival)
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
        var started = 0
        for i in 0..<CFArrayGetCount(list) {
            let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))
            if let builtIn, !builtIn(dev) { continue }  // external Magic Trackpads: not handled yet
            var w: Int32 = 0, hgt: Int32 = 0
            if dims?(dev, &w, &hgt) == 0, w > 0, hgt > 0 {
                padMM = CGSize(width: Double(w) / 100, height: Double(hgt) / 100)
            }
            register(dev, callback)
            if start(dev, 0) == 0 { started += 1 }
        }
        return started > 0 ? nil : "no built-in trackpad started"
    }
}
