// Probes the Force Touch trackpad's actuator via private MultitouchSupport (MTActuator*).
// Usage: haptic_probe [ids...]   Prints return codes and call durations for each actuation ID.
// Signatures as used by HapticKey / other open-source projects (reverse engineered, unofficial).
import CoreFoundation
import Darwin
import Foundation
import QuartzCore

let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)!
func sym<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
typealias GetID = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>) -> Int32
typealias BuiltIn = @convention(c) (UnsafeMutableRawPointer?) -> Bool
typealias ActCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
typealias ActOpen = @convention(c) (CFTypeRef) -> Int32
typealias ActActuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

let list = sym("MTDeviceCreateList", CreateList.self)!()!.takeRetainedValue()
var devID: UInt64 = 0
for i in 0..<CFArrayGetCount(list) {
    let d = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))
    if sym("MTDeviceIsBuiltIn", BuiltIn.self)?(d) ?? true { _ = sym("MTDeviceGetDeviceID", GetID.self)!(d, &devID); break }
}
print("device id \(devID)")
guard let create = sym("MTActuatorCreateFromDeviceID", ActCreate.self), let open = sym("MTActuatorOpen", ActOpen.self),
      let actuate = sym("MTActuatorActuate", ActActuate.self) else { print("actuator symbols missing"); exit(1) }
guard let act = create(devID)?.takeRetainedValue() else { print("MTActuatorCreateFromDeviceID returned nil"); exit(1) }
print("open rc \(open(act))")
let ids = CommandLine.arguments.dropFirst().compactMap { Int32($0) }
for id in ids.isEmpty ? [1, 2, 3, 4, 5, 6, 15, 16] : ids {
    let t0 = CACurrentMediaTime()
    let rc = actuate(act, id, 0, 0, 2.0)
    print(String(format: "id %2d rc 0x%08x  %.3f ms", id, UInt32(bitPattern: rc), (CACurrentMediaTime() - t0) * 1000))
    usleep(700_000)
}
