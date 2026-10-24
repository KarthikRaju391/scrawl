// Multiple displays: the frozen pointer parks on the canvas whichever display the window is on.
import AppKit

func displayChecks(_ check: (Bool, String) -> Void) {
    // Primary 1512 x 982 at the origin. Secondary displays in AppKit coordinates (y up):
    let primaryH: CGFloat = 982
    let cases: [(String, CGRect, CGRect)] = [   // name, canvas rect (AppKit global), display it's on (CG global, y down)
        ("primary", CGRect(x: 200, y: 100, width: 1000, height: 640), CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ("external to the right", CGRect(x: 1700, y: 200, width: 1600, height: 1000), CGRect(x: 1512, y: -458, width: 2560, height: 1440)),
        ("external to the left, lower", CGRect(x: -2400, y: -900, width: 1600, height: 900), CGRect(x: -2560, y: 541, width: 2560, height: 1440)),
        ("external above", CGRect(x: 100, y: 1200, width: 1600, height: 900), CGRect(x: -500, y: -1440, width: 2560, height: 1440)),
    ]
    var bad: [String] = []
    for (name, canvas, display) in cases {
        let p = CursorLock.parkPoint(canvasOnScreen: canvas, primaryScreenHeight: primaryH)
        // The CG point must be on the display the canvas is on, and map back to the canvas centre.
        let back = CGPoint(x: p.x, y: primaryH - p.y)
        if !display.contains(p) || abs(back.x - canvas.midX) > 0.01 || abs(back.y - canvas.midY) > 0.01 { bad.append("\(name) -> \(p)") }
    }
    check(bad.isEmpty, "frozen pointer parks on the canvas on primary, right, left-lower and above displays\(bad.isEmpty ? "" : ": \(bad)")")
}
