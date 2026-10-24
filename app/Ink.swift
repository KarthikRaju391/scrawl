// Ink pipeline, UI-free so the bench can replay recorded trackpad data through it.
//   raw finger point -> One Euro filter -> width model (0...1 pressure) -> perfect-freehand radius
//   -> union of circles + segment quads (one CGPath, nonzero fill).
import CoreGraphics
import Foundation

// MARK: - One Euro filter (Casiez et al. 2012), 2D with a shared speed estimate

struct OneEuro2D {
    var minCutoff: Double  // Hz; lower = steadier when still
    var beta: Double       // how fast the cutoff rises with speed (units of the input)
    var dCutoff: Double = 1.0
    private var prev: CGPoint?
    private var dPrev = CGPoint.zero
    private var tPrev = 0.0

    init(minCutoff: Double, beta: Double) { self.minCutoff = minCutoff; self.beta = beta }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    var velocity: CGPoint { dPrev }

    mutating func reset() { prev = nil; dPrev = .zero }

    mutating func filter(_ x: CGPoint, t: Double) -> CGPoint {
        guard let p = prev else { prev = x; tPrev = t; return x }
        let dt = max(t - tPrev, 1e-4)
        tPrev = t
        let dx = CGPoint(x: (x.x - p.x) / dt, y: (x.y - p.y) / dt)
        let ad = Self.alpha(dCutoff, dt)
        dPrev = CGPoint(x: dPrev.x + ad * (dx.x - dPrev.x), y: dPrev.y + ad * (dx.y - dPrev.y))
        let speed = hypot(dPrev.x, dPrev.y)
        let a = Self.alpha(minCutoff + beta * speed, dt)
        let out = CGPoint(x: p.x + a * (x.x - p.x), y: p.y + a * (x.y - p.y))
        prev = out
        return out
    }
}

// MARK: - Width models (swappable; tune after the guided probe run)

/// One input sample from a finger. `mm` is pad position in millimetres (filter space).
struct InputSample {
    var mm: CGPoint
    var t: Double
    var pressure: Double  // MultitouchSupport per-finger pressure (raw units, ~0-140 on this pad)
    var size: Double      // MultitouchSupport `total` (contact capacitance, ~0.1-0.85)
}

protocol WidthModel {
    var name: String { get }
    mutating func reset()
    /// 0...1, fed to perfect-freehand as pressure.
    mutating func pressure(_ s: InputSample, speedMMPerSec: Double) -> Double
}

/// Per-finger force from the private framework. Works without clicking.
/// Phase 1 passive data: unclicked p50 17, p95 40, max 123. Range defaults are provisional.
struct MTPressureModel: WidthModel {
    var name = "mt-pressure"
    var lo = 4.0, hi = 70.0, gamma = 0.8
    var divideBySize = false   // turn on if the guided run shows pressure is mostly contact area
    var smoothing = 0.35       // EMA weight of the new value
    private var last: Double?
    mutating func reset() { last = nil }
    mutating func pressure(_ s: InputSample, speedMMPerSec: Double) -> Double {
        var raw = s.pressure
        if divideBySize { raw /= max(s.size, 0.2) * 2 }
        let n = pow(min(max((raw - lo) / (hi - lo), 0), 1), gamma)
        let v = last.map { $0 + smoothing * (n - $0) } ?? n
        last = v
        return v
    }
}

/// Public-API fallback: faster = thinner (perfect-freehand's simulated pressure, in mm/s).
struct SpeedModel: WidthModel {
    var name = "speed"
    var fastMMPerSec = 160.0
    var smoothing = 0.25
    private var last: Double?
    mutating func reset() { last = nil }
    mutating func pressure(_ s: InputSample, speedMMPerSec: Double) -> Double {
        let n = 1 - min(speedMMPerSec / fastMMPerSec, 1) * 0.8
        let v = last.map { $0 + smoothing * (n - $0) } ?? 0.5
        last = v
        return v
    }
}

/// Contact size only (private framework `total`).
struct ContactSizeModel: WidthModel {
    var name = "contact-size"
    var lo = 0.25, hi = 0.8
    private var last: Double?
    mutating func reset() { last = nil }
    mutating func pressure(_ s: InputSample, speedMMPerSec: Double) -> Double {
        let n = min(max((s.size - lo) / (hi - lo), 0), 1)
        let v = last.map { $0 + 0.3 * (n - $0) } ?? n
        last = v
        return v
    }
}

func makeWidthModel(_ name: String) -> WidthModel {
    switch name {
    case "speed": return SpeedModel()
    case "contact-size": return ContactSizeModel()
    default: return MTPressureModel()
    }
}

// MARK: - Tools

enum ToolKind: String, CaseIterable { case pen, marker, highlighter, eraser }

struct Brush {
    var thinning: Double   // perfect-freehand: how much pressure changes width
    var alpha: CGFloat
    var taperStart: Double // in multiples of size
    var taperEnd: Double

    static func of(_ k: ToolKind) -> Brush {
        switch k {
        case .pen: return Brush(thinning: 0.6, alpha: 1, taperStart: 0, taperEnd: 1.5)
        case .marker: return Brush(thinning: 0.2, alpha: 1, taperStart: 0, taperEnd: 0)
        case .highlighter: return Brush(thinning: 0, alpha: 0.35, taperStart: 0, taperEnd: 0)
        case .eraser: return Brush(thinning: 0, alpha: 1, taperStart: 0, taperEnd: 0)
        }
    }
}

// MARK: - Stroke geometry (perfect-freehand radius model)

struct StrokePoint { var p: CGPoint; var pressure: Double }

/// perfect-freehand getStrokeRadius: size * easing(0.5 - thinning * (0.5 - pressure)), easing = identity.
@inline(__always) func strokeRadius(size: Double, thinning: Double, pressure: Double) -> Double {
    max(size * (0.5 - thinning * (0.5 - pressure)), 0.05 * size)
}

/// Radius per point: perfect-freehand thinning plus start/end tapers by arc length.
/// `live` skips the end taper (the end isn't known yet while the finger is down).
func strokeRadii(_ pts: [StrokePoint], size: Double, brush: Brush, live: Bool = false) -> [Double] {
    guard !pts.isEmpty else { return [] }
    var lens = [0.0]
    for i in 1..<pts.count { lens.append(lens[i - 1] + hypot(pts[i].p.x - pts[i - 1].p.x, pts[i].p.y - pts[i - 1].p.y)) }
    let total = lens.last!
    let ts = brush.taperStart * size, te = brush.taperEnd * size
    return pts.indices.map { i in
        var rad = strokeRadius(size: size, thinning: brush.thinning, pressure: pts[i].pressure)
        if ts > 0 { rad *= min(1, 0.25 + 0.75 * lens[i] / ts) }
        if !live && te > 0 && total > te * 1.5 { rad *= min(1, 0.25 + 0.75 * (total - lens[i]) / te) }
        return rad
    }
}

/// Filled outline as a union of circles at each point plus a quad per segment.
/// All subpaths share one winding direction, so a nonzero fill is the exact union (no double
/// alpha for the highlighter, no self-intersection holes at sharp turns).
/// `from` > 0 builds only the part from that point on (incremental drawing of a live stroke).
func strokePath(_ pts: [StrokePoint], size: Double, brush: Brush, from: Int = 0, live: Bool = false) -> CGPath {
    let path = CGMutablePath()
    guard from < pts.count else { return path }
    let r = strokeRadii(pts, size: size, brush: brush, live: live)
    if from == 0 { path.addEllipse(in: CGRect(x: pts[0].p.x - r[0], y: pts[0].p.y - r[0], width: 2 * r[0], height: 2 * r[0])) }
    for i in max(from, 1)..<pts.count {
        let a = pts[i - 1].p, b = pts[i].p, ra = r[i - 1], rb = r[i]
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        if d > 1e-6 {
            let nx = -dy / d, ny = dx / d
            // Same winding as addEllipse (checked by the bench's hole test).
            path.move(to: CGPoint(x: a.x - nx * ra, y: a.y - ny * ra))
            path.addLine(to: CGPoint(x: b.x - nx * rb, y: b.y - ny * rb))
            path.addLine(to: CGPoint(x: b.x + nx * rb, y: b.y + ny * rb))
            path.addLine(to: CGPoint(x: a.x + nx * ra, y: a.y + ny * ra))
            path.closeSubpath()
        }
        path.addEllipse(in: CGRect(x: b.x - rb, y: b.y - rb, width: 2 * rb, height: 2 * rb))
    }
    return path
}

// MARK: - Stroke builder: raw samples in, smoothed stroke points out

/// Turns one finger's raw samples into stroke points. Units: filter runs in pad millimetres;
/// `toCanvas` maps filtered mm to canvas units (fixed for the stroke's lifetime).
struct StrokeBuilder {
    var filter: OneEuro2D
    var model: WidthModel
    var toCanvas: (CGPoint) -> CGPoint
    var streamline = 0.25  // perfect-freehand streamline on top of One Euro (0 = off)
    private(set) var points: [StrokePoint] = []
    private(set) var lastFiltered: CGPoint?
    private(set) var lastT = 0.0
    private(set) var lengthMM = 0.0
    private var lastPressure = 0.5

    init(model: WidthModel, minCutoff: Double, beta: Double, toCanvas: @escaping (CGPoint) -> CGPoint) {
        self.model = model
        self.model.reset()
        filter = OneEuro2D(minCutoff: minCutoff, beta: beta)
        self.toCanvas = toCanvas
    }

    mutating func add(_ s: InputSample) {
        var f = filter.filter(s.mm, t: s.t)
        if let l = lastFiltered {
            let t = 0.15 + (1 - streamline) * 0.85
            f = CGPoint(x: l.x + (f.x - l.x) * t, y: l.y + (f.y - l.y) * t)
            lengthMM += hypot(f.x - l.x, f.y - l.y)
        }
        let v = filter.velocity
        lastPressure = model.pressure(s, speedMMPerSec: hypot(v.x, v.y))
        lastFiltered = f
        lastT = s.t
        let c = toCanvas(f)
        // Same point again (finger still): update its pressure instead of stacking duplicates.
        if let lp = points.last, hypot(c.x - lp.p.x, c.y - lp.p.y) < 1e-9 {
            points[points.count - 1].pressure = lastPressure
        } else {
            points.append(StrokePoint(p: c, pressure: lastPressure))
        }
    }

    /// Point extrapolated `ahead` seconds along the filtered velocity, to hide a frame of lag.
    func predicted(ahead: Double) -> StrokePoint? {
        guard let l = lastFiltered, points.count > 2 else { return nil }
        let v = filter.velocity
        let speed = hypot(v.x, v.y)
        guard speed > 20 else { return nil }  // mm/s; don't predict slow or still fingers
        let cap = min(ahead, 0.025)
        return StrokePoint(p: toCanvas(CGPoint(x: l.x + v.x * cap, y: l.y + v.y * cap)), pressure: lastPressure)
    }
}
