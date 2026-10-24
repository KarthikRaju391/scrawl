// Posts a key down/up (default Esc, keycode 53) to a pid, or to the HID stream with "hid".
import CoreGraphics
import Foundation
let pid = pid_t(CommandLine.arguments[1]) ?? 0
let code = CGKeyCode(CommandLine.arguments.count > 2 ? UInt16(CommandLine.arguments[2])! : 53)
let src = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    if CommandLine.arguments[1] == "hid" { e.post(tap: .cghidEventTap) } else { e.postToPid(pid) }
    usleep(30000)
}
