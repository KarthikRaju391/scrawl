// Jitter model: a finger held still with Gaussian sensor noise of sigma mm, sampled at 125 Hz,
// through the app's StrokeBuilder. Reports the drawn spread over 2 s (after 0.2 s settling) in
// physical pixels at 100% zoom. Real sensor noise is unknown until the guided hold_still step.
import CoreGraphics
import Foundation

func jitterModel(ptPerMM: Double, backing: Double, minCutoff: Double, beta: Double, writeLog: String?) {
    var rng = SystemRandomNumberGenerator()
    func gauss() -> Double {
        let u = Double.random(in: Double.ulpOfOne..<1, using: &rng), v = Double.random(in: 0..<1, using: &rng)
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
    print(String(format: "jitter model (One Euro minCutoff %.2f Hz, beta %.3f; %.1f pt/mm, %gx backing), 20 runs each:", minCutoff, beta, ptPerMM, backing))
    for sigma in [0.01, 0.02, 0.03, 0.05, 0.1] {
        var spreads: [Double] = [], raws: [Double] = []
        for run in 0..<20 {
            var b = StrokeBuilder(model: MTPressureModel(), minCutoff: minCutoff, beta: beta, toCanvas: { $0 })
            var outs: [CGPoint] = [], ins: [CGPoint] = []
            var log: [[Double]] = []
            for i in 0..<300 {  // 2.4 s
                let t = Double(i) * 0.008
                let p = CGPoint(x: 60 + gauss() * sigma, y: 40 + gauss() * sigma)
                b.add(InputSample(mm: p, t: t, pressure: 17, size: 0.5))
                if t >= 0.2 && t <= 2.2 { outs.append(b.lastFiltered!); ins.append(p) }
                // jitter_check.py log format; canvas units = mm * 1600/124.8, ptPerUnit chosen so pt/mm matches
                let k = 1600 / 124.8
                log.append([t, p.x, p.y, 17, 0.5, b.lastFiltered!.x * k, b.lastFiltered!.y * k, 0.3])
            }
            func spread(_ v: [CGPoint]) -> Double { max(v.map(\.x).max()! - v.map(\.x).min()!, v.map(\.y).max()! - v.map(\.y).min()!) }
            spreads.append(spread(outs) * ptPerMM * backing)
            raws.append(spread(ins) * ptPerMM * backing)
            if let path = writeLog, sigma == 0.05, run == 0 {
                let rec: [String: Any] = ["tool": "pen", "model": "synthetic", "zoom": 1.0, "ptPerUnit": ptPerMM * 124.8 / 1600, "backing": backing, "committed": true, "samples": log, "latencyMs": []]
                try! JSONSerialization.data(withJSONObject: rec).write(to: URL(fileURLWithPath: path))
            }
        }
        spreads.sort()
        print(String(format: "  sigma %.2f mm: raw spread %5.1f px -> drawn p50 %.2f px, max %.2f px  %@", sigma, raws.reduce(0, +) / 20, spreads[10], spreads.last!, spreads.last! < 1 ? "(< 1 px)" : ""))
    }
}
