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
    var minCutoff: Double { d.object(forKey: "oneEuroMinCutoff") as? Double ?? 1.0 }
    // beta 1.0 (was 0.05): replaying Karthik's real strokes, the ink trailed the finger by a median
    // 47 pt (p95 122 pt) at writing zoom; beta 1.0 cuts that to 7 pt (p95 21 pt). minCutoff, which
    // sets still-finger smoothing, stays at 1. See tools/filter_sweep.py.
    var beta: Double { d.object(forKey: "oneEuroBeta") as? Double ?? 1.0 }
    var palmMajor: Double { d.object(forKey: "palmMajorAxis") as? Double ?? 11.0 }
    var palmSize: Double { d.object(forKey: "palmTotal") as? Double ?? 1.4 }
    var predictMs: Double { d.object(forKey: "predictMs") as? Double ?? 16 }
    /// Inklet-style hover: a lighter touch shows the finger ring without inking; ink starts once
    /// MT pressure reaches this (raw units). 0 = off. Only meaningful with MultitouchSupport.
    var inkThreshold: Double { d.object(forKey: "inkThreshold") as? Double ?? 0 }
}

// MARK: - Model

final class Stroke {
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
    private(set) var strokes: [Stroke] = []
    private var undoStack: [[Stroke]] = []
    private var redoStack: [[Stroke]] = []

    func snapshot() { undoStack.append(strokes); redoStack.removeAll() }
    func add(_ s: Stroke) { snapshot(); strokes.append(s) }
    /// Eraser: removes without a new undo step (one step per eraser gesture, taken at its start).
    func remove(where pred: (Stroke) -> Bool) -> Bool {
        let n = strokes.count
        strokes.removeAll(where: pred)
        return strokes.count != n
    }
    func clear() { guard !strokes.isEmpty else { return }; snapshot(); strokes.removeAll() }
    func undo() { guard let s = undoStack.popLast() else { return }; redoStack.append(strokes); strokes = s }
    func redo() { guard let s = redoStack.popLast() else { return }; undoStack.append(strokes); strokes = s }
    func dropEmptyUndo() { if let last = undoStack.last, last.count == strokes.count, zip(last, strokes).allSatisfy({ $0 === $1 }) { undoStack.removeLast() } }
}

struct Camera {
    let page: CGSize
    var zoom = 1.0          // 1 = whole page visible
    var center: CGPoint
    static let maxZoom = 12.0

    init(page: CGSize) { self.page = page; center = CGPoint(x: page.width / 2, y: page.height / 2) }

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
    /// Top-left of the page at the current zoom.
    mutating func home() { let v = visible; center = CGPoint(x: v.width / 2, y: page.height - v.height / 2) }
    /// Pad position (0...1, y up) -> canvas point. This is the absolute mapping.
    func canvas(fromPad n: CGPoint) -> CGPoint {
        let v = visible
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

    var sizePt: Double { Self.sizes[tool]![sizeIndex[tool] ?? 2] }
    var color: NSColor { Self.colors[colorIndex[tool] ?? 0] }
}

// MARK: - Gesture engine: contact frames in, strokes / navigation out

final class GestureEngine {
    enum Mode { case idle, hover(Int32), drawing(Int32, Double), navigating, waitLift }
    private(set) var mode = Mode.idle
    private var palm = Set<Int32>()
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
        mode = .idle; palm.removeAll(); navPrev = nil; drewIds.removeAll(); seen.removeAll()
    }

    /// Contacts already on the pad when draw mode starts (a resting palm) never draw.
    func ignoreUntilLifted(_ ids: Set<Int32>) { palm.formUnion(ids); seen.formUnion(ids) }

    func frame(_ contacts: [Contact], t: Double) {
        let down = contacts.filter(\.isDown)
        let ids = Set(down.map(\.id))
        for id in seen.subtracting(ids) { onContactEnd?(id, palm.contains(id), drewIds.contains(id)) }
        seen = ids
        drewIds = drewIds.intersection(ids)
        palm = palm.intersection(ids)
        for c in down where c.major > settings.palmMajor || c.size > settings.palmSize || isPalm(c) { palm.insert(c.id) }
        let fingers = down.filter { !palm.contains($0.id) }.sorted { $0.id < $1.id }

        switch mode {
        case .idle:
            if fingers.count == 1 { mode = .hover(fingers[0].id); hover(fingers, t) }
            else if fingers.count >= 2 { mode = .navigating; navigate(fingers) }
        case .hover:
            hover(fingers, t)
        case let .drawing(id, started):
            let f = fingers.first { $0.id == id }
            if fingers.count >= 2 && (t - started < 0.15 || strokeLengthMM() < 3) {
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
    func push(_ c: [Contact], arrival: Double, sensorT: Double) {
        lock.lock(); items.append((c, arrival, sensorT)); lock.unlock()
    }
    func drain() -> [(contacts: [Contact], arrival: Double, sensorT: Double)] {
        lock.lock(); defer { lock.unlock() }
        let out = items; items.removeAll(keepingCapacity: true); return out
    }
}

// MARK: - Canvas view

final class CanvasView: MTKView {
    private(set) var pages: [Document] = [Document()]
    private var pageCameras: [Camera] = []
    private(set) var pageIndex = 0
    var doc: Document { pages[pageIndex] }
    /// Called when page, hint or mode status changes (the window updates its labels).
    var onStatus: (() -> Void)?
    var tools = ToolState() { didSet { needsRender = true } }
    private(set) var camera: Camera
    private var renderer: Renderer!
    private let gestures = GestureEngine()
    private var builder: StrokeBuilder?
    private var liveTool: ToolKind = .pen
    private var liveColor = SIMD4<Float>(0, 0, 0, 1)
    private var liveSize = 1.0
    private var contacts: [Contact] = []
    private var needsRender = true
    private var link: CADisplayLink?
    private var settings = Settings()
    var drawMode = false {
        didSet {
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
    let logger = StrokeLog()
    let input = InputQueue()

    /// Frames encoded / frames the display actually showed (test mode reports both).
    private(set) var renderCount = 0

    /// Frame timing for tests: CPU ms in render(), GPU ms, gaps between presented frames (ms), vertices.
    struct Perf { var cpu: [Double] = []; var gpu: [Double] = []; var gaps: [Double] = []; var verts: [Int] = []; var ticks = 0; var ticksIdle = 0; var tickMaxGap = 0.0; var lastTick = 0.0; var inputsPerTick: [Int] = []; var inputsSinceTick = 0 }
    var perf = Perf()
    private var lastPresented = 0.0

    // MARK: writing mode (see Writing.swift)
    var writingMode = false { didSet { lineInk = nil; lineLeft = nil; needsRender = true } }
    private var lineInk: CGRect?
    private var lineLeft: Double?
    private var camAnim: (from: CGPoint, to: CGPoint, start: Double)?
    private(set) var panCount = 0
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
        endWritingLine()
        if pageCameras.count < pages.count { pageCameras.append(camera) } else { pageCameras[pageIndex] = camera }
        pages.append(Document())
        pageIndex = pages.count - 1
        camera.home()
        pageCameras.append(camera)
        screensFilled = 0; hintDismissedAt = 0
        needsRender = true; onStatus?()
    }

    func goToPage(_ i: Int) {
        guard pages.indices.contains(i), i != pageIndex else { return }
        endWritingLine()
        while pageCameras.count < pages.count { pageCameras.append(camera) }
        pageCameras[pageIndex] = camera
        pageIndex = i
        camera = pageCameras[i]
        screensFilled = 0; hintDismissedAt = 0; updateScreensFilled(); hintDismissedAt = screensFilled
        needsRender = true; onStatus?()
    }

    private func endWritingLine() { lineInk = nil; lineLeft = nil }

    /// Test hook: where a canvas point currently is on the pad (0...1).
    func padPoint(_ p: CGPoint) -> CGPoint {
        let v = camera.visible
        return CGPoint(x: (p.x - v.minX) / v.width, y: (p.y - v.minY) / v.height)
    }

    private func slideCamera(to c: CGPoint) {
        var target = camera; target.center = c; target.clamp()
        camAnim = (camera.center, target.center, CACurrentMediaTime())
        needsRender = true
    }

    /// Finish any slide immediately (a finger touched down: the mapping must not move under it).
    private func finishSlide() {
        if let a = camAnim { camera.center = a.to; camAnim = nil }
    }

    private func stepSlide() {
        guard let a = camAnim else { return }
        let t = min((CACurrentMediaTime() - a.start) / 0.18, 1)
        let e = 1 - pow(1 - t, 3)  // ease out
        camera.center = CGPoint(x: a.from.x + (a.to.x - a.from.x) * e, y: a.from.y + (a.to.y - a.from.y) * e)
        if t >= 1 { camAnim = nil } else { needsRender = true }
    }
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

    /// Screen points per canvas unit at zoom 1.
    var ptPerUnit: Double { bounds.width / camera.page.width }

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
        for f in input.drain() { handle(f.contacts, arrival: f.arrival, sensorT: f.sensorT) }
        if !needsRender && camAnim == nil { perf.ticksIdle += 1 }
        perf.inputsPerTick.append(perf.inputsSinceTick); perf.inputsSinceTick = 0
        if camAnim != nil { stepSlide(); needsRender = true }
        guard needsRender else { return }
        needsRender = false
        predictAhead = max(l.targetTimestamp - CACurrentMediaTime(), 0) + settings.predictMs / 1000
        // MTKView.draw() calls draw(_:) and then releases currentDrawable. Rendering outside it
        // (paused view) kept re-presenting the first drawable: nothing new ever reached the screen.
        draw()
    }

    override func draw(_ dirtyRect: NSRect) { render(predictAhead: predictAhead) }

    func setNeedsRender() { needsRender = true }

    // MARK: input

    /// MultitouchSupport frames, already on the main thread.
    /// Contacts down right now, tracked even outside draw mode.
    private var downIds = Set<Int32>()

    func handle(_ cs: [Contact], arrival: Double, sensorT: Double) {
        downIds = Set(cs.filter(\.isDown).map(\.id))
        guard drawMode else { return }
        frameArrival = arrival
        frameSensorT = sensorT
        perf.inputsSinceTick += 1
        contacts = cs.filter(\.isDown)
        if !contacts.isEmpty { finishSlide() }
        gestures.frame(cs, t: arrival)
        needsRender = true
    }

    // NSTouch fallback (public API, no pressure): used when MultitouchSupport is unavailable.
    private var nsIds: [Int: Int32] = [:]
    /// macOS's resting-touch classification (palm/thumb), pad-normalized, from NSTouch events.
    private var restingNorm: [CGPoint] = []
    private var restingAt = 0.0

    private func nsTouchFrame(_ e: NSEvent) {
        guard drawMode else { return }
        if usingMT {  // MT draws; NSTouch only contributes Apple's resting flags for palm rejection
            restingNorm = e.touches(matching: .touching, in: self).filter(\.isResting).map(\.normalizedPosition)
            restingAt = CACurrentMediaTime()
            return
        }
        let arrival = CACurrentMediaTime()
        var out: [Contact] = []
        for t in e.touches(matching: .touching, in: self) where !t.isResting {
            let key = t.identity.hash
            let id = nsIds[key] ?? { let n = Int32(nsIds.count + 1); nsIds[key] = n; return n }()
            let mmPerPt = 25.4 / 72
            out.append(Contact(id: id, state: 4, norm: t.normalizedPosition,
                               mm: CGPoint(x: t.normalizedPosition.x * t.deviceSize.width * mmPerPt, y: t.normalizedPosition.y * t.deviceSize.height * mmPerPt),
                               pressure: 0, size: 0.5, major: 8))
        }
        if out.isEmpty { nsIds.removeAll() }
        handle(out, arrival: arrival, sensorT: e.timestamp)
    }
    override func touchesBegan(with e: NSEvent) { nsTouchFrame(e) }
    override func touchesMoved(with e: NSEvent) { nsTouchFrame(e) }
    override func touchesEnded(with e: NSEvent) { nsTouchFrame(e) }
    override func touchesCancelled(with e: NSEvent) { nsTouchFrame(e) }
    // In draw mode physical clicks land on the frozen cursor over this view: swallow them.
    override func mouseDown(with e: NSEvent) { if !drawMode { super.mouseDown(with: e) } }
    // Outside draw mode the usual trackpad gestures pan (two-finger scroll) and zoom (pinch).
    // In draw mode the same gestures come from MultitouchSupport instead, and these are ignored.
    override func scrollWheel(with e: NSEvent) {
        guard !drawMode else { return }
        let k = 1 / (ptPerUnit * camera.zoom)
        camera.center.x -= e.scrollingDeltaX * k
        camera.center.y += e.scrollingDeltaY * k
        camera.clamp(); endWritingLine(); needsRender = true
    }
    override func magnify(with e: NSEvent) {
        guard !drawMode else { return }
        let p = convert(e.locationInWindow, from: nil)
        let pad = CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
        let anchor = camera.canvas(fromPad: pad)
        camera.zoom *= 1 + e.magnification
        camera.zoom = min(max(camera.zoom, 1), Camera.maxZoom)
        let v = camera.visible
        camera.center = CGPoint(x: anchor.x - pad.x * v.width + v.width / 2, y: anchor.y - pad.y * v.height + v.height / 2)
        camera.clamp(); endWritingLine(); needsRender = true
    }

    /// Is this contact where macOS currently sees a resting touch? (fresh within 0.25 s, 6% of the pad)
    private func appleResting(_ c: Contact) -> Bool {
        guard CACurrentMediaTime() - restingAt < 0.25 else { return false }
        return restingNorm.contains { hypot($0.x - c.norm.x, ($0.y - c.norm.y) * 76.8 / 124.8) < 0.06 }
    }

    /// Per-contact features for tuning palm rejection: peak size/major, Apple resting seen.
    private var contactStats: [Int32: (maxSize: Double, maxMajor: Double, resting: Bool, start: Double)] = [:]

    private func wireGestures() {
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
            let anchor = self.camera.canvas(fromPad: prev)
            self.camera.zoom *= ratio
            self.camera.zoom = min(max(self.camera.zoom, 1), Camera.maxZoom)
            let v = self.camera.visible
            self.camera.center = CGPoint(x: anchor.x - now.x * v.width + v.width / 2, y: anchor.y - now.y * v.height + v.height / 2)
            self.camera.clamp()
            self.endWritingLine()  // moved by hand: the next stroke starts a new line where it lands
        }
    }

    private func sample(_ c: Contact, _ t: Double) -> InputSample {
        InputSample(mm: c.mm, t: frameSensorT, pressure: c.pressure, size: c.size)
    }

    private func beginStroke(_ c: Contact, _ t: Double) {
        finishSlide()
        let cam = camera, pad = Multitouch.padMM
        let model = makeWidthModel(usingMT ? settings.widthModel : "speed")
        builder = StrokeBuilder(model: model, minCutoff: settings.minCutoff, beta: settings.beta) { mm in
            cam.canvas(fromPad: CGPoint(x: mm.x / pad.width, y: mm.y / pad.height))
        }
        liveTool = tools.tool
        let col = tools.color.usingColorSpace(.sRGB)!
        liveColor = SIMD4(Float(col.redComponent), Float(col.greenComponent), Float(col.blueComponent), Float(Brush.of(liveTool).alpha))
        liveSize = tools.sizePt / (ptPerUnit * camera.zoom)
        if liveTool == .eraser { doc.snapshot() }
        logger.begin(tool: liveTool.rawValue, model: model.name, zoom: camera.zoom, ptPerUnit: ptPerUnit, backing: Double(window?.backingScaleFactor ?? 2))
        moveStroke(c, t)
    }

    private func moveStroke(_ c: Contact, _ t: Double) {
        guard builder != nil else { return }
        builder!.add(sample(c, t))
        logger.sample(t: frameSensorT, mm: c.mm, pressure: c.pressure, size: c.size, out: builder!.points.last!)
        pendingArrival = frameArrival
        if liveTool == .eraser, let p = builder!.points.last {
            let r = liveSize / 2
            if doc.remove(where: { $0.hit(p.p, r: r) }) { needsRender = true }
        }
    }

    private func endStroke(_ commit: Bool) {
        defer { builder = nil; needsRender = true }
        guard let b = builder else { return }
        logger.end(committed: commit)
        if liveTool == .eraser { doc.dropEmptyUndo(); return }
        guard commit, !b.points.isEmpty else { return }
        let s = Stroke(tool: liveTool, color: liveColor, size: liveSize, points: b.points, maxStep: smoothStep)
        s.mesh = renderer.makeMesh(strokeMesh(s.points, radii: s.radii, pxPerUnit: meshPxPerUnit))
        doc.add(s)
        updateScreensFilled()
        // Writing mode, now that the finger is up: pan along the line, or start the next line.
        if writingMode {
            if lineLeft == nil { lineLeft = s.bounds.minX }
            let line = lineInk.map { $0.union(s.bounds) } ?? s.bounds
            lineInk = line
            var layout = WritingLayout()
            layout.lineWidth = ToolState.lineWidths[tools.lineWidthIndex]
            switch layout.after(stroke: s.bounds, line: line, lineLeft: lineLeft!, visible: camera.visible, pageWidth: camera.page.width) {
            case .none: break
            case .pan(let c): panCount += 1; slideCamera(to: c)
            case .newLine(let c): newLineCount += 1; lineInk = nil; slideCamera(to: c)
            }
        }
    }

    // MARK: drawing

    /// Device pixels per canvas unit now, x2 headroom so circles stay round when zooming in later.
    private var meshPxPerUnit: Double { ptPerUnit * camera.zoom * Double(window?.backingScaleFactor ?? 2) * 2 }

    /// Interpolation step: 1.5 screen points at the zoom the stroke is drawn at.
    private var smoothStep: Double { 1.5 / (ptPerUnit * camera.zoom) }

    private func premul(_ c: SIMD4<Float>) -> SIMD4<Float> { SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w) }

    private func render(predictAhead: Double) {
        let cpu0 = CACurrentMediaTime()
        let vis = camera.visible
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
        renderer.render(in: self, visible: camera.visible, background: tools.background,
                        spacing: 48, pxPerUnit: ptPerUnit * camera.zoom * Double(window?.backingScaleFactor ?? 2),
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
        perf.verts.append(items.reduce(0) { $0 + $1.mesh.count + ($1.verts?.count ?? 0) })
    }

    // MARK: commands

    func undo() { doc.undo(); endWritingLine(); updateScreensFilled(); needsRender = true }
    func redo() { doc.redo(); needsRender = true }
    func clearPage() { doc.clear(); endWritingLine(); updateScreensFilled(); needsRender = true }
    /// Dismiss the "new page?" hint until another screen fills up.
    func dismissPageHint() { hintDismissedAt = screensFilled; onStatus?() }
    /// Test: add a finished stroke as if drawn at the current zoom.
    func testAddStroke(_ pts: [StrokePoint], tool: ToolKind = .pen) {
        let s = Stroke(tool: tool, color: SIMD4(0, 0, 0, 1), size: tools.sizePt / (ptPerUnit * camera.zoom), points: pts, maxStep: smoothStep)
        doc.add(s)
        updateScreensFilled()
    }
    func resetPerf() { perf = Perf(); lastPresented = 0 }

    /// Test baseline: same zoom and starting place as writing mode, without writing mode.
    func setZoomForTest(settingsWritingZoom: Bool) {
        camera.zoom = 3
        camera.home(); camera.clamp(); needsRender = true
    }

    func resetZoom() { camera.zoom = 1; camera.clamp(); needsRender = true }

    /// Full page to PNG at `scale` px per canvas unit (CPU, same union fill as the GPU path).
    func exportPNG(to url: URL, pxPerUnit: Double = 4) throws {
        let lowest = min(doc.strokes.map(\.bounds.minY).min() ?? 0, 0) - 20
        let w = Int(camera.page.width * pxPerUnit), h = Int((camera.page.height - lowest) * pxPerUnit)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: pxPerUnit, y: pxPerUnit)
        ctx.translateBy(x: 0, y: -lowest)
        for s in doc.strokes {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(s.color.x), green: CGFloat(s.color.y), blue: CGFloat(s.color.z), alpha: CGFloat(s.color.w)))
            ctx.addPath(strokePath(s.points, size: s.size, brush: Brush.of(s.tool)))
            ctx.fillPath(using: .winding)
        }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
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
        let dir = (ProcessInfo.processInfo.environment["TRACKPAD_DRAW_DATA"] ?? NSHomeDirectory() + "/code/trackpad-draw/data")
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
    /// One line per lifted contact (kind "contact"), for tuning palm rejection.
    func contact(_ d: [String: Any]) {
        var d = d; d["kind"] = "contact"
        write(d)
    }
    private func write(_ d: [String: Any]) {
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
