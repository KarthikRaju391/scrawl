// robot-input: real keyboard and mouse events (CGEvent), posted to one process (CGEventPostToPid), so the
// app gets them without taking focus or moving the pointer of the person using the Mac.
//   robot-input key <pid> <keycode> [ctrl,opt,cmd,shift]
// (Clicks posted this way never reach a window of an app in the background, so the robot clicks through
// AppKit inside the app instead; see app/Robot.swift.)
import CoreGraphics
import Foundation

let a = CommandLine.arguments
func flags(_ s: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in s.split(separator: ",") {
        switch m { case "ctrl": f.insert(.maskControl); case "opt": f.insert(.maskAlternate); case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift); default: break }
    }
    return f
}
guard a.count >= 4, let pid = pid_t(a[2]) else { print("usage: robot-input key <pid> <keycode> [mods]"); exit(2) }
let src = CGEventSource(stateID: .privateState)
switch a[1] {
case "key":
    let code = CGKeyCode(a[3])!
    let f = a.count > 4 ? flags(a[4]) : []
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = f
        e.postToPid(pid)
        usleep(15_000)
    }
default: exit(2)
}
