// Clicks at a point given as fractions of a pid's largest window (fx fy from top-left), via postToPid.
import CoreGraphics
import Foundation
let pid = pid_t(CommandLine.arguments[1])!, fx = Double(CommandLine.arguments[2])!, fy = Double(CommandLine.arguments[3])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
var best: [String: Double]?
var wid = 0
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    if best == nil || b["Width"]! * b["Height"]! > best!["Width"]! * best!["Height"]! { best = b; wid = w[kCGWindowNumber as String] as! Int }
}
let b = best!
let p = CGPoint(x: b["X"]! + b["Width"]! * fx, y: b["Y"]! + b["Height"]! * fy)
for t in [CGEventType.leftMouseDown, .leftMouseUp] {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
    // Events posted to a pid carry no window; tell AppKit which window is under the pointer.
    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))
    e.setIntegerValueField(.mouseEventClickState, value: 1)
    e.postToPid(pid); usleep(40000)
}
print("clicked \(Int(p.x)),\(Int(p.y))")
