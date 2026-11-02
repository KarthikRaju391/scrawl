// Document, camera, gestures and the canvas view.
// Coordinates: canvas units, y up. The page has the trackpad's aspect ratio, so the whole pad
// maps absolutely onto whatever part of the page is visible (all of it at zoom 1).
import AppKit
import MetalKit
import QuartzCore
import simd

// MARK: - Settings (defaults domain local.trackpad-draw; tune after the guided probe run)

struct Settings {
    let d = UserDefaults.standard
    var widthModel: String { d.string(forKey: "widthModel") ?? "mt-pressure" }  // mt-pressure | speed | contact-size
    var inputSource: String { d.string(forKey: "inputSource") ?? "mt" }        // mt | nstouch
    /// Smoothing slider (0...1); oneEuroMinCutoff / oneEuroBeta, if set, override it.
    var smoothing: Double { d.object(forKey: "smoothing") as? Double ?? Smoothing.defaultValue }
    var minCutoff: Double { d.object(forKey: "oneEuroMinCutoff") as? Double ?? Smoothing.params(smoothing).minCutoff }
    // Default (smoothing 0.5) = minCutoff 4, beta 1. History: beta 0.05 left the ink a median 47 pt
    // behind at writing zoom; beta 1 cut it to 7 pt. minCutoff 1 then made the ink creep ~0.6 s
    // after the finger stopped; 4 settles ~4x faster. See tools/filter_sweep.py, bench "settle".
    var beta: Double { d.object(forKey: "oneEuroBeta") as? Double ?? Smoothing.params(smoothing).beta }
    /// Off by default: macOS's resting flag marked real fingers as palms (47 of 73 "palms" in
    /// Karthik's 18:34 session were fingertips), which broke two-finger pinch. Kept for later tuning.
    var palmRejection: Bool { d.bool(forKey: "palmRejection") }
    /// Rejoin snap (experimental): a touch-down soon after a lift and close to it continues exactly
    /// from the lift point (cursive rejoins). `--rejoin on|off` overrides for tests.
    /// "off", "on" (snap at touch-down) or "dir" (snap only if the new stroke continues the previous
    /// one's direction, decided ~1.5 mm in). `--rejoin` overrides for tests; "rejoinMode" in defaults.
    var rejoinMode: String {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--rejoin"), i + 1 < a.count { return a[i + 1] }
        let m = d.string(forKey: "rejoinMode") ?? "off"
        return m == "ab" ? Settings.abCondition : m
    }
    /// Blind A/B: with rejoinMode "ab", each launch secretly picks on or off (logged, never shown).
    static let abCondition = Bool.random() ? "on" : "off"
    var rejoinSnap: Bool { rejoinMode != "off" }
    /// Writing mode moves the page only after the finger has been up this long (0 = immediately). Settings › Wait
    /// before next line sets it, 0.2-1 s (Karthik, 1 Nov); read at each lift, so a change applies at the next one.
    var pauseBeforeMoveMs: Double {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--pause-ms"), i + 1 < a.count, let v = Double(a[i + 1]) { return v }
        if let v = Self.pauseChosenMs { return v }
        if Launch.testing { return Self.defaultPauseMs }   // tests neither save nor read the stored choice
        return d.object(forKey: "pauseBeforeMoveMs") as? Double ?? Self.defaultPauseMs
    }
    static let defaultPauseMs = 400.0
    /// The Settings slider's value this run (saved to "pauseBeforeMoveMs" too, except in tests).
    nonisolated(unsafe) static var pauseChosenMs: Double?
    /// Edge guard: touches that start within this fraction of the pad from any edge are ignored (a resting
    /// palm or thumb). 0 = off; `--edge-guard` overrides (replays of old sessions use 0). The inner area
    /// maps to the whole writing area.
    static let defaultEdgeGuard = 0.05
    var edgeGuard: Double {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--edge-guard"), i + 1 < a.count, let v = Double(a[i + 1]) { return min(max(v, 0), 0.2) }
        return min(max(d.object(forKey: "edgeGuard") as? Double ?? Self.defaultEdgeGuard, 0), 0.2)
    }
    var rejoinRadiusMM: Double { d.object(forKey: "rejoinRadiusMM") as? Double ?? 3.5 }
    var rejoinWindowMs: Double { d.object(forKey: "rejoinWindowMs") as? Double ?? 250 }
    var palmMajor: Double { d.object(forKey: "palmMajorAxis") as? Double ?? 11.0 }
    var palmSize: Double { d.object(forKey: "palmTotal") as? Double ?? 1.4 }
    /// Prediction slider, 0...24 ms (0 = off). Default 12: middle of the lag/overshoot trade-off.
    var predictMs: Double { d.object(forKey: "predictMs") as? Double ?? 12 }
    /// Inklet-style hover: a lighter touch shows the finger ring without inking; ink starts once
    /// MT pressure reaches this (raw units). 0 = off. Only meaningful with MultitouchSupport.
    var inkThreshold: Double { d.object(forKey: "inkThreshold") as? Double ?? 0 }
}

// MARK: - Model

final class Stroke {
    var id = 0                 // stable id (session replay: commits, erases, undo)
    let tool: ToolKind
    let color: SIMD4<Float>   // straight (not premultiplied) RGBA; alpha from the brush
    let size: Double          // diameter in canvas units at full pressure
    let points: [StrokePoint]
    let radii: [Double]
    var mesh = Mesh()
    let bounds: CGRect

    /// `points` are the filtered samples; they're stored interpolated (`maxStep` canvas units).
    init(tool: ToolKind, color: SIMD4<Float>, size: Double, points raw: [StrokePoint], maxStep: Double) {
        let points = catmullRom(raw, maxStep: maxStep)
        self.tool = tool; self.color = color; self.size = size; self.points = points
        radii = strokeRadii(points, size: size, brush: Brush.of(tool))
        let maxR = radii.max() ?? 0
        let xs = points.map(\.p.x), ys = points.map(\.p.y)
        bounds = CGRect(x: xs.min()! - maxR, y: ys.min()! - maxR, width: xs.max()! - xs.min()! + 2 * maxR, height: ys.max()! - ys.min()! + 2 * maxR)
    }

    /// Does a circle at `p` with radius `r` touch this stroke?
    func hit(_ p: CGPoint, r: Double) -> Bool {
        guard bounds.insetBy(dx: -r, dy: -r).contains(p) else { return false }
        for i in points.indices {
            let q = points[i].p
            let reach = r + radii[i]
            if (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) <= reach * reach { return true }
            if i > 0 {  // segment distance, so fast strokes with sparse points still get hit
                let a = points[i - 1].p
                let dx = q.x - a.x, dy = q.y - a.y, l2 = dx * dx + dy * dy
                if l2 > 0 {
                    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
                    let cx = a.x + t * dx - p.x, cy = a.y + t * dy - p.y
                    if cx * cx + cy * cy <= reach * reach { return true }
                }
            }
        }
        return false
    }
}

final class Document {
    /// A page made now (not one being loaded).
    static func new() -> Document { let d = Document(); d.created = clock(); d.edited = d.created; return d }

    private(set) var strokes: [Stroke] = []
    private var undoStack: [[Stroke]] = []
    private var redoStack: [[Stroke]] = []
    /// Bumped on every change to the page's contents (the gallery re-renders a thumbnail only then).
    private(set) var version = 0 { didSet { edited = Self.clock() } }
    /// When the page was made, and last changed (stroke, erase, undo, redo, clear). Pages saved before
    /// 0.1.0 had no dates and keep `created == nil` ("date unknown"); loading never changes either date.
    var created: Date?
    var edited: Date?
    /// You chose to keep writing on this page past a screen (K, or wrote on with the "filled a screen" note showing):
    /// the note doesn't come back for it, also after the notebook is reopened (saved with the page).
    var keptWriting = false
    nonisolated(unsafe) static var clock: () -> Date = { Date() }

    static let maxUndo = 100
    func snapshot() { editedBeforeSnapshot = edited; version += 1; undoStack.append(strokes); if undoStack.count > Self.maxUndo { undoStack.removeFirst() }; redoStack.removeAll() }
    /// An eraser gesture snapshots at its start; if it erased nothing, the page wasn't changed (the overview sorts by it).
    private var editedBeforeSnapshot: Date?
    var undoStackForSave: [[Stroke]] { undoStack }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var redoStackForSave: [[Stroke]] { redoStack }
    func restore(strokes: [Stroke], undo: [[Stroke]], redo: [[Stroke]]) { let e = edited; version += 1; edited = e; self.strokes = strokes; undoStack = undo; redoStack = redo }
    func add(_ s: Stroke) { snapshot(); strokes.append(s) }
    /// Eraser: removes without a new undo step (one step per eraser gesture, taken at its start).
    func remove(where pred: (Stroke) -> Bool) -> Bool {
        let n = strokes.count
        strokes.removeAll(where: pred)
        if strokes.count != n { version += 1 }
        return strokes.count != n
    }
    func clear() { guard !strokes.isEmpty else { return }; snapshot(); strokes.removeAll() }
    /// Scratch-out: the strokes under a scratch go in one undo step (the scratch itself is never added).
    func scratchOut(erasing gone: [Stroke]) { snapshot(); strokes.removeAll { s in gone.contains { $0 === s } } }
    /// Swap the last stroke (no new undo step: it's a correction of the stroke just added).
    func replaceLast(_ s: Stroke) { guard !strokes.isEmpty else { return }; version += 1; strokes[strokes.count - 1] = s }
    func undo() { guard let s = undoStack.popLast() else { return }; version += 1; redoStack.append(strokes); strokes = s }
    func redo() { guard let s = redoStack.popLast() else { return }; version += 1; undoStack.append(strokes); strokes = s }
    /// Put back the state saved by the last snapshot and forget that step (a cancelled eraser gesture).
    func rollbackLastSnapshot() { guard let s = undoStack.popLast() else { return }; if s.count != strokes.count || !zip(s, strokes).allSatisfy({ $0 === $1 }) { version += 1 } else { edited = editedBeforeSnapshot }; strokes = s }
    func dropEmptyUndo() { if let last = undoStack.last, last.count == strokes.count, zip(last, strokes).allSatisfy({ $0 === $1 }) { undoStack.removeLast(); edited = editedBeforeSnapshot } }
}

struct Camera {
    let page: CGSize
    var zoom = 1.0          // 1 = whole page visible
    var center: CGPoint
    static let maxZoom = 12.0

    init(page: CGSize) { self.page = page; center = CGPoint(x: page.width / 2, y: page.height / 2) }
    /// The edge guard's band (fraction of the pad per side). The pad inside it maps onto the whole view;
    /// a stroke that started inside and runs into the band keeps going past the view's edge.
    nonisolated(unsafe) static var margin = 0.0
    static func active(_ n: CGPoint) -> CGPoint {
        let m = margin, k = 1 / (1 - 2 * m)
        return CGPoint(x: (n.x - m) * k, y: (n.y - m) * k)
    }
    static func pad(fromActive a: CGPoint) -> CGPoint {
        let m = margin
        return CGPoint(x: a.x * (1 - 2 * m) + m, y: a.y * (1 - 2 * m) + m)
    }

    var visible: CGRect {
        let w = page.width / zoom, h = page.height / zoom
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }
    /// The page is `page.width` wide, its top edge is at y = page.height, and it is infinitely long
    /// downwards (y keeps decreasing). `page.height` is the visible height at zoom 1.
    mutating func clamp() {
        zoom = min(max(zoom, 1), Self.maxZoom)
        let v = visible
        center.x = min(max(center.x, v.width / 2), page.width - v.width / 2)
        center.y = min(center.y, page.height - v.height / 2)
    }
    /// Two-finger gesture: the canvas point under the previous centroid follows the fingers; the
    /// zoom changes by `ratio` unless the zoom is locked (then it only pans).
    mutating func navigate(from prev: CGPoint, to now: CGPoint, ratio: Double, zoomLocked: Bool) {
        let anchor = canvas(fromPad: prev)
        if !zoomLocked { zoom = min(max(zoom * ratio, 1), Self.maxZoom) }
        let v = visible, a = Self.active(now)
        center = CGPoint(x: anchor.x - a.x * v.width + v.width / 2, y: anchor.y - a.y * v.height + v.height / 2)
        clamp()
    }

    /// Top-left of the page at the current zoom.
    mutating func home() { let v = visible; center = CGPoint(x: v.width / 2, y: page.height - v.height / 2) }
    /// Pad position (0...1, y up) -> canvas point. This is the absolute mapping.
    func canvas(fromPad p: CGPoint) -> CGPoint {
        let v = visible, n = Self.active(p)
        return CGPoint(x: v.minX + n.x * v.width, y: v.minY + n.y * v.height)
    }
}

// MARK: - Tool state (Keep-style: each tool remembers its own color and size)

struct ToolState {
    private static let hex: [Int] = [0x000000, 0x5F6368, 0xD93025, 0xF29900, 0xFDD663, 0x1E8E3E, 0x12B5CB, 0x1A73E8, 0x9334E6, 0xE52592, 0x8D6E63, 0xFFFFFF]
    static let colors: [NSColor] = hex.map { (h: Int) -> NSColor in
        let r = CGFloat((h >> 16) & 255) / 255, g = CGFloat((h >> 8) & 255) / 255, b = CGFloat(h & 255) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    /// Size options in screen points at the zoom where the stroke is drawn (writing zoomed in
    /// keeps the same on-screen width, which is the point of zooming in to write small).
    static let sizes: [ToolKind: [Double]] = [
        .pen: [1.5, 2.5, 4, 6, 9], .marker: [4, 6, 9, 13, 18], .highlighter: [10, 14, 20, 28, 36], .eraser: [8, 14, 22, 32, 44],
        .select: [1, 1, 1, 1, 1],   // no ink: unused
    ]
    var tool: ToolKind = .pen
    var colorIndex: [ToolKind: Int] = [.pen: 0, .marker: 7, .highlighter: 4]
    var sizeIndex: [ToolKind: Int] = [.pen: 1, .marker: 2, .highlighter: 2, .eraser: 2]
    var background = 0  // 0 none, 1 square, 2 dot, 3 ruled
    static let lineWidths = [0.5, 0.75, 1.0]  // writing mode line width, fraction of the page width
    var lineWidthIndex = 2   // 100% (Karthik, 29 Oct)
    var zoomLocked = false

    /// Saved in defaults ("toolState") so the app reopens with the same tools, sizes, colours,
    /// background, line width and zoom lock. (Smoothing/prediction are saved by their sliders.)
    func save(to defaults: UserDefaults = .standard) {
        let d: [String: Any] = ["tool": tool.rawValue, "background": background, "lineWidthIndex": lineWidthIndex, "zoomLocked": zoomLocked,
                                "colorIndex": Dictionary(uniqueKeysWithValues: colorIndex.map { ($0.key.rawValue, $0.value) }),
                                "sizeIndex": Dictionary(uniqueKeysWithValues: sizeIndex.map { ($0.key.rawValue, $0.value) })]
        defaults.set(d, forKey: "toolState")
    }
    static func load(from defaults: UserDefaults = .standard) -> ToolState {
        var t = ToolState()
        guard let d = defaults.dictionary(forKey: "toolState") else { return t }
        if let v = d["tool"] as? String, let k = ToolKind(rawValue: v), k != .select { t.tool = k }   // a launch never starts on Select
        if let v = d["background"] as? Int, (0...3).contains(v) { t.background = v }
        if let v = d["lineWidthIndex"] as? Int, ToolState.lineWidths.indices.contains(v) { t.lineWidthIndex = v }
        if let v = d["zoomLocked"] as? Bool { t.zoomLocked = v }
        // "autoPan" (the sideways pan along a line, removed 28 Oct) may still be in old settings: ignored.
        // "aimFirst" (aim-first mode, removed in 0.1.0) may still be in old settings: ignored.
        for (k, v) in d["colorIndex"] as? [String: Int] ?? [:] { if let kind = ToolKind(rawValue: k), ToolState.colors.indices.contains(v) { t.colorIndex[kind] = v } }
        for (k, v) in d["sizeIndex"] as? [String: Int] ?? [:] { if let kind = ToolKind(rawValue: k), (0..<5).contains(v) { t.sizeIndex[kind] = v } }
        return t
    }

    var sizePt: Double { Self.sizes[tool]![sizeIndex[tool] ?? 2] }
    var color: NSColor { Self.colors[colorIndex[tool] ?? 0] }
}

// MARK: - Gesture engine: contact frames in, strokes / navigation out

final class GestureEngine {
    enum Mode { case idle, hover(Int32), drawing(Int32, Double), navigating, waitLift }
    private(set) var mode = Mode.idle
    var drawingId: Int32? { if case let .drawing(id, _) = mode { return id }; return nil }
    private var palm = Set<Int32>()
    /// Contacts that touched down in the edge band: ignored until they lift (never draw, pan or pinch).
    private(set) var edgeIgnored = Set<Int32>()
    var edgeGuard: () -> Double = { Settings.defaultEdgeGuard }
    static func inBand(_ n: CGPoint, _ g: Double) -> Bool { g > 0 && (n.x < g || n.x > 1 - g || n.y < g || n.y > 1 - g) }
    /// Whether the guard ignores this contact (already ignored, or touching down in the band now).
    func ignoresAtEdge(_ c: Contact) -> Bool { edgeIgnored.contains(c.id) || (!seen.contains(c.id) && Self.inBand(c.norm, edgeGuard())) }
    /// Extra palm signal (macOS resting-touch classification), checked per contact per frame.
    var isPalm: (Contact) -> Bool = { _ in false }
    /// Called once per contact when it lifts: (id, was classified palm, drew a stroke).
    var onContactEnd: ((Int32, Bool, Bool) -> Void)?
    private var drewIds = Set<Int32>()
    private var seen = Set<Int32>()
    private var navPrev: (ids: [Int32], centroid: CGPoint, dist: Double)?
    /// Dead zone (Karthik, 1 Nov: a two- or three-finger double tap nudged the view): two or more fingers move nothing
    /// until their centroid has moved `deadZoneMM` or the distance between them has changed `deadZoneMM` (pad mm),
    /// from where the pair landed. In 35 recorded sessions (4,676 episodes, tools/tap_analysis.py) no tap-shaped
    /// episode got there (most: centroid 1.41 mm, distance 1.67 mm; 1,140 taps), and pans and pinches got there
    /// 25 ms after they began moving (median; p95 158 ms, slow drifts). A 4% distance rule caught 23 taps.
    static let deadZoneMM = 2.0
    private var navStart: (ids: [Int32], centroidMM: CGPoint, dist: Double)?
    private var navLive = false
    var settings = Settings()
    lazy var inkThreshold = settings.inkThreshold

    var onBegin: ((Contact, Double) -> Void)?
    var onMove: ((Contact, Double) -> Void)?
    var onEnd: ((Bool) -> Void)?                 // true = commit, false = discard
    var onNavigate: ((CGPoint, CGPoint, Double) -> Void)?  // prev centroid, new centroid (pad 0...1), zoom ratio
    var strokeLengthMM: () -> Double = { 0 }

    func reset() {
        if case .drawing = mode { onEnd?(false) }
        mode = .idle; palm.removeAll(); edgeIgnored.removeAll(); navPrev = nil; navStart = nil; navLive = false; drewIds.removeAll(); seen.removeAll()
    }

    /// Click to draw: false while it's off, so a finger only aims (hovers) and never inks by touch.
    var canInk: () -> Bool = { true }
    /// Click to draw: a light finger the sensor reports as lifting (5 breaking, 6 lingering) for a moment and then
    /// touching again (seen on Karthik's trackpad after releasing the click: back within 38-149 ms) stays the same
    /// stroke. A real lift goes on to 7 or disappears, and ends it.
    var bridgesLift: () -> Bool = { false }
    static let liftBridge = 0.15
    private var liftSince: Double?
    private var aiming: Contact?, lastT = 0.0
    /// Click to draw: the click is pen-down for the finger that's aiming. The stroke starts where it is now and
    /// goes on (the click released or not) until it lifts. False if no single finger is aiming.
    @discardableResult func beginNow() -> Bool {
        guard case let .hover(id) = mode, let f = aiming, f.id == id else { return false }
        mode = .drawing(id, lastT); drewIds.insert(id); onBegin?(f, lastT)
        return true
    }

    /// Contacts already on the pad when draw mode starts (a resting palm) never draw.
    lazy var palmRejection = settings.palmRejection
    func ignoreUntilLifted(_ ids: Set<Int32>) { guard palmRejection else { return }; palm.formUnion(ids); seen.formUnion(ids) }

    func frame(_ contacts: [Contact], t: Double) {
        if case let .drawing(id, _) = mode, bridgesLift(), contacts.contains(where: { $0.id == id && ($0.state == 5 || $0.state == 6) }) {
            if t - (liftSince ?? t) < Self.liftBridge { liftSince = liftSince ?? t; return }
        }
        liftSince = nil
        let down = contacts.filter(\.isDown)
        let ids = Set(down.map(\.id))
        for id in seen.subtracting(ids) { onContactEnd?(id, palm.contains(id), drewIds.contains(id)) }
        // Edge guard: only where a contact first touches down counts; moving into the band later is fine.
        let g = edgeGuard()
        for c in down where !seen.contains(c.id) && Self.inBand(c.norm, g) { edgeIgnored.insert(c.id) }
        edgeIgnored = edgeIgnored.intersection(ids)
        seen = ids
        drewIds = drewIds.intersection(ids)
        palm = palm.intersection(ids)
        if palmRejection {
            for c in down where c.major > settings.palmMajor || c.size > settings.palmSize || isPalm(c) { palm.insert(c.id) }
        }
        let fingers = down.filter { !palm.contains($0.id) && !edgeIgnored.contains($0.id) }.sorted { $0.id < $1.id }
        lastT = t; aiming = fingers.count == 1 ? fingers[0] : nil

        switch mode {
        case .idle:
            if fingers.count == 1 { mode = .hover(fingers[0].id); hover(fingers, t) }
            else if fingers.count >= 2 { mode = .navigating; navigate(fingers) }
        case .hover:
            hover(fingers, t)
        case let .drawing(id, started):
            let f = fingers.first { $0.id == id }
            // A second finger soon after the first (or before it has moved much) = pinch/pan, not ink.
            if fingers.count >= 2 && (t - started < 0.25 || strokeLengthMM() < 6) {
                onEnd?(false)  // it was the start of a pinch/pan, not a stroke
                mode = .navigating; navPrev = nil; navigate(fingers)
            } else if let f {
                onMove?(f, t)
            } else {
                onEnd?(!palm.contains(id))  // a contact that turned into a palm is discarded
                mode = fingers.isEmpty ? .idle : .waitLift
            }
        case .navigating:
            if fingers.count >= 2 { navigate(fingers) } else { navPrev = nil; navStart = nil; navLive = false; mode = fingers.isEmpty ? .idle : .waitLift }
        case .waitLift:
            if fingers.isEmpty { mode = .idle }
        }
    }

    private func hover(_ fingers: [Contact], _ t: Double) {
        guard case let .hover(id) = mode else { return }
        if fingers.count >= 2 { mode = .navigating; navigate(fingers) }
        else if let f = fingers.first(where: { $0.id == id }) {
            if f.pressure >= inkThreshold && canInk() { mode = .drawing(id, t); drewIds.insert(id); onBegin?(f, t) }
        } else { mode = fingers.isEmpty ? .idle : .waitLift }
    }

    private func navigate(_ fingers: [Contact]) {
        let a = fingers[0], b = fingers[1]
        let c = CGPoint(x: (a.norm.x + b.norm.x) / 2, y: (a.norm.y + b.norm.y) / 2)
        let d = hypot(a.mm.x - b.mm.x, a.mm.y - b.mm.y)
        defer { navPrev = ([a.id, b.id], c, Double(d)) }
        if !navLive {
            // In the dead zone: measured from where this pair landed; a new pair starts it again.
            let cmm = CGPoint(x: (a.mm.x + b.mm.x) / 2, y: (a.mm.y + b.mm.y) / 2)
            guard let s = navStart, s.ids == [a.id, b.id] else { navStart = ([a.id, b.id], cmm, Double(d)); return }
            guard hypot(cmm.x - s.centroidMM.x, cmm.y - s.centroidMM.y) > Self.deadZoneMM || abs(Double(d) - s.dist) > Self.deadZoneMM else { return }
            navLive = true
            return   // out of it: moves count from here (navPrev = now), no jump
        }
        guard let p = navPrev, p.ids == [a.id, b.id] else { return }
        let ratio = p.dist > 5 && d > 5 ? Double(d) / p.dist : 1
        onNavigate?(p.centroid, c, ratio)
    }
}

// MARK: - Input queue

/// Trackpad frames from the driver's thread, drained once per display tick. Delivering them with
/// DispatchQueue.main.async arrived in bursts of 2-4 per tick with most ticks getting none, so the
/// ink advanced in jumps (judder) even on an empty page.
final class InputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(contacts: [Contact], arrival: Double, sensorT: Double)] = []
    private var firmAt: [Int32: Double] = [:], downNow: Set<Int32> = []
    /// Returns true if the queue was empty (the caller may schedule a fallback drain).
    @discardableResult
    func push(_ c: [Contact], arrival: Double, sensorT: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = items.isEmpty; items.append((c, arrival, sensorT))
        downNow = Set(c.filter(\.isDown).map(\.id))
        for x in c where x.isDown && x.pressure >= CanvasView.clickPressure { firmAt[x.id] = arrival }
        firmAt = firmAt.filter { downNow.contains($0.key) || arrival - $0.value < 1 }
        return wasEmpty
    }
    /// Whether a finger that's on the pad now (newest frame, as they arrive: a click can reach the app before the
    /// frames that pressed it are drained) pressed firmly since `since`.
    func firmFingerDown(since: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return downNow.contains { (firmAt[$0] ?? -1) >= since }
    }
    func drain() -> [(contacts: [Contact], arrival: Double, sensorT: Double)] {
        lock.lock(); defer { lock.unlock() }
        let out = items; items.removeAll(keepingCapacity: true); return out
    }
}

// MARK: - Canvas view

final class CanvasView: MTKView {
    private(set) var pages: [Document] = [Document.new()]
    private var pageCameras: [Camera] = []
    var pageCamerasForSave: [Camera] { pageCameras }
    lazy var autosaver = Autosaver(canvas: self)
    /// Something in the notebook changed: save it shortly.
    func markDirty() { if AppPaths.persists { autosaver.changed() }; onDocChanged?() }
    /// After any change to the page (the toolbar dims undo / redo when there's nothing to undo / redo).
    var onDocChanged: (() -> Void)?
    /// A two-finger (undo) or three-finger (redo) double tap was recognised: "Undo", "Redo", "Nothing to undo"...
    var onTapCommand: ((String) -> Void)?
    private var taps = MultiTapDetector()
    /// The undo scrub in progress: where the fingers started (pad mm, x) and the steps taken (- undo, + redo).
    private var scrub: (startX: Double, steps: Int, sliding: Bool, ended: Bool)?
    static let scrubStepMM = 7.0, scrubStartMM = 4.0
    private var tapViewAnchor: Camera?

    func restorePages(_ docs: [Document], cameras: [Camera], index: Int, nextStrokeId: Int) {
        setSelection(nil, "page")
        pages = docs; pageCameras = cameras; pageIndex = index
        if index < cameras.count { camera = cameras[index] }
        nextStrokeIdValue = nextStrokeId
        endWritingLine(); screensFilled = 0; hintDismissedAt = 0; updateScreensFilled()
        needsRender = true; onStatus?()
    }
    private(set) var pageIndex = 0 { didSet { if pageIndex != oldValue { setSelection(nil, "page") } } }
    var doc: Document { pages[pageIndex] }
    /// Called when page, hint or mode status changes (the window updates its labels).
    var onStatus: (() -> Void)?
    // Tests start from the default tools: the person using this Mac may have left the real app on the eraser.
    var tools = Launch.testing ? ToolState() : ToolState.load() {
        didSet {
            if tools.zoomLocked != oldValue.zoomLocked { logger.event(["what": "zoomLock", "locked": tools.zoomLocked, "source": source]) }
            if tools.tool != oldValue.tool || tools.zoomLocked != oldValue.zoomLocked || tools.lineWidthIndex != oldValue.lineWidthIndex {
                act("tools", ["tool": tools.tool.rawValue, "zoomLocked": tools.zoomLocked, "lineWidth": tools.lineWidthIndex])
            }
            // A new width keeps the block and the line (widths count from the block's start); a waiting move is decided
            // again at the next lift, with the new width.
            if tools.lineWidthIndex != oldValue.lineWidthIndex { cancelPendingMove() }
            if tools.tool != oldValue.tool { setSelection(nil, "tool") }   // switching tool clears the selection
            if !testMode { tools.save() }
            needsRender = true
        }
    }
    /// Test modes don't touch the saved settings.
    let testMode = Launch.testing
    private(set) var camera: Camera {
        didSet {  // every zoom change is logged with its cause, to track down "the lock unlocked"
            if camera.center != oldValue.center || camera.zoom != oldValue.zoom {
                markDirty()   // the view of each page is saved too
                let v = camera.visible
                recorder.record(["k": "view", "x": v.minX, "y": v.minY, "w": v.width, "h": v.height, "z": camera.zoom, "src": source], sensorT: frameSensorT)
                onViewChange?(source)
            }
            // One line per gesture (same cause within 0.5 s is coalesced); always when locked.
            if abs(camera.zoom - oldValue.zoom) > 1e-9 {
                let now = CACurrentMediaTime()
                if tools.zoomLocked || source != lastZoomLog.source || now - lastZoomLog.t > 0.5 {
                    logger.event(["what": "zoom", "from": oldValue.zoom, "to": camera.zoom, "source": source, "locked": tools.zoomLocked])
                }
                lastZoomLog = (source, now)
            }
        }
    }
    private var lastZoomLog = (source: "", t: 0.0)
    /// What is changing the camera/tools right now (for the event log).
    var source = "unknown"
    func changing(_ src: String, _ body: () -> Void) { let old = source; source = src; body(); source = old }
    /// The visible part of the page changed, and why ("pinch", "arrow", "autopan"...): the page map follows it.
    var onViewChange: ((String) -> Void)?
    /// A finger went down on / came off the page (draw mode): the page map fades while you draw.
    var onTouching: ((Bool) -> Void)?
    /// Centre the view on a page point, keeping the zoom (the page map).
    func centerView(on p: CGPoint, src: String) {
        cancelPendingMove(); finishSlide()
        changing(src) { var c = camera; c.center = p; c.clamp(); camera = c }
        needsRender = true
    }
    private(set) var renderer: Renderer!
    private let gestures = GestureEngine()
    private var builder: StrokeBuilder?
    var liveStrokePointCountForTest: Int { builder?.points.count ?? 0 }
    /// Test hook: the live stroke's newest filtered point (canvas units), nil between strokes.
    var liveTipForTest: CGPoint? { builder?.points.last?.p }
    private var liveTool: ToolKind = .pen
    private var liveColor = SIMD4<Float>(0, 0, 0, 1)
    private var liveSize = 1.0
    private var contacts: [Contact] = []
    private var countedContacts = 0
    /// Replays of sessions recorded before 0.1.0 (--legacy-edge): lines started at the line's first stroke.
    private var legacyLineLeft: Double?
    private let legacyWriting = CommandLine.arguments.contains("--legacy-edge")
    private var needsRender = true
    private var link: CADisplayLink?
    private(set) var settings = Settings()
    // MARK: click to draw (Settings): a touch only aims until a click. The click turns drawing on and starts the
    // stroke where the finger is; release the click and draw on; lift and touch again for more strokes, no more
    // clicks. `clickDrawTimeout` seconds after the last lift with no writing it turns off; never while writing.

    nonisolated(unsafe) static var clickToDraw = Launch.testing ? false : UserDefaults.standard.bool(forKey: "clickToDraw")
    /// 0 turns drawing off at every lift (a click per stroke).
    nonisolated(unsafe) static var clickDrawTimeout: Double = {
        let v = UserDefaults.standard.object(forKey: "clickToDrawTimeout") as? Double ?? 3
        return Launch.testing ? 3 : min(max(v, 0), 5)
    }()
    /// A real click presses the finger down: the sensor reads 100-150 then (Karthik's trackpad). macOS tap-to-click
    /// sends a click for a light tap (10-80, or after the finger has lifted): that doesn't turn drawing on.
    static let clickPressure = 90.0, clickPressWindow = 0.25
    /// Tap-to-click sends its click as the finger lifts (in Karthik's sessions the finger was gone 0-33 ms after
    /// the click); a real press holds it down longer (66 ms and up). A click-started stroke whose finger lifts
    /// within this is a tap: the stroke is dropped and drawing goes back off.
    static let tapLiftWindow = 0.05
    private var clickStroke: (at: Double, wasOn: Bool)?
    // Aiming is the absolute mapping drawing has always used (the whole pad onto the view), as Karthik aimed
    // before click to draw, two-finger panning the page under it: the mark starts where the finger lands and
    // follows it like a cursor while it's down, and the ink, mapped the same way, starts exactly at it.
    // (7ddf404 carried the mark on from where it last stopped instead; Karthik wants it to start under the finger.)
    private var aimMM: CGPoint?
    var aimPadForTest: CGPoint? { aimMM }
    /// Where the blue mark for a finger is on the page (the ink starts here).
    func markPoint(_ c: Contact) -> CGPoint { camera.canvas(fromPad: c.norm) }
    /// The mark of the one finger down, if exactly one is (test hook).
    var markForTest: CGPoint? { contacts.count == 1 ? markPoint(contacts[0]) : nil }
    private func updateAim() {
        let fingers = contacts.filter { !gestures.ignoresAtEdge($0) }
        if Self.clickToDraw, fingers.count == 1 { aimMM = fingers[0].mm }
    }
    private(set) var clickDrawOn = false
    private var clickDrawLastLift = 0.0
    private var clickDrawTimer: Timer?
    /// When the last click came; the finger's first frame may arrive just after it.
    private var clickAt = -1.0
    func clickDown() {
        guard drawMode, Self.clickToDraw else { return }
        let now = CACurrentMediaTime()
        // Without the private touch API there's no pressure to tell a press from a tap: any click counts.
        // A real click is a press: a finger on the pad now that pressed firmly just before. Tap-to-click's click
        // comes as the finger lifts (often with none down by then) - even a hard quick tap's (90-155).
        if usingMT && !input.firmFingerDown(since: now - Self.clickPressWindow) { act("tapClickIgnored"); return }
        act("click")
        clickStroke = (now, clickDrawOn)
        clickDrawOn = true; clickDrawLastLift = now
        if clickDrawTimer == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.clickDrawTick() }
            RunLoop.main.add(t, forMode: .common); clickDrawTimer = t
        }
        if builder == nil && !gestures.beginNow() { clickAt = now }
    }
    private func clickDrawTick() {
        guard clickDrawOn else { return clickDrawOff() }
        if builder == nil && CACurrentMediaTime() - clickDrawLastLift > Self.clickDrawTimeout { clickDrawOff() }
    }
    /// Session replay (TestSession): a recorded click / click-to-draw-off, without the live press check.
    func replayClick() { CanvasView.clickToDraw = true; clickDrawOn = true; clickDrawLastLift = now(); if builder == nil && !gestures.beginNow() { clickAt = CACurrentMediaTime() } }
    func replayClickDrawOff() { clickDrawOff() }
    private func clickDrawOff() {
        clickDrawTimer?.invalidate(); clickDrawTimer = nil
        guard clickDrawOn else { return }
        clickDrawOn = false; act("clickDrawOff")
    }
    /// The aim mark: a blue ring around the finger.
    static let aimRingColor = SIMD4<Float>(0.10, 0.45, 0.91, 0.8)

    var drawMode = false {
        didSet {
            if drawMode != oldValue { act("drawMode", ["on": drawMode]) }
            if !drawMode { clickDrawOff() }
            // Frames are only handled in draw mode: a finger that lifts outside it would leave the count stale, and a
            // waiting move would never fire (nothing touching means no frames). The next frame recounts.
            if countedContacts > 0 { countedContacts = 0; onTouching?(false) }
            gestures.reset(); contacts = []; needsRender = true
            if drawMode { gestures.ignoreUntilLifted(downIds) }
            // No App Nap / timer coalescing while drawing: input and frames must not be throttled.
            if drawMode, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "drawing")
            } else if !drawMode, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        }
    }
    private var activity: NSObjectProtocol?
    var usingMT = false
    /// Edge guard: fraction of the pad along each edge where new touches are ignored (0 = off).
    var edgeGuardFraction: Double { Camera.margin }
    private var edgeGuardObserver: Any?
    let logger = StrokeLog()
    let input = InputQueue()
    lazy var recorder: SessionRecorder = {
        let r = SessionRecorder(dir: (logger.path as NSString).deletingLastPathComponent)
        r.clock = { [weak self] in self?.now() ?? CACurrentMediaTime() }
        return r
    }()
    func act(_ name: String, _ extra: [String: Any] = [:]) {
        var d = extra; d["k"] = "act"; d["a"] = name
        recorder.record(d, sensorT: frameSensorT)
        onAct?(name, extra)
    }
    /// Every action the session log records (tips, the practice page and usage counts listen here).
    var onAct: ((String, [String: Any]) -> Void)?
    private var pinchedThisTouch = false

    /// Frames encoded / frames the display actually showed (test mode reports both).
    private(set) var renderCount = 0

    /// Frame timing for tests: CPU ms in render(), GPU ms, gaps between presented frames (ms), vertices.
    struct Perf { var cpu: [Double] = []; var build: [Double] = []; var drawableWait: [Double] = []; var gpu: [Double] = []; var gaps: [Double] = []; var verts: [Int] = []; var ticks = 0; var ticksIdle = 0; var tickMaxGap = 0.0; var lastTick = 0.0; var inputsPerTick: [Int] = []; var inputsSinceTick = 0 }
    var perf = Perf()
    private var lastPresented = 0.0

    // MARK: writing mode (see Writing.swift)
    var writingMode = false { didSet { if writingMode != oldValue { act("writingMode", ["on": writingMode]) }; endWritingLine(); needsRender = true } }
    private var lineInk: CGRect?
    private var lineStrokes: [CGRect] = []

    private var camAnim: (from: Camera, to: Camera, start: Double, src: String, duration: Double)?
    private(set) var newLineCount = 0
    /// Where the next line starts (page units: line start x, the line's middle y), once the page has gone there.
    private(set) var nextLineAt: CGPoint?

    // MARK: pages and the screen-height hint
    /// Height of the display the window is on, in canvas units (page width = display width).
    var screenUnits: Double {
        let f = window?.screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        return camera.page.width * f.height / f.width
    }
    /// Screens of this page already filled with writing (shows the "new page?" hint).
    private(set) var screensFilled = 0
    var showPageHint: Bool { !doc.keptWriting && screensFilled > hintDismissedAt }
    private var hintDismissedAt = 0

    private func updateScreensFilled() {
        let lowest = doc.strokes.map(\.bounds.minY).min() ?? camera.page.height
        let n = Int((camera.page.height - lowest) / screenUnits)
        if n != screensFilled { screensFilled = n; onStatus?() }
    }

    func newPage() {
        act("newPage", ["pages": pages.count + 1])
        endWritingLine(); finishSlide()   // a new-line slide still running belongs to this page, not the next
        if pageCameras.count < pages.count { pageCameras.append(camera) } else { pageCameras[pageIndex] = camera }
        pages.append(Document.new())
        pageIndex = pages.count - 1
        changing("newPage") { camera.home() }
        pageCameras.append(camera)
        screensFilled = 0; hintDismissedAt = 0
        markDirty()
        needsRender = true; onStatus?()
    }

    /// A deleted page, kept so ⌘Z can put it back where it was.
    struct DeletedPage { let doc: Document; let camera: Camera; let index: Int; let wasCurrent: Bool; let blank: Document? }

    /// Delete page i. The open page moves to the next one (or the previous, at the end); deleting the only
    /// page leaves one blank page.
    func deletePage(_ i: Int) -> DeletedPage? {
        guard pages.indices.contains(i) else { return nil }
        act("deletePage", ["page": i, "pages": pages.count])
        endWritingLine(); cancelPendingMove(); finishSlide()
        while pageCameras.count < pages.count { pageCameras.append(camera) }
        pageCameras[pageIndex] = camera
        let doc = pages[i], cam = pageCameras[i], wasCurrent = i == pageIndex
        if wasCurrent { setSelection(nil, "page") }
        if pages.count == 1 {
            let blank = Document.new()
            pages = [blank]; pageIndex = 0
            changing("deletePage") { camera.home() }
            pageCameras = [camera]
            afterPageChange()
            return DeletedPage(doc: doc, camera: cam, index: i, wasCurrent: true, blank: blank)
        }
        pages.remove(at: i); pageCameras.remove(at: i)
        if i < pageIndex { pageIndex -= 1 }
        else if wasCurrent {
            pageIndex = min(i, pages.count - 1)
            changing("deletePage") { var c = pageCameras[pageIndex]; if tools.zoomLocked { c.zoom = camera.zoom; c.clamp() }; camera = c }
        }
        afterPageChange()
        return DeletedPage(doc: doc, camera: cam, index: i, wasCurrent: wasCurrent, blank: nil)
    }

    /// Undo a delete: the page goes back in its place (and is opened if it was the open page).
    func restorePage(_ d: DeletedPage) {
        act("restorePage", ["page": d.index])
        endWritingLine(); cancelPendingMove(); finishSlide()
        while pageCameras.count < pages.count { pageCameras.append(camera) }
        pageCameras[pageIndex] = camera
        if let blank = d.blank, pages.count == 1, pages[0] === blank, blank.strokes.isEmpty {
            pages = [d.doc]; pageCameras = [d.camera]; pageIndex = 0
            changing("restorePage") { camera = d.camera }
        } else {
            let at = min(d.index, pages.count)
            pages.insert(d.doc, at: at); pageCameras.insert(d.camera, at: at)
            if d.wasCurrent { pageIndex = at; changing("restorePage") { camera = d.camera } }
            else if at <= pageIndex { pageIndex += 1 }
        }
        afterPageChange()
    }

    private func afterPageChange() {
        screensFilled = 0; hintDismissedAt = 0; updateScreensFilled(); hintDismissedAt = screensFilled
        markDirty()
        needsRender = true; onStatus?()
    }

    /// A page's saved view (the current page: the live camera).
    func cameraForPage(_ i: Int) -> Camera { i == pageIndex || !pageCameras.indices.contains(i) ? camera : pageCameras[i] }

    func goToPage(_ i: Int) {
        act("goToPage", ["page": i])
        guard pages.indices.contains(i), i != pageIndex else { return }
        endWritingLine(); finishSlide()   // a new-line slide still running belongs to this page, not the next
        while pageCameras.count < pages.count { pageCameras.append(camera) }
        pageCameras[pageIndex] = camera
        pageIndex = i
        changing("page") {
            var c = pageCameras[i]
            if tools.zoomLocked { c.zoom = camera.zoom; c.clamp() }  // locked: every page keeps this zoom
            camera = c
        }
        screensFilled = 0; hintDismissedAt = 0; updateScreensFilled(); hintDismissedAt = screensFilled
        markDirty()
        needsRender = true; onStatus?()
    }

    /// `keepRun`: an undo ends the line but not the block you're writing (rewriting the last word keeps the run's start).
    private func endWritingLine(keepRun: Bool = false) {
        lineInk = nil; lineStrokes = []; pendingMove = nil; legacyLineLeft = nil; handPanX = 0
        if !keepRun { runStart = nil }
        segmentStart = runStart; prevLine = nil; lineHeld = false
    }
    /// After the eraser or a scratch-out: the line is what's left of it (as after an undo), so erased ink can't call for
    /// the next line, or be carried on.
    private func pruneWritingLine() {
        func alive(_ rs: [CGRect]) -> [CGRect] { rs.filter { r in doc.strokes.contains { $0.bounds == r } } }
        let left = alive(lineStrokes)
        if left.count != lineStrokes.count { lineStrokes = left; lineInk = left.first.map { f in left.dropFirst().reduce(f) { $0.union($1) } } }
        if lineInk == nil { lineHeld = false }   // nothing left to finish (a held empty line never moved again)
        if let p = prevLine {
            let pl = alive(p.strokes)
            if pl.count != p.strokes.count { prevLine = pl.first.map { f in (pl.dropFirst().reduce(f) { $0.union($1) }, pl) } }
        }
    }
    /// Where the current line started (WritingLayout.segmentStart): the writing run's start.
    private var segmentStart: Double?
    /// Writing run (Karthik, 28 Oct): the x where the first line of the block you're writing now began. Every next
    /// line goes back to it, and every line's width counts from it. A run starts with the first stroke after writing
    /// mode turns on, a page change, a deliberate hand pan to write somewhere new, or writing well above or below the
    /// line; a pause doesn't start one.
    private var runStart: Double?
    /// Where the next-line pan comes for the current line (page x): its width limit, moved along when a deliberate hand
    /// pan moved the line's start. Nil outside writing mode (no width chosen). Drawn as a faint line.
    var lineLimitX: Double? {
        guard writingMode else { return nil }
        var l = WritingLayout(); l.lineWidth = ToolState.lineWidths[tools.lineWidthIndex]; l.segmentStart = segmentStart
        return l.lineEnd(lineLeft: l.lineStart(pageWidth: camera.page.width), pageWidth: camera.page.width)
    }
    static let limitLineColor = SIMD4<Float>(0.10, 0.45, 0.91, 0.22)
    /// Karthik (28 Oct evening): the line only as you approach the width point. It starts to show when the line's ink
    /// (with the stroke being drawn) is within 15% of the line width of the limit (120 page units for ½-page lines),
    /// fading in in proportion to full strength at the limit, and fades out (0.25 s) after the new line or when the
    /// ink is no longer near it (an undo, a line started elsewhere).
    static let limitShowWithin = 0.15, limitFadeSeconds = 0.25
    private var limitAlpha = 0.0, limitAlphaAt = 0.0
    var limitAlphaForTest: Double { limitAlpha }
    /// The current line's rightmost ink (page x), including the stroke being drawn.
    var lineRightForTest: Double? { lineRight }
    private var lineRight: Double? {
        let live = builder?.points.last.map { Double($0.p.x) }
        switch (lineInk?.maxX, live) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
    private var limitTargetAlpha: Double {
        guard let lim = lineLimitX, let right = lineRight else { return 0 }
        let within = Self.limitShowWithin * ToolState.lineWidths[tools.lineWidthIndex] * camera.page.width
        return Double(Self.limitLineColor.w) * min(max(1 - (lim - right) / within, 0), 1)
    }
    /// Moves the drawn strength toward the target (a full fade takes `limitFadeSeconds`); keeps frames coming until there.
    private func stepLimitAlpha() {
        let now = CACurrentMediaTime(), dt = limitAlphaAt == 0 ? 0 : min(now - limitAlphaAt, 0.1)
        limitAlphaAt = now
        let target = limitTargetAlpha, step = dt / Self.limitFadeSeconds * Double(Self.limitLineColor.w)
        limitAlpha = target > limitAlpha ? min(target, limitAlpha + step) : max(target, limitAlpha - step)
        if abs(limitAlpha - target) > 1e-4 { needsRender = true }
    }
    /// Test hook: the limit line as last drawn (page x, and the view's left and width then).
    private(set) var limitDrawnForTest: [Double]?
    /// How far the view's centre moved sideways by hand since the last stroke (page units). Pinches zoom about
    /// the fingers and barely move it; nudges stay under 10% of the view.
    private var handPanX = 0.0
    /// The view's centre after the last stroke (or where the last next-line move went). Any move of yours since then
    /// (two-finger pan in or out of draw mode, a pinch, scrolling, arrows, the page map) counts toward starting a new
    /// block: Karthik scrolled to the middle of the page outside draw mode, and the old block (on the left) stayed.
    private var handRef: CGPoint?
    /// The line a next-line move just left, and whether the current line is one you went back to finish (no automatic
    /// move for it then: you're finishing it by hand).
    private var prevLine: (ink: CGRect, strokes: [CGRect])?
    private var lineHeld = false
    /// Test hook (bench/writingVerify.swift): the writing-mode state, read only.
    struct WritingStateForTest { var runStart, segmentStart: Double?; var lineInk: CGRect?; var lineStrokes: [CGRect]; var prevLine: CGRect?
                                 var lineHeld: Bool; var handPanX: Double; var handRef: CGPoint?; var pending: (target: CGPoint, liftAt: Double)?
                                 var countedContacts: Int; var sliding: Bool }
    var writingStateForTest: WritingStateForTest {
        var p: (target: CGPoint, liftAt: Double)?
        if let m = pendingMove, case .newLine(let c) = m.move { p = (c, m.liftAt) }
        return WritingStateForTest(runStart: runStart, segmentStart: segmentStart, lineInk: lineInk, lineStrokes: lineStrokes, prevLine: prevLine?.ink,
                                   lineHeld: lineHeld, handPanX: handPanX, handRef: handRef, pending: p, countedContacts: countedContacts, sliding: camAnim != nil)
    }

    /// Return in writing mode: next line now (one line down, back to the line start).
    func newLineByHand() {
        guard writingMode else { return }
        act("newLineByHand")
        cancelPendingMove(); finishSlide()
        let v = camera.visible, layout = WritingLayout()
        let midY = lineInk?.midY ?? v.midY
        let pitch = max((lineInk?.height ?? 0) * 1.35, v.height * 0.12)
        applyMove(.newLine(WritingLayout.newLineCenter(lineLeft: runStart ?? layout.lineStart(pageWidth: camera.page.width), lineMidY: midY, pitch: pitch, visible: v)))
    }



    /// Test hook: where a canvas point currently is on the pad (0...1).
    func padPoint(_ p: CGPoint) -> CGPoint {
        let v = camera.visible
        return Camera.pad(fromActive: CGPoint(x: (p.x - v.minX) / v.width, y: (p.y - v.minY) / v.height))
    }

    private func slideCamera(to c: CGPoint, src: String = "autopan") {
        var target = camera; target.center = c; target.clamp()
        camAnim = (camera, target, CACurrentMediaTime(), src, 0.18)
    }
    /// Move and zoom the view to `target` over `duration` (ease out; the zoom changes evenly in log scale).
    func animateCamera(to target: Camera, src: String, duration: Double = 0.25) {
        var t = target; t.clamp()
        camAnim = (camera, t, CACurrentMediaTime(), src, duration)
        needsRender = true
    }

    private func finishSlide() {
        if let a = camAnim { changing(a.src) { camera = a.to }; camAnim = nil }
    }

    private func stepSlide() {
        guard let a = camAnim else { return }
        let t = min((CACurrentMediaTime() - a.start) / a.duration, 1)
        let e = 1 - pow(1 - t, 3)  // ease out
        var c = a.to
        c.zoom = exp(log(a.from.zoom) + (log(a.to.zoom) - log(a.from.zoom)) * e)
        c.center = CGPoint(x: a.from.center.x + (a.to.center.x - a.from.center.x) * e, y: a.from.center.y + (a.to.center.y - a.from.center.y) * e)
        changing(a.src) { camera = c }
        if t >= 1 { camAnim = nil } else { needsRender = true }
    }

    // MARK: resume (draw mode starts where you last wrote)

    /// Where you last wrote on each page (the end of the last stroke, its line's height) and the zoom it
    /// was written at.
    private var lastInk: [ObjectIdentifier: (point: CGPoint, zoom: Double)] = [:]
    /// The view when draw mode last ended.
    private var viewAtDrawExit: Camera?
    /// Tests that check views don't want draw mode to move them (the robot turns it on).
    var resumeOnDrawStart = !Launch.testing
    /// Settings › Start draw mode where I last wrote (on by default): off, draw mode starts at the view you left.
    nonisolated(unsafe) static var resumeLastPoint = Launch.testing ? true : (UserDefaults.standard.object(forKey: "resumeLastPoint") as? Bool ?? true)
    static let resumeDefaultZoom = 3.0

    /// The view draw mode should start at: the last word's end 40% across and its line 57.5% down, at the
    /// zoom you wrote it at. Nil (stay) if the page is empty, if that's in view already, or if you've zoomed
    /// in somewhere else since draw mode ended (you chose that spot).
    func resumeTarget() -> Camera? {
        guard resumeOnDrawStart, Self.resumeLastPoint, let last = doc.strokes.last else { return nil }
        let info = lastInk[ObjectIdentifier(doc)] ?? (CGPoint(x: last.bounds.maxX, y: last.bounds.midY), Self.resumeDefaultZoom)
        let sameAsExit = viewAtDrawExit.map { abs($0.center.x - camera.center.x) < 0.5 && abs($0.center.y - camera.center.y) < 0.5 && abs($0.zoom - camera.zoom) < 1e-3 } ?? true
        guard sameAsExit || camera.zoom <= 1.05 else { return nil }
        var t = camera
        if !tools.zoomLocked { t.zoom = max(info.zoom, 1) }
        let w = t.page.width / t.zoom, h = t.page.height / t.zoom
        t.center = CGPoint(x: info.point.x + 0.1 * w, y: info.point.y + (WritingLayout.lineFromTop - 0.5) * h)
        t.clamp()
        if abs(t.zoom - camera.zoom) < 1e-3 && camera.visible.insetBy(dx: w * 0.05, dy: h * 0.05).contains(info.point) { return nil }
        return t
    }
    func noteDrawExit() { viewAtDrawExit = camera }

    private(set) var presentedCount = 0

    // Timing of the frame being handled: arrival (latency) and sensor time (filter).
    private var frameArrival = 0.0
    private var frameSensorT = 0.0
    // Latency bookkeeping: arrival time of the newest sample not yet on screen.
    private var pendingArrival: Double?

    static let pageUnits = CGSize(width: 1600, height: 1600 / (124.8 / 76.8))

    override init(frame: NSRect, device: MTLDevice?) {
        camera = Camera(page: Self.pageUnits)
        camera.home()
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        guard let r = Renderer(view: self) else { fatalError("Metal unavailable") }
        renderer = r
        clearStencil = 0
        isPaused = true                 // driven by our display link, only when something changed
        enableSetNeedsDisplay = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 3
        (layer as? CAMetalLayer)?.displaySyncEnabled = true
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
        wireGestures()
    }
    required init(coder: NSCoder) { fatalError() }

    /// Where the trackpad's active area lands in this view: the largest rectangle with the pad's shape
    /// that fits, centred left-right and at the top (in a tall window the page top meets the window top,
    /// and the rest of the window shows the page continuing below, instead of off-page space above it). The paper fills the whole view; outside this rectangle it shows the page around
    /// it at the same scale (reach it by panning). Same rule windowed (any shape) and in full screen: no stretch.
    var padRect: CGRect {
        let a = Self.pageUnits.width / Self.pageUnits.height
        var w = bounds.width, h = w / a
        if h > bounds.height { h = bounds.height; w = h * a }
        return CGRect(x: (bounds.width - w) / 2, y: bounds.height - h, width: w, height: h)
    }
    /// Screen points per canvas unit at zoom 1.
    var ptPerUnit: Double { max(padRect.width, 1) / camera.page.width }
    /// The part of the page drawn in the view (the pad's area, `camera.visible`, plus the paper around it).
    var renderRect: CGRect { renderRect(for: camera) }
    func renderRect(for cam: Camera) -> CGRect {
        let v = cam.visible, r = padRect, k = v.width / max(r.width, 1)
        return CGRect(x: v.minX - r.minX * k, y: v.minY - r.minY * k, width: bounds.width * k, height: bounds.height * k)
    }
    /// Page point under a view point.
    func canvasPoint(fromView p: CGPoint) -> CGPoint {
        let rr = renderRect
        return CGPoint(x: rr.minX + p.x / bounds.width * rr.width, y: rr.minY + p.y / bounds.height * rr.height)
    }
    /// View point of a page point.
    func viewPoint(fromCanvas c: CGPoint) -> CGPoint {
        let rr = renderRect
        return CGPoint(x: (c.x - rr.minX) / rr.width * bounds.width, y: (c.y - rr.minY) / rr.height * bounds.height)
    }
    /// Test hook: whether the last frame drew the pad-area outline, and where (view points).
    private(set) var outlineDrawn: CGRect?
    /// Test hook: the page rectangle the last frame was drawn with (what the renderer maps onto the view).
    private(set) var renderedRect: CGRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        link = displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    private var predictAhead = 0.0

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        perf.ticks += 1
        if perf.lastTick > 0 { perf.tickMaxGap = max(perf.tickMaxGap, (now - perf.lastTick) * 1000) }
        perf.lastTick = now
        drainInput()
        if !needsRender && camAnim == nil { perf.ticksIdle += 1 }
        perf.inputsPerTick.append(perf.inputsSinceTick); perf.inputsSinceTick = 0
        advanceClock()
        if camAnim != nil { stepSlide(); needsRender = true }
        guard needsRender, !renderingPaused else { return }
        needsRender = false
        // Prediction slider at 0 = draw only where the finger has been (no look-ahead at all).
        predictAhead = settings.predictMs <= 0 ? 0 : max(l.targetTimestamp - CACurrentMediaTime(), 0) + settings.predictMs / 1000
        // MTKView.draw() calls draw(_:) and then releases currentDrawable. Rendering outside it
        // (paused view) kept re-presenting the first drawable: nothing new ever reached the screen.
        draw()
    }

    override func draw(_ dirtyRect: NSRect) { render(predictAhead: predictAhead) }

    func setNeedsRender() { needsRender = true }
    /// Draw the current page now, presented with the current Core Animation transaction: whatever else changes in the
    /// window this turn (a transition's picture removed, the overview hidden) reaches the screen in the same frame as
    /// the page. Otherwise the canvas showed the page it drew before for a frame or two (Karthik, 30 Oct).
    func drawNowWithTransaction() {
        renderingPaused = false
        presentsWithTransaction = true
        needsRender = false
        draw()
        DispatchQueue.main.async { [weak self] in self?.presentsWithTransaction = false }
    }

    /// Arrow keys: pan by 10% of the view (a whole view with `screen`), like scrolling a document (→ shows what's
    /// to the right, ↓ what's further down). Clamped like any pan (page sides and top); never a new line or a
    /// page change: a pending writing-mode move is dropped.
    func panByArrow(dx: Int, dy: Int, screen: Bool) {
        cancelPendingMove(); finishSlide()
        let v = camera.visible, f = screen ? 1.0 : 0.1
        changing("arrow") { camera.center.x += Double(dx) * f * v.width; camera.center.y -= Double(dy) * f * v.height; camera.clamp() }
        if writingMode { handPanX += abs(camera.center.x - (v.midX)) }   // moved by hand
        needsRender = true
    }
    /// While the pages overview covers the canvas (and during its transitions): no frames. Each frame waits
    /// on the window server for a drawable, which stalled the transition's animation by ~40 ms.
    var renderingPaused = false { didSet { if !renderingPaused { needsRender = true } } }

    private var lastDrain = 0.0
    private func drainInput() {
        lastDrain = CACurrentMediaTime()
        let frames = input.drain()
        if !frames.isEmpty { lastMTFrameAt = lastDrain }
        guard !inputStalled else { return }   // switched to NSTouch: late MT frames would double the input
        for f in frames { handle(f.contacts, arrival: f.arrival, sensorT: f.sensorT) }
    }
    /// Fallback when display ticks stop (window covered, display link paused): process queued
    /// input anyway, so gestures and strokes never wait on the screen.
    /// Tests: process everything queued before reading counts.
    func flushInputForTest() { drainInput(); finishSlide(); recorder.flush() }

    func drainIfStale() {
        if CACurrentMediaTime() - lastDrain > 0.04 { drainInput() }
    }

    // MARK: input

    /// MultitouchSupport frames, already on the main thread.
    /// Contacts down right now, tracked even outside draw mode.
    private var downIds = Set<Int32>()

    func handle(_ cs: [Contact], arrival: Double, sensorT: Double) {
        downIds = Set(cs.filter(\.isDown).map(\.id))
        guard drawMode else { return }
        frameArrival = arrival
        frameSensorT = sensorT
        recorder.record(["k": "touch", "c": cs.map { [Int($0.id), Int($0.state), ($0.norm.x * 10000).rounded() / 10000, ($0.norm.y * 10000).rounded() / 10000, ($0.pressure * 10).rounded() / 10] }], sensorT: sensorT)
        perf.inputsSinceTick += 1
        contacts = cs.filter(\.isDown)
        updateAim()
        // Only fingers the edge guard counts: a palm resting on the edge must neither cancel nor hold
        // back a pending page move.
        let counted = contacts.filter { !gestures.ignoresAtEdge($0) }
        if (countedContacts > 0) != !counted.isEmpty { onTouching?(!counted.isEmpty) }
        countedContacts = counted.count
        if countedContacts > 0 { finishSlide(); cancelPendingMove() }
        // Multi-finger taps: the view at the start of each touch episode, to undo any nudge a tap gave it.
        if !counted.isEmpty && tapViewAnchor == nil { tapViewAnchor = camera }
        if let ev = taps.frame(counted, t: arrival) {
            if let c = tapViewAnchor { changing("tap") { camera = c } }   // a tap is not a pan or a pinch
            switch ev {
            case .hold(2):
                // Undo scrub: slide left to step back through history, right to step forward, live.
                let x = counted.map(\.mm.x).reduce(0, +) / Double(counted.count)
                scrub = (x, 0, false, false)   // armed: it starts when the fingers slide (a resting hold does nothing)
            case .doubleTap(2):
                act("gestureUndo"); let could = doc.canUndo; undo(); onTapCommand?(could ? "Undo" : "Nothing to undo")
            case .doubleTap(3):
                act("gestureRedo"); let could = doc.canRedo; redo(); onTapCommand?(could ? "Redo" : "Nothing to redo")
            default: break
            }
        }
        if var sc = scrub {
            // Only the two fingers that held count. If one lifts, the scrub is over (what's shown stays) and
            // the other finger does nothing until it lifts too.
            if counted.count == 2 && !sc.ended {
                let x = counted.map(\.mm.x).reduce(0, +) / Double(counted.count)
                if !sc.sliding && abs(x - sc.startX) >= Self.scrubStartMM { sc.sliding = true; act("scrubStart"); onTapCommand?("← Undo · Redo →") }
                let target = sc.sliding ? Int(((x - sc.startX) / Self.scrubStepMM).rounded(.towardZero)) : 0
                let was = sc.steps
                while sc.steps > target && doc.canUndo { undo(); sc.steps -= 1 }
                while sc.steps < target && doc.canRedo { redo(); sc.steps += 1 }
                if sc.steps != target { sc.startX = x - Double(sc.steps) * Self.scrubStepMM }   // at an end of history
                if sc.steps != was { act("scrubStep", ["steps": sc.steps]); onTapCommand?(sc.steps < 0 ? "Undo ×\(-sc.steps)" : sc.steps > 0 ? "Redo ×\(sc.steps)" : "← Undo · Redo →") }
            } else if !sc.ended {
                sc.ended = true
                if sc.sliding { act("scrubEnd", ["steps": sc.steps]) }
            }
            if counted.isEmpty { scrub = nil; tapViewAnchor = nil } else { scrub = sc }
            if let c = tapViewAnchor { camera = c }
            gestures.frame([], t: arrival)   // no pan, pinch or ink while scrubbing
            needsRender = true
            return
        }
        if counted.isEmpty { tapViewAnchor = nil; if pinchedThisTouch { snapZoomAfterPinch() }; pinchedThisTouch = false }
        gestures.frame(cs, t: arrival)
        needsRender = true
    }

    // NSTouch fallback (public API, no pressure): used when MultitouchSupport is unavailable, turned
    // off (inputSource=nstouch), or silently not delivering (see the stall check below).
    private var nsIds: [Int: Int32] = [:]
    /// macOS's resting-touch classification (palm/thumb), pad-normalized, from NSTouch events.
    private var restingNorm: [CGPoint] = []
    private var restingAt = 0.0
    /// When MultitouchSupport last delivered a frame, and since when NSTouch has seen a finger down without one.
    var lastMTFrameAt = 0.0
    private var nsSinceMT: (first: Double, samples: Int)?   // NSTouch finger-down samples since MT's last frame
    /// MultitouchSupport started but its frames don't arrive (e.g. blocked by a future macOS): called once,
    /// after switching to the public touch path so drawing keeps working.
    var onInputStalled: (() -> Void)?
    private(set) var inputStalled = false

    struct NSTouchSample { var key: Int; var norm: CGPoint; var deviceSize: CGSize; var resting: Bool }

    private func nsTouchFrame(_ e: NSEvent) {
        let ts = e.touches(matching: .touching, in: self).map {
            NSTouchSample(key: $0.identity.hash, norm: $0.normalizedPosition, deviceSize: $0.deviceSize, resting: $0.isResting)
        }
        touchSamples(ts, timestamp: e.timestamp)
    }

    /// Touches from NSTouch (or a test). Device size is in points (1/72 in).
    func touchSamples(_ ts: [NSTouchSample], timestamp: Double, now: Double = CACurrentMediaTime()) {
        guard drawMode else { return }
        if usingMT {  // MT draws; NSTouch only contributes Apple's resting flags for palm rejection
            restingNorm = ts.filter(\.resting).map(\.norm)
            restingAt = now
            // NSTouch has seen a finger down in 30+ events over 0.5 s+ (one stroke or several short ones),
            // and MT has sent nothing since the first of them: MT is stalled.
            if ts.contains(where: { !$0.resting }) {
                if let n = nsSinceMT, lastMTFrameAt < n.first { nsSinceMT = (n.first, n.samples + 1) } else { nsSinceMT = (now, 1) }
                if let n = nsSinceMT, n.samples >= 30, now - n.first > 0.5 {
                    usingMT = false; inputStalled = true; nsSinceMT = nil
                    logger.event(["what": "inputStalled", "fallback": "nstouch"])
                    onInputStalled?()
                }
            }
            if usingMT { return }
        }
        var out: [Contact] = []
        if let d = ts.first?.deviceSize, d.width > 0 {   // this trackpad's size (the gesture thresholds are in mm)
            Multitouch.padMM = CGSize(width: d.width * 25.4 / 72, height: d.height * 25.4 / 72)
        }
        for t in ts where !t.resting {
            let id = nsIds[t.key] ?? { let n = Int32(nsIds.count + 1); nsIds[t.key] = n; return n }()
            out.append(Self.contact(fromTouch: t, id: id))
        }
        if out.isEmpty { nsIds.removeAll() }
        handle(out, arrival: now, sensorT: timestamp)
    }

    /// NSTouch -> the same Contact MultitouchSupport produces (no pressure; size from the device).
    static func contact(fromTouch t: NSTouchSample, id: Int32) -> Contact {
        let mmPerPt = 25.4 / 72
        return Contact(id: id, state: 4, norm: t.norm, mm: CGPoint(x: t.norm.x * t.deviceSize.width * mmPerPt, y: t.norm.y * t.deviceSize.height * mmPerPt),
                       pressure: 0, size: 0.5, major: 8)
    }
    override func touchesBegan(with e: NSEvent) { nsTouchFrame(e) }
    override func touchesMoved(with e: NSEvent) { nsTouchFrame(e) }
    override func touchesEnded(with e: NSEvent) { nsTouchFrame(e) }
    override func touchesCancelled(with e: NSEvent) { nsTouchFrame(e) }
    // In draw mode physical clicks land on the frozen cursor over this view: swallow them.
    override func mouseDown(with e: NSEvent) {
        if drawMode { clickDown(); return }
        onBackgroundClick?()
        // Select, outside draw mode: a pointer drag on the page makes the rectangle.
        if tools.tool == .select { selectBegin(at: canvasPoint(fromView: convert(e.locationInWindow, from: nil))); return }
        super.mouseDown(with: e)
    }
    override func mouseDragged(with e: NSEvent) {
        if !drawMode, selectDrag != nil { selectMove(to: canvasPoint(fromView: convert(e.locationInWindow, from: nil))); return }
        super.mouseDragged(with: e)
    }
    override func mouseUp(with e: NSEvent) {
        if !drawMode, selectDrag != nil { selectMove(to: canvasPoint(fromView: convert(e.locationInWindow, from: nil))); selectEnd(true); return }
        super.mouseUp(with: e)
    }
    /// A click on the page outside draw mode (closes an open toolbar panel; the width picked there stays).
    var onBackgroundClick: (() -> Void)?
    /// In draw mode a click draws (click to draw), even if it's the click that brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { drawMode }
    // A two-finger tap is also the system's right-click; in draw mode it lands on the frozen pointer here.
    override func rightMouseDown(with e: NSEvent) { if !drawMode { super.rightMouseDown(with: e) } }
    // Outside draw mode the usual trackpad gestures pan (two-finger scroll) and zoom (pinch).
    // In draw mode the same gestures come from MultitouchSupport instead, and these are ignored.
    override func scrollWheel(with e: NSEvent) {
        guard !drawMode else { return }
        cancelPendingMove(); finishSlide()   // moved by hand: a waiting next-line move is dropped (as for arrows and the map)
        let k = 1 / (ptPerUnit * camera.zoom)
        changing("scroll") { camera.center.x -= e.scrollingDeltaX * k; camera.center.y += e.scrollingDeltaY * k; camera.clamp() }
        needsRender = true
    }
    override func magnify(with e: NSEvent) {
        guard !drawMode, !tools.zoomLocked else { return }
        cancelPendingMove(); finishSlide()
        let p = convert(e.locationInWindow, from: nil)
        let anchor = canvasPoint(fromView: p), r = padRect
        changing("magnify") {   // the page point under the pointer stays under it
            var c = camera
            c.zoom = min(max(c.zoom * (1 + e.magnification), 1), Camera.maxZoom)
            let v = c.visible, k = v.width / max(r.width, 1)
            c.center = CGPoint(x: anchor.x - (p.x - r.minX) * k + v.width / 2, y: anchor.y - (p.y - r.minY) * k + v.height / 2)
            c.clamp(); camera = c
        }
        if e.phase == .ended { snapZoomAfterPinch() }
        needsRender = true
    }

    /// Is this contact where macOS currently sees a resting touch? (fresh within 0.25 s, 6% of the pad)
    private func appleResting(_ c: Contact) -> Bool {
        guard CACurrentMediaTime() - restingAt < 0.25 else { return false }
        return restingNorm.contains { hypot($0.x - c.norm.x, ($0.y - c.norm.y) * 76.8 / 124.8) < 0.06 }
    }

    /// Per-contact features for tuning palm rejection: peak size/major, Apple resting seen.
    private var contactStats: [Int32: (maxSize: Double, maxMajor: Double, resting: Bool, start: Double)] = [:]

    private func wireGestures() {
        Camera.margin = Settings().edgeGuard
        gestures.edgeGuard = { Camera.margin }
        // The Edge guard slider writes the default; pick it up for the next touch.
        edgeGuardObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            let g = Settings().edgeGuard
            if g != Camera.margin { Camera.margin = g }
        }
        gestures.isPalm = { [weak self] c in
            guard let self else { return false }
            let r = self.appleResting(c)
            let old = self.contactStats[c.id]
            self.contactStats[c.id] = (max(old?.maxSize ?? 0, c.size), max(old?.maxMajor ?? 0, c.major), (old?.resting ?? false) || r, old?.start ?? CACurrentMediaTime())
            return r
        }
        gestures.onContactEnd = { [weak self] id, palm, drew in
            guard let self, let st = self.contactStats.removeValue(forKey: id) else { return }
            self.logger.contact(["id": Int(id), "maxSize": st.maxSize, "maxMajor": st.maxMajor, "appleResting": st.resting,
                                 "palm": palm, "drew": drew, "durationS": CACurrentMediaTime() - st.start])
        }
        gestures.strokeLengthMM = { [weak self] in self?.builder?.lengthMM ?? self?.selectDrag?.lengthMM ?? 0 }
        gestures.onBegin = { [weak self] c, t in self?.beginStroke(c, t) }
        gestures.canInk = { [weak self] in guard let self else { return true }; return !Self.clickToDraw || self.clickDrawOn || CACurrentMediaTime() - self.clickAt < 0.15 }
        gestures.bridgesLift = { [weak self] in Self.clickToDraw && self?.clickDrawOn == true }
        gestures.onMove = { [weak self] c, t in self?.moveStroke(c, t) }
        gestures.onEnd = { [weak self] commit in
            guard let self else { return }
            // The click's finger lifted at once: it was tap-to-click on a hard tap, not a press. No ink, and drawing
            // goes back to how it was.
            if let c = self.clickStroke, self.frameArrival - c.at < Self.tapLiftWindow {
                self.clickStroke = nil; self.act("tapClickUndone"); self.endStroke(false)
                if !c.wasOn { self.clickDrawOff() }
                return
            }
            self.clickStroke = nil; self.endStroke(commit)
        }
        gestures.onNavigate = { [weak self] prev, now, ratio in
            guard let self else { return }
            let cx0 = self.camera.center.x
            let z0 = self.camera.zoom
            self.changing("pinch") { self.camera.navigate(from: prev, to: now, ratio: ratio, zoomLocked: self.tools.zoomLocked) }  // moved by hand: the next stroke starts a new line where it lands
            if abs(self.camera.zoom - z0) > 1e-6 && !self.pinchedThisTouch { self.pinchedThisTouch = true; self.act("pinchZoom") }
            // Sideways pans by hand only (a pinch's zoom moves the view around the fingers; that isn't a pan).
            if self.writingMode && abs(self.camera.zoom - z0) < 1e-9 { self.handPanX += abs(self.camera.center.x - cx0) }
        }
    }

    private func sample(_ c: Contact, _ t: Double) -> InputSample {
        InputSample(mm: CGPoint(x: c.mm.x + strokeOffset.x, y: c.mm.y + strokeOffset.y), t: frameSensorT, pressure: c.pressure, size: c.size)
    }

    /// Where the last stroke lifted (pad mm, after any snap) and when (sensor clock).
    private var lastLift: (mm: CGPoint, t: Double, dir: CGPoint)?
    /// Raw (unshifted) samples of the current stroke, and a pending rejoin waiting for the direction check.
    // MARK: selection (the Select tool)

    /// The selected rectangle, in page units (y up): it stays on the page through pans and zooms. Never an edit: no undo
    /// step, nothing saved. Cleared by Esc (outside draw mode), another tool, another page, or a tap with Select.
    private(set) var selection: CGRect?
    /// Called when the selection appears, changes or goes (the floating bar follows it).
    var onSelectionChange: ((CGRect?) -> Void)?
    /// The drag making a new selection: its first corner, and the selection it replaces (put back if the drag turns into
    /// a pan or pinch).
    private var selectDrag: (anchor: CGPoint, before: CGRect?, startMM: CGPoint, lengthMM: Double)?
    var selectionDragging: Bool { selectDrag != nil }
    /// A drag shorter than this (view points) is a tap: it clears the selection.
    static let selectTapPt = 4.0
    func setSelection(_ r: CGRect?, _ why: String) {
        guard r != selection else { return }
        selection = r
        act("selection", r.map { ["why": why, "x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? ["why": why, "cleared": true])
        needsRender = true
        onSelectionChange?(r)
    }
    private func selectBegin(at p: CGPoint, mm: CGPoint = .zero) {
        selectDrag = (p, selection, mm, 0)
        setSelection(CGRect(origin: p, size: .zero), "drag")
    }
    private func selectMove(to p: CGPoint, mm: CGPoint = .zero) {
        guard let d = selectDrag else { return }
        selectDrag?.lengthMM = max(d.lengthMM, hypot(mm.x - d.startMM.x, mm.y - d.startMM.y))
        setSelection(CGRect(x: min(d.anchor.x, p.x), y: min(d.anchor.y, p.y), width: abs(p.x - d.anchor.x), height: abs(p.y - d.anchor.y)), "drag")
    }
    private func selectEnd(_ commit: Bool) {
        guard let d = selectDrag else { return }
        selectDrag = nil
        if !commit { setSelection(d.before, "cancelled"); return }   // it became a pan or pinch: the old selection stays
        let k = ptPerUnit * camera.zoom   // view points per page unit
        if let s = selection, max(s.width, s.height) * k < Self.selectTapPt { setSelection(nil, "tap") }
    }
    /// The page point under a pad position: the absolute mapping ink uses (the whole pad onto the view).
    private func pagePoint(_ c: Contact) -> CGPoint {
        let pad = Multitouch.padMM
        return camera.canvas(fromPad: CGPoint(x: c.mm.x / pad.width, y: c.mm.y / pad.height))
    }
    /// Test: the page point a pad contact maps to (the selection's corner).
    func pagePointForTest(_ c: Contact) -> CGPoint { pagePoint(c) }
    func setSelectionForTest(_ r: CGRect?) { setSelection(r, "test") }

    private var rawSamples: [InputSample] = []
    private var pendingSnap: CGPoint?
    private var makeBuilder: (() -> StrokeBuilder)?
    /// Offset applied to every sample of the current stroke (pad mm): non-zero when snapped.
    private var strokeOffset = CGPoint.zero
    private(set) var rejoinCount = 0
    private var nextStrokeIdValue = 1
    var nextStrokeIdForSave: Int { nextStrokeIdValue }

    private func beginStroke(_ c: Contact, _ t: Double) {
        clickAt = -1
        finishSlide()
        if tools.tool == .select { selectBegin(at: pagePoint(c), mm: c.mm); return }   // a rectangle, no ink
        strokeOffset = .zero; pendingSnap = nil; rawSamples = []
        if settings.rejoinSnap, tools.tool != .eraser, let l = lastLift,
           (frameSensorT - l.t) * 1000 < settings.rejoinWindowMs, hypot(c.mm.x - l.mm.x, c.mm.y - l.mm.y) < settings.rejoinRadiusMM {
            let snap = CGPoint(x: l.mm.x - c.mm.x, y: l.mm.y - c.mm.y)   // continue exactly from the lift
            if settings.rejoinMode == "dir" { pendingSnap = snap } else { strokeOffset = snap; rejoinCount += 1 }
        }
        let cam = camera, pad = Multitouch.padMM
        let model = makeWidthModel(usingMT ? settings.widthModel : "speed")
        let st = settings
        makeBuilder = {
            StrokeBuilder(model: model, minCutoff: st.minCutoff, beta: st.beta) { mm in
                cam.canvas(fromPad: CGPoint(x: mm.x / pad.width, y: mm.y / pad.height))
            }
        }
        builder = makeBuilder!()
        liveTool = tools.tool
        let col = tools.color.usingColorSpace(.sRGB)!
        liveColor = SIMD4(Float(col.redComponent), Float(col.greenComponent), Float(col.blueComponent), Float(Brush.of(liveTool).alpha))
        liveSize = tools.sizePt / (ptPerUnit * camera.zoom)
        if liveTool == .eraser { doc.snapshot() }
        logger.begin(tool: liveTool.rawValue, model: model.name, zoom: camera.zoom, ptPerUnit: ptPerUnit, backing: Double(window?.backingScaleFactor ?? 2))
        act("strokeBegin", ["tool": liveTool.rawValue, "padX": c.norm.x, "padY": c.norm.y, "snapX": strokeOffset.x, "snapY": strokeOffset.y, "pendingSnap": pendingSnap != nil])
        moveStroke(c, t)
    }

    private func moveStroke(_ c: Contact, _ t: Double) {
        if selectDrag != nil { selectMove(to: pagePoint(c), mm: c.mm); return }
        guard builder != nil else { return }
        let raw = InputSample(mm: c.mm, t: frameSensorT, pressure: c.pressure, size: c.size)
        rawSamples.append(raw)
        if let snap = pendingSnap, let l = lastLift {
            // Direction check ~1.5 mm in: snap only if this stroke carries on the previous one's direction.
            let first = rawSamples[0].mm, dx = c.mm.x - first.x, dy = c.mm.y - first.y, len = hypot(dx, dy)
            if len >= 1.5 {
                pendingSnap = nil
                let cosTurn = (dx * l.dir.x + dy * l.dir.y) / len
                logger.event(["what": "rejoinCandidate", "cos": cosTurn, "stroke": doc.strokes.count, "snapLen": hypot(snap.x, snap.y)])
                if cosTurn > 0.3 {
                    strokeOffset = snap; rejoinCount += 1
                    builder = makeBuilder!()   // rebuild from the start with the offset (only ~1.5 mm drawn so far)
                    for r in rawSamples.dropLast() { builder!.add(InputSample(mm: CGPoint(x: r.mm.x + snap.x, y: r.mm.y + snap.y), t: r.t, pressure: r.pressure, size: r.size)) }
                }
            }
        }
        builder!.add(sample(c, t))
        logger.sample(t: frameSensorT, mm: c.mm, pressure: c.pressure, size: c.size, out: builder!.points.last!)
        pendingArrival = frameArrival
        if liveTool == .eraser, let p = builder!.points.last {
            let r = liveSize / 2
            let hit = doc.strokes.filter { $0.hit(p.p, r: r) }.map(\.id)
            if !hit.isEmpty, doc.remove(where: { $0.hit(p.p, r: r) }) { act("erase", ["ids": hit]); markDirty(); needsRender = true }
        }
    }

    private func endStroke(_ commit: Bool) {
        if selectDrag != nil { selectEnd(commit); return }
        defer {
            builder = nil; needsRender = true; clickDrawLastLift = CACurrentMediaTime()
            if Self.clickDrawTimeout == 0 { clickDrawOff() }   // 0 s: every lift turns drawing off
        }
        guard var b = builder else { return }
        b.finish()
        logger.end(committed: commit)
        act("strokeEnd", ["committed": commit, "index": commit ? doc.strokes.count : -1, "snapX": strokeOffset.x, "snapY": strokeOffset.y])
        if liveTool == .eraser {
            // Cancelled (it became a two- or three-finger gesture: a pan, pinch or tap): nothing it erased stays erased.
            if commit { doc.dropEmptyUndo(); pruneWritingLine() } else { doc.rollbackLastSnapshot(); markDirty() }
            return
        }
        guard commit, !b.points.isEmpty else { return }
        if liveTool != .eraser, let raw = b.lastRaw {
            // Direction the stroke was heading at the end: last raw point vs the one ~1.5 mm earlier.
            var dir = CGPoint.zero
            if let back = rawSamples.reversed().first(where: { hypot($0.mm.x + strokeOffset.x - raw.x, $0.mm.y + strokeOffset.y - raw.y) >= 1.5 }) {
                let dx = raw.x - (back.mm.x + strokeOffset.x), dy = raw.y - (back.mm.y + strokeOffset.y), l = hypot(dx, dy)
                dir = CGPoint(x: dx / l, y: dy / l)
            }
            lastLift = (raw, frameSensorT, dir)
        }
        // Scratch-out (Scratch.swift): a fast zig-zag over ink erases what it covers; the zig-zag isn't kept.
        if ScratchOut.enabled, liveTool == .pen || liveTool == .marker,
           ScratchOut.shapeMatches(ScratchOut.features(mm: rawSamples.map(\.mm), t: rawSamples.map(\.t))) {
            let unitsPerMM = camera.visible.width / (Multitouch.padMM.width * (1 - 2 * Camera.margin))
            if let gone = ScratchOut.covered(scratch: b.points.map(\.p), in: doc.strokes, reach: ScratchOut.reachMM * unitsPerMM) {
                doc.scratchOut(erasing: gone)
                pruneWritingLine()
                fadeOut(gone)
                act("scratchOut", ["ids": gone.map(\.id)])
                markDirty()
                onTapCommand?("Scratched out")
                return
            }
        }
        let s = Stroke(tool: liveTool, color: liveColor, size: liveSize, points: b.points, maxStep: smoothStep)
        s.mesh = renderer.makeMesh(strokeMesh(s.points, radii: s.radii, pxPerUnit: meshPxPerUnit))
        s.id = nextStrokeIdValue; nextStrokeIdValue += 1
        doc.add(s)
        lastInk[ObjectIdentifier(doc)] = (CGPoint(x: s.bounds.maxX, y: s.bounds.midY), camera.zoom)
        if showPageHint { doc.keptWriting = true; onStatus?() }   // wrote on with the note showing: keeping this page
        act("commit", ["id": s.id, "page": pageIndex])
        markDirty()
        updateScreensFilled()
        // Writing mode, now that the finger is up (see Writing.swift).
        if writingMode {
            let vh = camera.visible.height
            var continued = false
            // Back on the line a next-line move just left, at or after its end: you're finishing it. It goes on (the block
            // stays), with no automatic move for it (Karthik: a new block started there and every next line went off the
            // page's edge).
            if lineInk == nil, let p = prevLine, abs(s.bounds.midY - p.ink.midY) < max(p.ink.height * 0.6, vh * 0.05),
               s.bounds.minX >= p.ink.maxX - max(p.ink.height, camera.visible.width * 0.03) {
                lineInk = p.ink; lineStrokes = p.strokes; lineHeld = true; continued = true
                act("lineContinued", ["x": s.bounds.minX])
            }
            if lineInk == nil { prevLine = nil }
            // A stroke well above or below the current line (you moved there yourself): a new line there. Just below it
            // and near the block's start, it's the block's next line; anywhere else, a new block.
            // A line you went back to finish (held): anything written under its ink is a new line too. Written where the
            // move put you (one line down: 0.12 of the view when that's more than 1.35 line heights), the next line was
            // within the usual 1.2x and joined the held line, which then took every line below it, with no move again.
            if let line = lineInk, abs(s.bounds.midY - line.midY) > max(line.height, vh * 0.12) * 1.2 || (lineHeld && s.bounds.midY < line.minY) {
                let nextOfBlock = s.bounds.midY < line.midY && line.midY - s.bounds.midY < max(line.height, vh * 0.12) * 3.5 &&
                    runStart.map { abs(s.bounds.minX - $0) < camera.page.width * WritingLayout.newRunAway } == true
                lineInk = nil; lineStrokes = []; legacyLineLeft = s.bounds.minX; lineHeld = false; prevLine = nil
                if !nextOfBlock { segmentStart = nil; runStart = nil }   // a new run here
            }
            // A deliberate hand pan (10% of the view or more) and then writing somewhere new on the line: the line
            // starts here now, and ends ½ / ¾ of the page later. Carrying on where the line ended keeps its start: to
            // its right, anything within 10% of the page is carrying on (Karthik, 29 Oct, page 18: with no sideways
            // auto-pan, panning right by hand is how a zoomed-in line goes on; his next word after the pan came 4.9% of
            // the page after the line's end, past the old 8%-of-the-view gap, and started a block there).
            let vw = camera.visible.width
            let movedByHand = continued ? 0 : max(handPanX, handRef.map { abs(camera.center.x - $0.x) } ?? 0)
            // (1 - 1e-9): one arrow press moves exactly 10% of the view; rounding left it just short in 39% of positions.
            if movedByHand >= vw * WritingLayout.deliberatePan * (1 - 1e-9) {
                if let line = lineInk {
                    let gap = max(line.height * 1.5, vw * 0.08)
                    if s.bounds.minX > line.maxX + max(gap, camera.page.width * WritingLayout.newRunAway) || s.bounds.maxX < line.minX - gap {
                        runStart = s.bounds.minX; lineInk = nil; lineStrokes = []   // a new run where you moved to
                        act("lineMoved", ["x": s.bounds.minX])
                    }
                } else if runStart.map({ abs(s.bounds.minX - $0) > camera.page.width * WritingLayout.newRunAway }) ?? true {
                    // No line open (a new line just came, or nothing written yet), and you write well away from the
                    // block's start: a new run there. Near it (a pinch or nudge, then the next line a little off its
                    // start), the block stays (it drifted to 56% of the page with each line before).
                    runStart = s.bounds.minX
                    act("lineMoved", ["x": s.bounds.minX])
                }
            }
            handPanX = 0; handRef = camera.center
            if runStart == nil { runStart = s.bounds.minX }   // the run's first stroke
            segmentStart = runStart
            if legacyLineLeft == nil { legacyLineLeft = s.bounds.minX }
            let line = lineInk.map { $0.union(s.bounds) } ?? s.bounds
            lineInk = line
            lineStrokes.append(s.bounds)
            var layout = WritingLayout()
            layout.lineWidth = ToolState.lineWidths[tools.lineWidthIndex]
            layout.legacyStrokeEdge = legacyWriting
            layout.segmentStart = segmentStart
            layout.wordHint = typicalWordWidth
            let start = legacyWriting ? legacyLineLeft! : (runStart ?? layout.lineStart(pageWidth: camera.page.width))
            let move = layout.after(stroke: s.bounds, line: line, lineStrokes: lineStrokes, lineLeft: start,
                                    visible: camera.visible, pageWidth: camera.page.width)
            if move == .none || lineHeld { pendingMove = nil }
            else if settings.pauseBeforeMoveMs <= 0 { applyMove(move) }
            else {
                // A line break waits for a word gap: the usual pause after the lift (Settings, 400 ms by default) (a touch before then cancels it),
                // once the line's ink has crossed the limit (Karthik, 29 Oct, option A), or reached 93% of the page with
                // the limit near the page's edge: the same pause (Karthik on b03bac2: "don't wait for 1.5s, users won't
                // know that"). Written ink never moves.
                let wait = settings.pauseBeforeMoveMs
                pendingMove = (move, now(), wait)
                act("movePending", ["kind": move.kind, "right": line.maxX, "limit": layout.lineEnd(lineLeft: start, pageWidth: camera.page.width),
                                    "runStart": runStart ?? -1, "segStart": segmentStart ?? -1, "width": layout.lineWidth])
            }
        }
    }

    // MARK: page moves wait for a pause

    /// The writing-mode move waiting for the finger to stay up `pauseBeforeMoveMs`.
    private var pendingMove: (move: WritingLayout.Move, liftAt: Double, waitMs: Double)?
    /// A typical word's width on the lines written so far (for a line that has one word yet).
    private var typicalWordWidth: Double?
    /// The clock for that wait (replaced by a virtual clock when replaying recorded sessions).
    var now: () -> Double = { CACurrentMediaTime() }
    private(set) var movesCancelled = 0

    /// A finger touched down before the pause was up: no move now; it's re-decided at the next lift.
    private func cancelPendingMove() {
        guard pendingMove != nil else { return }
        pendingMove = nil; movesCancelled += 1; act("moveCancelled")
    }

    /// Called every display tick (and by the replay driver): run the pending move once the pause is up.
    func advanceClock() {
        guard let p = pendingMove, countedContacts == 0, now() - p.liftAt >= p.waitMs / 1000 else { return }
        pendingMove = nil
        applyMove(p.move)
    }

    private func applyMove(_ move: WritingLayout.Move) {
        switch move {
        case .none: break
        case .newLine(let c):
            if let line = lineInk {
                let ws = WritingLayout.words(lineStrokes, gap: WritingLayout.wordGap(lineStrokes, visible: camera.visible)).map { $0.end - $0.start }.sorted()
                if ws.count >= 2, ws[ws.count / 2] <= line.width * WritingLayout.maxWordShare { typicalWordWidth = ws[ws.count / 2] }
            }
            if let line = lineInk { nextLineAt = CGPoint(x: runStart ?? WritingLayout().lineStart(pageWidth: camera.page.width), y: line.midY - max(line.height * 1.35, camera.visible.height * 0.12)) }
            act("newLine", ["toX": c.x, "toY": c.y]); newLineCount += 1
            if let l = lineInk { prevLine = (l, lineStrokes) }
            lineHeld = false; lineInk = nil; lineStrokes = []; segmentStart = runStart; handPanX = 0   // the run goes on
            // The app's own move isn't yours: remember where the view will really be (the camera stops at the page's
            // edge; the unclamped target looked like a hand move of 10%+ and started a new block at the page's edge).
            var target = camera; target.center = c; target.clamp(); handRef = target.center
            slideCamera(to: c, src: "newLine")
        }
        needsRender = true
    }

    // MARK: drawing

    /// Device pixels per canvas unit now, x2 headroom so circles stay round when zooming in later.
    private var meshPxPerUnit: Double { ptPerUnit * camera.zoom * Double(window?.backingScaleFactor ?? 2) * 2 }

    /// Interpolation step: 1.5 screen points at the zoom the stroke is drawn at.
    private var smoothStep: Double { 1.5 / (ptPerUnit * camera.zoom) }

    static let selectionTint = SIMD4<Float>(0.10, 0.45, 0.91, 0.08), selectionLine = SIMD4<Float>(0.10, 0.45, 0.91, 0.9)
    /// Test hook: the selection rectangle the last frame drew (page units), if any.
    private(set) var selectionDrawnForTest: CGRect?
    private func premul(_ c: SIMD4<Float>) -> SIMD4<Float> { SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w) }

    private func render(predictAhead: Double) {
        let cpu0 = CACurrentMediaTime()
        let vis = renderRect   // everything drawn in the view, not just the pad's area
        var items: [Renderer.DrawItem] = []
        // Dashed line at every screen height down the page: where a screen's worth of writing ends.
        do {
            let k = 1 / (ptPerUnit * camera.zoom), su = screenUnits
            var verts: [SIMD2<Float>] = []
            var n = max(1, Int(((camera.page.height - vis.maxY) / su).rounded(.down)))
            while camera.page.height - Double(n) * su >= vis.minY {
                let y = camera.page.height - Double(n) * su
                if y <= vis.maxY {
                    var x = max(vis.minX, 0)
                    while x < min(vis.maxX, camera.page.width) {
                        let r = CGRect(x: x, y: y - 0.75 * k, width: 6 * k, height: 1.5 * k)
                        let a = SIMD2<Float>(Float(r.minX), Float(r.minY)), b = SIMD2<Float>(Float(r.maxX), Float(r.minY))
                        let c = SIMD2<Float>(Float(r.maxX), Float(r.maxY)), d = SIMD2<Float>(Float(r.minX), Float(r.maxY))
                        verts += [a, b, c, a, c, d]
                        x += 12 * k
                    }
                }
                n += 1
            }
            if !verts.isEmpty { items.append(.init(mesh: Mesh(), verts: verts, color: premul(SIMD4(0.55, 0.6, 0.68, 0.6)))) }
        }
        // Writing mode: a faint vertical line where the next-line pan will come (the line's width limit), 1 pt wide at any
        // zoom, only as the line's ink nears it (fading in), gone after the new line. The live view only: exports,
        // thumbnails and the page map render the page without it.
        stepLimitAlpha()
        if limitAlpha > 0.002, let x = lineLimitX, x > vis.minX, x < vis.maxX {
            let w = 0.5 / (ptPerUnit * camera.zoom)
            let a = SIMD2<Float>(Float(x - w), Float(vis.minY)), b = SIMD2<Float>(Float(x + w), Float(vis.minY))
            let c = SIMD2<Float>(Float(x + w), Float(vis.maxY)), d = SIMD2<Float>(Float(x - w), Float(vis.maxY))
            var col = Self.limitLineColor; col.w = Float(limitAlpha)
            items.append(.init(mesh: Mesh(), verts: [a, b, c, a, c, d], color: premul(col)))
            limitDrawnForTest = [x, vis.minX, vis.width]
        } else { limitDrawnForTest = nil }
        items += doc.strokes.compactMap { s in
            guard s.bounds.intersects(vis) else { return nil }  // off-screen (most of the page when zoomed in)
            if s.mesh.buffer == nil { s.mesh = renderer.makeMesh(strokeMesh(s.points, radii: s.radii, pxPerUnit: meshPxPerUnit)) }
            return .init(mesh: s.mesh, verts: nil, color: premul(s.color))
        }
        // The selection: a light tint and a dashed outline, 1 pt at any zoom. The live view only (exports never show it).
        selectionDrawnForTest = nil
        if let s = selection, s.intersects(vis) {
            let k = 1 / (ptPerUnit * camera.zoom)   // page units per view point
            func quad(_ r: CGRect) -> [SIMD2<Float>] {
                let a = SIMD2<Float>(Float(r.minX), Float(r.minY)), b = SIMD2<Float>(Float(r.maxX), Float(r.minY))
                let c = SIMD2<Float>(Float(r.maxX), Float(r.maxY)), d = SIMD2<Float>(Float(r.minX), Float(r.maxY))
                return [a, b, c, a, c, d]
            }
            items.append(.init(mesh: Mesh(), verts: quad(s), color: premul(Self.selectionTint)))
            var dash: [SIMD2<Float>] = []
            let on = 5 * k, step = 9 * k, w = 1 * k
            for (a, b, horizontal) in [(s.minX, s.maxX, true), (s.minY, s.maxY, false)] {
                var x = a
                while x < b {
                    let e = min(x + on, b)
                    if horizontal { dash += quad(CGRect(x: x, y: s.minY - w / 2, width: e - x, height: w)) + quad(CGRect(x: x, y: s.maxY - w / 2, width: e - x, height: w)) }
                    else { dash += quad(CGRect(x: s.minX - w / 2, y: x, width: w, height: e - x)) + quad(CGRect(x: s.maxX - w / 2, y: x, width: w, height: e - x)) }
                    x += step
                }
            }
            items.append(.init(mesh: Mesh(), verts: dash, color: premul(Self.selectionLine)))
            selectionDrawnForTest = s
        }
        if !ghosts.isEmpty {
            let t = CACurrentMediaTime()
            ghosts = ghosts.filter { t - $0.start < Self.fadeSeconds }
            for g in ghosts where g.stroke.bounds.intersects(vis) {
                if g.stroke.mesh.buffer == nil { g.stroke.mesh = renderer.makeMesh(strokeMesh(g.stroke.points, radii: g.stroke.radii, pxPerUnit: meshPxPerUnit)) }
                var c = g.stroke.color; c.w *= Float(1 - (t - g.start) / Self.fadeSeconds)
                items.append(.init(mesh: g.stroke.mesh, verts: nil, color: premul(c)))
            }
            if !ghosts.isEmpty { needsRender = true }
        }
        if let b = builder, liveTool != .eraser, !b.points.isEmpty {
            var pts = b.points
            if let p = b.predicted(ahead: predictAhead) { pts.append(p) }
            pts = catmullRom(pts, maxStep: smoothStep)
            let radii = strokeRadii(pts, size: liveSize, brush: Brush.of(liveTool), live: true)
            items.append(.init(mesh: Mesh(), verts: strokeMesh(pts, radii: radii, pxPerUnit: meshPxPerUnit), color: premul(liveColor)))
        }
        if drawMode {  // finger markers: where each finger is on the page (there is no cursor)
            let ringR = 5 / (ptPerUnit * camera.zoom)
            for c in contacts {
                let p = markPoint(c)
                let r = liveTool == .eraser && builder != nil ? liveSize / 2 : ringR
                var v: [SIMD2<Float>] = []
                let n = 32
                for k in 0..<n {
                    let a0 = Double(k) / Double(n) * 2 * .pi, a1 = Double(k + 1) / Double(n) * 2 * .pi
                    let w = 1.2 / (ptPerUnit * camera.zoom)
                    func pt(_ a: Double, _ rr: Double) -> SIMD2<Float> { SIMD2(Float(p.x + cos(a) * rr), Float(p.y + sin(a) * rr)) }
                    v += [pt(a0, r - w), pt(a0, r + w), pt(a1, r + w), pt(a0, r - w), pt(a1, r + w), pt(a1, r - w)]
                }
                items.append(.init(mesh: Mesh(), verts: v, color: premul(Self.aimRingColor)))
            }
        }
        let arrival = pendingArrival
        pendingArrival = nil
        renderCount += 1
        // Draw mode: a faint outline where the trackpad's area is (the paper around it is reached by panning).
        outlineDrawn = nil
        if drawMode {
            let v = camera.visible, k = 1 / (ptPerUnit * camera.zoom), t = 1.0 * k
            var q: [SIMD2<Float>] = []
            for r in [CGRect(x: v.minX, y: v.minY, width: v.width, height: t), CGRect(x: v.minX, y: v.maxY - t, width: v.width, height: t),
                      CGRect(x: v.minX, y: v.minY, width: t, height: v.height), CGRect(x: v.maxX - t, y: v.minY, width: t, height: v.height)] {
                let a = SIMD2<Float>(Float(r.minX), Float(r.minY)), b = SIMD2<Float>(Float(r.maxX), Float(r.minY))
                let c = SIMD2<Float>(Float(r.maxX), Float(r.maxY)), d = SIMD2<Float>(Float(r.minX), Float(r.maxY))
                q += [a, b, c, a, c, d]
            }
            items.append(.init(mesh: Mesh(), verts: q, color: premul(SIMD4(0.10, 0.45, 0.91, 0.22))))
            outlineDrawn = padRect
        }
        renderedRect = vis
        perf.build.append((CACurrentMediaTime() - cpu0) * 1000)
        renderer.render(in: self, visible: vis, background: tools.background,
                        spacing: 48, pxPerUnit: ptPerUnit * camera.zoom * Double(window?.backingScaleFactor ?? 2),
                        page: CGRect(x: 0, y: -1e9, width: camera.page.width, height: camera.page.height + 1e9),
                        items: items, presented: { [weak self] t in
                            guard t > 0 else { return }  // 0 = dropped frame
                            DispatchQueue.main.async {
                                guard let self else { return }
                                self.presentedCount += 1
                                if let a = arrival { self.logger.latency((t - a) * 1000) }
                                if self.lastPresented > 0 { self.perf.gaps.append((t - self.lastPresented) * 1000) }
                                self.lastPresented = t
                            }
                        }, gpuMs: { [weak self] ms in DispatchQueue.main.async { self?.perf.gpu.append(ms) } })
        perf.cpu.append((CACurrentMediaTime() - cpu0) * 1000)
        perf.drawableWait.append(renderer.lastDrawableWaitMs)
        perf.verts.append(items.reduce(0) { $0 + $1.mesh.count + ($1.verts?.count ?? 0) })
    }

    // MARK: commands

    func undo() {
        logger.event(["what": "undo", "strokesBefore": doc.strokes.count])   // the "that landed wrong" signal
        act("undo", ["strokes": doc.strokes.count])
        let before = doc.strokes
        let line = lineStrokes
        doc.undo(); endWritingLine(keepRun: true); updateScreensFilled(); markDirty(); needsRender = true
        // The line stays open with what's left of it (rewriting its last word, or panning on after the undo, carries the
        // line on; with it closed, the next stroke after a pan looked like a new block).
        let left = line.filter { r in doc.strokes.contains { $0.bounds == r } }
        if writingMode, let first = left.first {
            lineStrokes = left; lineInk = left.dropFirst().reduce(first) { $0.union($1) }
        }
        fadeOut(before.filter { s in !doc.strokes.contains { $0 === s } })
    }
    /// Strokes that just went (undo, scratch-out) fade out over 120 ms, so you see what was taken away.
    private var ghosts: [(stroke: Stroke, start: Double)] = []
    static let fadeSeconds = 0.12
    var ghostCountForTest: Int { ghosts.count }
    private func fadeOut(_ gone: [Stroke]) {
        let t = CACurrentMediaTime()
        ghosts = ghosts.filter { t - $0.start < Self.fadeSeconds } + gone.map { ($0, t) }
        if !ghosts.isEmpty { needsRender = true }
    }
    func redo() { act("redo", ["strokes": doc.strokes.count]); doc.redo(); markDirty(); needsRender = true }
    func clearPage() {
        act("clear", ["strokes": doc.strokes.count]); doc.clear(); markDirty(); endWritingLine(); updateScreensFilled(); needsRender = true }
    /// Dismiss the "new page?" hint until another screen fills up.
    func dismissPageHint() { hintDismissedAt = screensFilled; doc.keptWriting = true; markDirty(); onStatus?() }
    /// Test: add a finished stroke as if drawn at the current zoom.
    func testAddStroke(_ pts: [StrokePoint], tool: ToolKind = .pen, color: SIMD4<Float> = SIMD4(0, 0, 0, 1), sizePt: Double? = nil) {
        let s = Stroke(tool: tool, color: color, size: (sizePt ?? tools.sizePt) / (ptPerUnit * camera.zoom), points: pts, maxStep: smoothStep)
        s.id = nextStrokeIdValue; nextStrokeIdValue += 1
        doc.add(s)
        updateScreensFilled()
    }
    func resetPerf() { perf = Perf(); lastPresented = 0 }

    /// Test baseline: same zoom and starting place as writing mode, without writing mode.
    /// Replay: put the view exactly where a recorded view record says (scrolls/magnify done outside draw mode).
    func setVisibleForReplay(x: Double, y: Double, w: Double, z: Double) {
        changing("replay") {
            var c = camera; c.zoom = z
            let v = c.visible
            c.center = CGPoint(x: x + v.width / 2, y: y + v.height / 2)
            camera = c
        }
    }

    func setZoomForTest(settingsWritingZoom: Bool) {
        changing("test") { camera.zoom = 3; camera.home(); camera.clamp() }; needsRender = true
    }

    // MARK: zoom as a percentage (100% = the page's width fills the view)

    static let zoomPresets: [Double] = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8]
    /// "300%": rounded to 10% (5% under 200%), so it reads cleanly and is easy to pick again.
    static func zoomText(_ z: Double) -> String {
        let p = z * 100, step = p < 200 ? 5.0 : 10.0
        return "\(Int((p / step).rounded() * step))%"
    }
    /// Zoom to `z`, keeping the middle of the view where it is (the zoom menu).
    func setZoom(_ z: Double, src: String = "zoomMenu") {
        guard !tools.zoomLocked else { NSSound.beep(); return }
        var t = camera; t.zoom = min(max(z, 1), Camera.maxZoom); t.clamp()
        animateCamera(to: t, src: src, duration: 0.2)
        finishSlideSoon()
    }
    private func finishSlideSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.finishSlide() } }
    /// A pinch that ends within 4% of a preset lands on it (297% -> 300%), so a zoom you like is easy to hit again.
    func snapZoomAfterPinch() {
        guard !tools.zoomLocked, let p = Self.zoomPresets.first(where: { abs(camera.zoom - $0) / $0 < 0.04 }), abs(camera.zoom - p) > 1e-9 else { return }
        changing("zoomSnap") { var c = camera; c.zoom = p; c.clamp(); camera = c }
        needsRender = true
    }

    func resetZoom() {
        guard !tools.zoomLocked else { NSSound.beep(); return }  // locked means locked
        changing("zoomToPage") { camera.zoom = 1; camera.clamp() }; needsRender = true
    }

    /// Full page to PNG at `scale` px per canvas unit (CPU, same union fill as the GPU path).
}

// MARK: - Session recorder (test build): everything needed to replay a drawing session exactly

/// session-<time>.jsonl next to the stroke log. Every record has "m" (CACurrentMediaTime) and "t"
/// (sensor clock, same as the stroke log's sample times):
///   {"k":"touch","c":[[id,state,x,y,pressure],...]}  every trackpad frame in draw mode (pad 0...1)
///   {"k":"view","x":minX,"y":minY,"w":w,"h":h,"z":zoom,"src":cause}  every change of the visible page area
///   {"k":"act","a":name,...}  undo/redo/clear, stroke begin/end, auto-pan, new line, tool, modes, pages
/// Only this app's own state is recorded (no screen capture).
final class SessionRecorder {
    private var fh: FileHandle?
    private var buffer: [Data] = []
    private var lastFlush = 0.0
    let path: String
    init(dir: String) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        path = "\(dir)/session-\(f.string(from: Date())).jsonl"
    }
    var clock: () -> Double = { CACurrentMediaTime() }   // the canvas clock (virtual in replays)
    func record(_ d: [String: Any], sensorT: Double) {
        guard Diagnostics.enabled else { return }
        var d = d; d["m"] = clock(); d["t"] = sensorT
        if let data = try? JSONSerialization.data(withJSONObject: d) { buffer.append(data) }
        if CACurrentMediaTime() - lastFlush > 0.5 { flush() }
    }
    func flush() {
        lastFlush = CACurrentMediaTime()
        guard !buffer.isEmpty else { return }
        if fh == nil { FileManager.default.createFile(atPath: path, contents: nil); fh = FileHandle(forWritingAtPath: path) }
        for b in buffer { fh?.write(b); fh?.write(Data("\n".utf8)) }
        buffer.removeAll(keepingCapacity: true)
    }
}

// MARK: - Stroke log (data/ for the jitter and latency checks)

final class StrokeLog {
    private var fh: FileHandle?
    private var cur: [String: Any] = [:]
    private var samples: [[Double]] = []
    private var latencies: [Double] = []
    let path: String

    init() {
        let dir = Diagnostics.logsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        path = "\(dir)/strokes-\(f.string(from: Date())).jsonl"
    }

    func begin(tool: String, model: String, zoom: Double, ptPerUnit: Double, backing: Double) {
        cur = ["tool": tool, "model": model, "zoom": zoom, "ptPerUnit": ptPerUnit, "backing": backing]
        samples = []; latencies = []
    }
    /// t, raw mm x/y, pressure, size, output canvas x/y, output pressure
    func sample(t: Double, mm: CGPoint, pressure: Double, size: Double, out: StrokePoint) {
        samples.append([t, mm.x, mm.y, pressure, size, out.p.x, out.p.y, out.pressure])
    }
    func latency(_ ms: Double) { latencies.append(ms) }
    /// One line per notable change (kind "event"): zoom changes, zoom lock on/off, with the cause.
    func event(_ d: [String: Any]) {
        var d = d; d["kind"] = "event"; d["time"] = ISO8601DateFormatter().string(from: Date())
        write(d)
    }
    /// One line per lifted contact (kind "contact"), for tuning palm rejection.
    func contact(_ d: [String: Any]) {
        var d = d; d["kind"] = "contact"
        write(d)
    }
    private func write(_ d: [String: Any]) {
        guard Diagnostics.enabled else { return }
        if fh == nil {
            FileManager.default.createFile(atPath: path, contents: nil)
            fh = FileHandle(forWritingAtPath: path)
        }
        if let data = try? JSONSerialization.data(withJSONObject: d) { fh?.write(data); fh?.write(Data("\n".utf8)) }
    }
    func end(committed: Bool) {
        cur["committed"] = committed
        cur["samples"] = samples
        // Presented handlers can arrive after the stroke ends; these are the ones seen so far.
        cur["latencyMs"] = latencies
        write(cur)
    }
}
