// Prints whether the system cursor is visible (CGCursorIsVisible via dlsym; unavailable to Swift
// directly) and where it is.
import CoreGraphics
import Darwin
typealias F = @convention(c) () -> Int32
let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
let vis = dlsym(h, "CGCursorIsVisible").map { unsafeBitCast($0, to: F.self)() }
let loc = CGEvent(source: nil)!.location
print("cursor visible=\(vis.map { $0 != 0 ? "yes" : "no" } ?? "unknown") at=(\(Int(loc.x)),\(Int(loc.y)))")
