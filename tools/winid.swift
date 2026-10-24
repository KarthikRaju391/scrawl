// Prints the window id of the first on-screen window owned by a process name.
import CoreGraphics
let name = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == name && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String]!); break
}
