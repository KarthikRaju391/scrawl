// Prints the pids of open "Problem Report for Trackpad Draw" windows; with --close, quits them.
// The crash checks use it so a test crash can never leave a dialog on Karthik's screen.
import CoreGraphics
import Foundation
let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let pids = Set(wins.filter { ($0[kCGWindowName as String] as? String ?? "").hasPrefix("Problem Report for Trackpad Draw") }
                   .compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
for p in pids { print(p); if CommandLine.arguments.contains("--close") { kill(p, SIGTERM) } }
