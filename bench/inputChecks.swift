// Input without MultitouchSupport, and with several trackpads.
import AppKit

func inputChecks(_ check: (Bool, String) -> Void) {
    // Two pads: the first touched owns the input until its fingers lift; idle pads' empty frames are dropped.
    var a = DeviceArbiter()
    let seq: [(Int, Int, Double, Bool)] = [
        (1, 0, 0.00, false),   // built-in idle frame
        (2, 1, 0.01, true),    // finger on the Magic Trackpad: it becomes active
        (1, 1, 0.02, false),   // a palm on the built-in pad meanwhile: ignored
        (2, 2, 0.03, true),
        (2, 0, 0.04, true),    // all up on pad 2: the empty frame goes through, pad released
        (2, 0, 0.05, false),   // its trailing empty frames: dropped
        (1, 1, 0.06, true),    // now the built-in pad can take over
    ]
    var got: [Bool] = []
    for (d, n, t, _) in seq { got.append(a.accept(device: d, touches: n, now: t)) }
    check(got == seq.map(\.3), "two trackpads: the one touched first owns the input until its fingers lift (\(got))")
    var b = DeviceArbiter()
    _ = b.accept(device: 1, touches: 1, now: 0)   // pad 1 never sends its final empty frame
    check(!b.accept(device: 2, touches: 1, now: 0.3) && b.accept(device: 2, touches: 1, now: 0.6),
          "a pad that goes quiet without a final empty frame releases the input after 0.5 s")

    // NSTouch -> Contact: device size is in points; mm = normalized * size * 25.4/72.
    let t = CanvasView.NSTouchSample(key: 7, norm: CGPoint(x: 0.25, y: 0.5), deviceSize: CGSize(width: 453.5, height: 283.5), resting: false)
    let c = CanvasView.contact(fromTouch: t, id: 3)
    check(abs(c.mm.x - 40.0) < 0.05 && abs(c.mm.y - 50.0) < 0.05 && c.pressure == 0 && c.id == 3,
          String(format: "public touch path maps a 160 x 100 mm pad to mm (%.2f, %.2f), no pressure", c.mm.x, c.mm.y))

    // What the welcome window says for each input situation.
    check(InputStatus(mtError: nil, stalled: false, summary: "built-in trackpad 160 × 100 mm") == .full("built-in trackpad 160 × 100 mm")
          && InputStatus(mtError: "turned off (basic touch input chosen)", stalled: false, summary: "") == .basic("turned off (basic touch input chosen)")
          && InputStatus(mtError: "no trackpad found", stalled: false, summary: "") == .noTrackpad
          && InputStatus(mtError: nil, stalled: true, summary: "x") == .stalled,
          "input status: full / basic / no trackpad / stalled map to their messages")
}
