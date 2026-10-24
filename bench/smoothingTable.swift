// What each Smoothing slider position does: a finger moving at 40 mm/s that stops dead and holds
// still (sensor noise sigma 0.02 mm) for 1 s. At 100% zoom in the default window, 1 px = 0.046 mm.
import CoreGraphics
import Foundation

func smoothingTable(_ check: (Bool, String) -> Void) {
    let pxPerMM = 10.96 * 2
    var rng = SystemRandomNumberGenerator()
    func gauss() -> Double { sqrt(-2 * log(Double.random(in: 1e-12..<1, using: &rng))) * cos(2 * .pi * Double.random(in: 0..<1, using: &rng)) }
    print("Smoothing slider: lag while moving, time for the ink to settle after the finger stops, still-finger wobble")
    var settleAt: [Double: Double] = [:]
    for s in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let p = Smoothing.params(s)
        var lags: [Double] = [], settle: [Double] = [], wobble: [Double] = []
        for _ in 0..<20 {
            var b = StrokeBuilder(model: MTPressureModel(), minCutoff: p.minCutoff, beta: p.beta, toCanvas: { $0 })
            var t = 0.0, x = 20.0
            for _ in 0..<62 { x += 40 * 0.008; t += 0.008; b.add(InputSample(mm: CGPoint(x: x, y: 30), t: t, pressure: 25, size: 0.5))
                lags.append((x - b.lastFiltered!.x) * pxPerMM / 2) }   // pt
            let stopT = t
            var settled: Double?
            var hold: [CGPoint] = []
            for _ in 0..<125 {
                t += 0.008
                b.add(InputSample(mm: CGPoint(x: x + gauss() * 0.02, y: 30 + gauss() * 0.02), t: t, pressure: 25, size: 0.5))
                let f = b.lastFiltered!
                if settled == nil, abs(f.x - x) * pxPerMM < 1 { settled = t - stopT }
                if t - stopT > 0.4 { hold.append(f) }
            }
            settle.append((settled ?? 1) * 1000)
            let xs = hold.map(\.x), ys = hold.map(\.y)
            wobble.append(max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) * pxPerMM)
        }
        func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        settleAt[s] = med(settle)
        print(String(format: "  %3.0f%%  (minCutoff %5.2f Hz, beta %4.2f): lag %4.1f pt, settles in %4.0f ms, still wobble %.2f px",
                     s * 100, p.minCutoff, p.beta, med(lags), med(settle), med(wobble)))
    }
    check(settleAt[0.5]! < 250, String(format: "default smoothing settles within 250 ms of the finger stopping (%.0f ms)", settleAt[0.5]!))
}
