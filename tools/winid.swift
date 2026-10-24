// Prints the id of the largest normal (layer 0) window owned by a pid or process name.
import CoreGraphics
let key = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
var best: (Int, Double)?
for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
    let owner = w[kCGWindowOwnerName as String] as? String, pid = w[kCGWindowOwnerPID as String] as? Int
    guard owner == key || pid.map(String.init) == key else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if best == nil || area > best!.1 { best = (w[kCGWindowNumber as String] as! Int, area) }
}
if let best { print(best.0) }
