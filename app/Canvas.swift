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
    /// Writing mode moves the page only after the finger has been up this long (0 = immediately).
    var pauseBeforeMoveMs: Double {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--pause-ms"), i + 1 < a.count, let v = Double(a[i + 1]) { return v }
        return d.object(forKey: "pauseBeforeMoveMs") as? Double ?? 400
    }
    /// Writing-mode pan trigger (fraction of the view); `--pan-edge` overrides (replays of old sessions use 0.85).
    var panEdge: Double {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--pan-edge"), i + 1 < a.count, let v = Double(a[i + 1]) { return v }
        return d.object(forKey: "panEdge") as? Double ?? 0.70
    }
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
    nonisolated(unsafe) static var clock: () -> Date = { Date() }

    static let maxUndo = 100
    func snapshot() { version += 1; undoStack.append(strokes); if undoStack.count > Self.maxUndo { undoStack.removeFirst() }; redoStack.removeAll() }
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
    func rollbackLastSnapshot() { guard let s = undoStack.popLast() else { return }; if s.count != strokes.count || !zip(s, strokes).allSatisfy({ $0 === $1 }) { version += 1 }; strokes = s }
    func dropEmptyUndo() { if let last = undoStack.last, last.count == strokes.count, zip(last, strokes).allSatisfy({ $0 === $1 }) { undoStack.removeLast() } }
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
    ]
    var tool: ToolKind = .pen
    var colorIndex: [ToolKind: Int] = [.pen: 0, .marker: 7, .highlighter: 4]
    var sizeIndex: [ToolKind: Int] = [.pen: 1, .marker: 2, .highlighter: 2, .eraser: 2]
    var background = 0  // 0 none, 1 square, 2 dot, 3 ruled
    static let lineWidths = [0.5, 0.75, 1.0]  // writing mode line width, fraction of the page width
    var lineWidthIndex = 1
    var zoomLocked = false
    var autoPan = AutoPan.centre

    /// Saved in defaults ("toolState") so the app reopens with the same tools, sizes, colours,
    /// background, line width and zoom lock. (Smoothing/prediction are saved by their sliders.)
    func save(to defaults: UserDefaults = .standard) {
        let d: [String: Any] = ["tool": tool.rawValue, "background": background, "lineWidthIndex": lineWidthIndex, "zoomLocked": zoomLocked, "autoPan": autoPan.rawValue,
                                "colorIndex": Dictionary(uniqueKeysWithValues: colorIndex.map { ($0.key.rawValue, $0.value) }),
                                "sizeIndex": Dictionary(uniqueKeysWithValues: sizeIndex.map { ($0.key.rawValue, $0.value) })]
        defaults.set(d, forKey: "toolState")
    }
    static func load(from defaults: UserDefaults = .standard) -> ToolState {
        var t = ToolState()
        guard let d = defaults.dictionary(forKey: "toolState") else { return t }
        if let v = d["tool"] as? String, let k = ToolKind(rawValue: v) { t.tool = k }
        if let v = d["background"] as? Int, (0...3).contains(v) { t.background = v }
        if let v = d["lineWidthIndex"] as? Int, ToolState.lineWidths.indices.contains(v) { t.lineWidthIndex = v }
        if let v = d["zoomLocked"] as? Bool { t.zoomLocked = v }
        if let v = d["autoPan"] as? Int, let a = AutoPan(rawValue: v) { t.autoPan = a }
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
    var settings = Settings()
    lazy var inkThreshold = settings.inkThreshold

    var onBegin: ((Contact, Double) -> Void)?
    var onMove: ((Contact, Double) -> Void)?
    var onEnd: ((Bool) -> Void)?                 // true = commit, false = discard
    var onNavigate: ((CGPoint, CGPoint, Double) -> Void)?  // prev centroid, new centroid (pad 0...1), zoom ratio
    var strokeLengthMM: () -> Double = { 0 }

    func reset() {
        if case .drawing = mode { onEnd?(false) }
        mode = .idle; palm.removeAll(); edgeIgnored.removeAll(); navPrev = nil; drewIds.removeAll(); seen.removeAll()
    }

    /// Contacts already on the pad when draw mode starts (a resting palm) never draw.
    lazy var palmRejection = settings.palmRejection
    func ignoreUntilLifted(_ ids: Set<Int32>) { guard palmRejection else { return }; palm.formUnion(ids); seen.formUnion(ids) }

    func frame(_ contacts: [Contact], t: Double) {
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
            if fingers.count >= 2 { navigate(fingers) } else { navPrev = nil; mode = fingers.isEmpty ? .idle : .waitLift }
        case .waitLift:
            if fingers.isEmpty { mode = .idle }
        }
    }

    private func hover(_ fingers: [Contact], _ t: Double) {
        guard case let .hover(id) = mode else { return }
        if fingers.count >= 2 { mode = .navigating; navigate(fingers) }
        else if let f = fingers.first(where: { $0.id == id }) {
            if f.pressure >= inkThreshold { mode = .drawing(id, t); drewIds.insert(id); onBegin?(f, t) }
        } else { mode = fingers.isEmpty ? .idle : .waitLift }
    }

    private func navigate(_ fingers: [Contact]) {
        let a = fingers[0], b = fingers[1]
        let c = CGPoint(x: (a.norm.x + b.norm.x) / 2, y: (a.norm.y + b.norm.y) / 2)
        let d = hypot(a.mm.x - b.mm.x, a.mm.y - b.mm.y)
        defer { navPrev = ([a.id, b.id], c, Double(d)) }
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
    /// Returns true if the queue was empty (the caller may schedule a fallback drain).
    @discardableResult
    func push(_ c: [Contact], arrival: Double, sensorT: Double) -> Bool {
        lock.lock(); let wasEmpty = items.isEmpty; items.append((c, arrival, sensorT)); lock.unlock()
        return wasEmpty
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
        pages = docs; pageCameras = cameras; pageIndex = index
        if index < cameras.count { camera = cameras[index] }
        nextStrokeIdValue = nextStrokeId
        endWritingLine(); screensFilled = 0; hintDismissedAt = 0; updateScreensFilled()
        needsRender = true; onStatus?()
    }
    private(set) var pageIndex = 0
    var doc: Document { pages[pageIndex] }
    /// Called when page, hint or mode status changes (the window updates its labels).
    var onStatus: (() -> Void)?
    // Tests start from the default tools: the person using this Mac may have left the real app on the eraser.
    var tools = Launch.testing ? ToolState() : ToolState.load() {
        didSet {
            if tools.zoomLocked != oldValue.zoomLocked { logger.event(["what": "zoomLock", "locked": tools.zoomLocked, "source": source]) }
            if tools.tool != oldValue.tool || tools.autoPan != oldValue.autoPan || tools.zoomLocked != oldValue.zoomLocked || tools.lineWidthIndex != oldValue.lineWidthIndex {
                act("tools", ["tool": tools.tool.rawValue, "autoPan": tools.autoPan.rawValue, "zoomLocked": tools.zoomLocked, "lineWidth": tools.lineWidthIndex])
            }
            if tools.lineWidthIndex != oldValue.lineWidthIndex { endWritingLine() }
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
                onViewChange?()
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
    /// The visible part of the page changed (the page map follows it).
    var onViewChange: (() -> Void)?
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
    var drawMode = false {
        didSet {
            if drawMode != oldValue { act("drawMode", ["on": drawMode]) }
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
    private(set) var panCount = 0
    private(set) var lastPanWordStart: Double?   // test/diagnostics: start of the word at the last pan
    private(set) var newLineCount = 0

    // MARK: pages and the screen-height hint
    /// Height of the display the window is on, in canvas units (page width = display width).
    var screenUnits: Double {
        let f = window?.screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        return camera.page.width * f.height / f.width
    }
    /// Screens of this page already filled with writing (shows the "new page?" hint).
    private(set) var screensFilled = 0
    var showPageHint: Bool { screensFilled > hintDismissedAt }
    private var hintDismissedAt = 0

    private func updateScreensFilled() {
        let lowest = doc.strokes.map(\.bounds.minY).min() ?? camera.page.height
        let n = Int((camera.page.height - lowest) / screenUnits)
        if n != screensFilled { screensFilled = n; onStatus?() }
    }

    func newPage() {
        act("newPage", ["pages": pages.count + 1])
        endWritingLine()
        if pageCameras.count < pages.count { pageCameras.append(camera) } else { pageCameras[pageIndex] = camera }
        pages.append(Document.new())
        pageIndex = pages.count - 1
        changing("newPage") { camera.home() }
        pageCameras.append(camera)
        screensFilled = 0; hintDismissedAt = 0
        markDirty()
        needsRender = true; onStatus?()
    }

    /// A page's saved view (the current page: the live camera).
    func cameraForPage(_ i: Int) -> Camera { i == pageIndex || !pageCameras.indices.contains(i) ? camera : pageCameras[i] }

    func goToPage(_ i: Int) {
        act("goToPage", ["page": i])
        guard pages.indices.contains(i), i != pageIndex else { return }
        endWritingLine()
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

    private func endWritingLine() { lineInk = nil; lineStrokes = []; pendingMove = nil; legacyLineLeft = nil; lineFree = false }
    /// The current line was moved right by hand: it isn't held to the line width (WritingLayout.lineFree).
    private var lineFree = false

    /// Return in writing mode: next line now (one line down, back to the line start).
    func newLineByHand() {
        guard writingMode else { return }
        act("newLineByHand")
        cancelPendingMove(); finishSlide()
        let v = camera.visible, layout = WritingLayout()
        let midY = lineInk?.midY ?? v.midY
        let pitch = max((lineInk?.height ?? 0) * 1.35, v.height * 0.12)
        applyMove(.newLine(WritingLayout.newLineCenter(lineLeft: layout.lineStart(pageWidth: camera.page.width), lineMidY: midY, pitch: pitch, visible: v)))
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
    static let resumeDefaultZoom = 3.0

    /// The view draw mode should start at: the last word's end 40% across and its line 57.5% down, at the
    /// zoom you wrote it at. Nil (stay) if the page is empty, if that's in view already, or if you've zoomed
    /// in somewhere else since draw mode ended (you chose that spot).
    func resumeTarget() -> Camera? {
        guard resumeOnDrawStart, let last = doc.strokes.last else { return nil }
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

    /// Arrow keys: pan by 10% of the view (a whole view with `screen`), like scrolling a document (→ shows what's
    /// to the right, ↓ what's further down). Clamped like any pan (page sides and top); never a new line or a
    /// page change: a pending writing-mode move is dropped.
    func panByArrow(dx: Int, dy: Int, screen: Bool) {
        cancelPendingMove(); finishSlide()
        let v = camera.visible, f = screen ? 1.0 : 0.1
        changing("arrow") { camera.center.x += Double(dx) * f * v.width; camera.center.y -= Double(dy) * f * v.height; camera.clamp() }
        if dx > 0 && writingMode && tools.autoPan != .off && lineInk != nil && camera.visible.minX > v.minX { lineFree = true }   // moved right by hand
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
        if counted.isEmpty { tapViewAnchor = nil; pinchedThisTouch = false }
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
    override func mouseDown(with e: NSEvent) { if !drawMode { super.mouseDown(with: e) } }
    // A two-finger tap is also the system's right-click; in draw mode it lands on the frozen pointer here.
    override func rightMouseDown(with e: NSEvent) { if !drawMode { super.rightMouseDown(with: e) } }
    // Outside draw mode the usual trackpad gestures pan (two-finger scroll) and zoom (pinch).
    // In draw mode the same gestures come from MultitouchSupport instead, and these are ignored.
    override func scrollWheel(with e: NSEvent) {
        guard !drawMode else { return }
        let k = 1 / (ptPerUnit * camera.zoom)
        changing("scroll") { camera.center.x -= e.scrollingDeltaX * k; camera.center.y += e.scrollingDeltaY * k; camera.clamp() }
        needsRender = true
    }
    override func magnify(with e: NSEvent) {
        guard !drawMode, !tools.zoomLocked else { return }
        let p = convert(e.locationInWindow, from: nil)
        let anchor = canvasPoint(fromView: p), r = padRect
        changing("magnify") {   // the page point under the pointer stays under it
            var c = camera
            c.zoom = min(max(c.zoom * (1 + e.magnification), 1), Camera.maxZoom)
            let v = c.visible, k = v.width / max(r.width, 1)
            c.center = CGPoint(x: anchor.x - (p.x - r.minX) * k + v.width / 2, y: anchor.y - (p.y - r.minY) * k + v.height / 2)
            c.clamp(); camera = c
        }
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
        gestures.strokeLengthMM = { [weak self] in self?.builder?.lengthMM ?? 0 }
        gestures.onBegin = { [weak self] c, t in self?.beginStroke(c, t) }
        gestures.onMove = { [weak self] c, t in self?.moveStroke(c, t) }
        gestures.onEnd = { [weak self] commit in self?.endStroke(commit) }
        gestures.onNavigate = { [weak self] prev, now, ratio in
            guard let self else { return }
            let x0 = self.camera.visible.minX
            let z0 = self.camera.zoom
            self.changing("pinch") { self.camera.navigate(from: prev, to: now, ratio: ratio, zoomLocked: self.tools.zoomLocked) }  // moved by hand: the next stroke starts a new line where it lands
            if abs(self.camera.zoom - z0) > 1e-6 && !self.pinchedThisTouch { self.pinchedThisTouch = true; self.act("pinchZoom") }
            // With auto-pan on, panning right by hand is a choice of where to write; with No pan it's how you
            // move along the line, which still ends at the line width.
            if self.writingMode && self.tools.autoPan != .off && self.lineInk != nil && self.camera.visible.minX > x0 + 1e-6 { self.lineFree = true }
        }
    }

    private func sample(_ c: Contact, _ t: Double) -> InputSample {
        InputSample(mm: CGPoint(x: c.mm.x + strokeOffset.x, y: c.mm.y + strokeOffset.y), t: frameSensorT, pressure: c.pressure, size: c.size)
    }

    /// Where the last stroke lifted (pad mm, after any snap) and when (sensor clock).
    private var lastLift: (mm: CGPoint, t: Double, dir: CGPoint)?
    /// Raw (unshifted) samples of the current stroke, and a pending rejoin waiting for the direction check.
    private var rawSamples: [InputSample] = []
    private var pendingSnap: CGPoint?
    private var makeBuilder: (() -> StrokeBuilder)?
    /// Offset applied to every sample of the current stroke (pad mm): non-zero when snapped.
    private var strokeOffset = CGPoint.zero
    private(set) var rejoinCount = 0
    private var nextStrokeIdValue = 1
    var nextStrokeIdForSave: Int { nextStrokeIdValue }

    private func beginStroke(_ c: Contact, _ t: Double) {
        finishSlide()
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
        defer { builder = nil; needsRender = true }
        guard var b = builder else { return }
        b.finish()
        logger.end(committed: commit)
        act("strokeEnd", ["committed": commit, "index": commit ? doc.strokes.count : -1, "snapX": strokeOffset.x, "snapY": strokeOffset.y])
        if liveTool == .eraser {
            // Cancelled (it became a two- or three-finger gesture: a pan, pinch or tap): nothing it erased stays erased.
            if commit { doc.dropEmptyUndo() } else { doc.rollbackLastSnapshot(); markDirty() }
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
        act("commit", ["id": s.id, "page": pageIndex])
        markDirty()
        updateScreensFilled()
        // Writing mode, now that the finger is up (see Writing.swift).
        if writingMode {
            let vh = camera.visible.height
            // A stroke well above or below the current line (you moved there yourself): new line here.
            if let line = lineInk, abs(s.bounds.midY - line.midY) > max(line.height, vh * 0.12) * 1.2 {
                lineInk = nil; lineStrokes = []; legacyLineLeft = s.bounds.minX; lineFree = false
            }
            if legacyLineLeft == nil { legacyLineLeft = s.bounds.minX }
            let line = lineInk.map { $0.union(s.bounds) } ?? s.bounds
            lineInk = line
            lineStrokes.append(s.bounds)
            var layout = WritingLayout()
            layout.lineWidth = ToolState.lineWidths[tools.lineWidthIndex]
            layout.autoPan = tools.autoPan
            layout.edge = settings.panEdge
            layout.legacyStrokeEdge = legacyWriting
            layout.lineFree = lineFree
            let start = legacyWriting ? legacyLineLeft! : layout.lineStart(pageWidth: camera.page.width)
            let move = layout.after(stroke: s.bounds, line: line, lineStrokes: lineStrokes, lineLeft: start,
                                    visible: camera.visible, pageWidth: camera.page.width)
            if move == .none { pendingMove = nil }
            else if settings.pauseBeforeMoveMs <= 0 { applyMove(move) }
            else { pendingMove = (move, now()); act("movePending", ["kind": move.kind]) }
        }
    }

    // MARK: page moves wait for a pause

    /// The writing-mode move waiting for the finger to stay up `pauseBeforeMoveMs`.
    private var pendingMove: (move: WritingLayout.Move, liftAt: Double)?
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
        guard let p = pendingMove, countedContacts == 0, now() - p.liftAt >= settings.pauseBeforeMoveMs / 1000 else { return }
        pendingMove = nil
        applyMove(p.move)
    }

    private func applyMove(_ move: WritingLayout.Move) {
        switch move {
        case .none: break
        case .pan(let c):
            act("autoPan", ["toX": c.x, "toY": c.y, "mode": tools.autoPan.rawValue])
            panCount += 1
            if let line = lineInk { lastPanWordStart = WritingLayout.wordStarts(lineStrokes, gap: max(line.height * 0.45, camera.visible.width * 0.01)).last ?? 0 }
            slideCamera(to: c)
        case .newLine(let c):
            act("newLine", ["toX": c.x, "toY": c.y]); newLineCount += 1; lineInk = nil; lineStrokes = []; lineFree = false
            slideCamera(to: c, src: "newLine")
        }
        needsRender = true
    }

    // MARK: drawing

    /// Device pixels per canvas unit now, x2 headroom so circles stay round when zooming in later.
    private var meshPxPerUnit: Double { ptPerUnit * camera.zoom * Double(window?.backingScaleFactor ?? 2) * 2 }

    /// Interpolation step: 1.5 screen points at the zoom the stroke is drawn at.
    private var smoothStep: Double { 1.5 / (ptPerUnit * camera.zoom) }

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
        items += doc.strokes.compactMap { s in
            guard s.bounds.intersects(vis) else { return nil }  // off-screen (most of the page when zoomed in)
            if s.mesh.buffer == nil { s.mesh = renderer.makeMesh(strokeMesh(s.points, radii: s.radii, pxPerUnit: meshPxPerUnit)) }
            return .init(mesh: s.mesh, verts: nil, color: premul(s.color))
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
                let p = camera.canvas(fromPad: c.norm)
                let r = liveTool == .eraser && builder != nil ? liveSize / 2 : ringR
                var v: [SIMD2<Float>] = []
                let n = 32
                for k in 0..<n {
                    let a0 = Double(k) / Double(n) * 2 * .pi, a1 = Double(k + 1) / Double(n) * 2 * .pi
                    let w = 1.2 / (ptPerUnit * camera.zoom)
                    func pt(_ a: Double, _ rr: Double) -> SIMD2<Float> { SIMD2(Float(p.x + cos(a) * rr), Float(p.y + sin(a) * rr)) }
                    v += [pt(a0, r - w), pt(a0, r + w), pt(a1, r + w), pt(a0, r - w), pt(a1, r + w), pt(a1, r - w)]
                }
                items.append(.init(mesh: Mesh(), verts: v, color: premul(SIMD4(0.10, 0.45, 0.91, 0.8))))
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
        doc.undo(); endWritingLine(); updateScreensFilled(); markDirty(); needsRender = true
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
    func dismissPageHint() { hintDismissedAt = screensFilled; onStatus?() }
    /// Test: add a finished stroke as if drawn at the current zoom.
    func testAddStroke(_ pts: [StrokePoint], tool: ToolKind = .pen) {
        let s = Stroke(tool: tool, color: SIMD4(0, 0, 0, 1), size: tools.sizePt / (ptPerUnit * camera.zoom), points: pts, maxStep: smoothStep)
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
