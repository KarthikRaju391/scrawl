// Prints the id of the largest normal (layer 0) window owned by a pid or process name.
// `winid <pid> all`: every on-screen layer-0 window of it, one per line: id x y width height (points, top-left origin).
import CoreGraphics
let key = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "all" {
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowIsOnscreen as String] as? Bool) == true {
        let owner = w[kCGWindowOwnerName as String] as? String, pid = w[kCGWindowOwnerPID as String] as? Int
        guard owner == key || pid.map(String.init) == key else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print(w[kCGWindowNumber as String] as! Int, Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(b["Width"] ?? 0), Int(b["Height"] ?? 0))
    }
    exit(0)
}
var best: (Int, Double)?
for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
    let owner = w[kCGWindowOwnerName as String] as? String, pid = w[kCGWindowOwnerPID as String] as? Int
    guard owner == key || pid.map(String.init) == key else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if best == nil || area > best!.1 { best = (w[kCGWindowNumber as String] as! Int, area) }
}
if let best { print(best.0) }
