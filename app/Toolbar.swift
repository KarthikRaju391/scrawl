// Keep-style drawing toolbar: a floating pill with undo/redo, the four tools, background, and
// draw mode. Tapping the selected tool opens a panel with size dots and color swatches (each tool
// keeps its own). Layout and palette are approximated from memory of Keep's drawing screen.
import AppKit

final class ToolbarView: NSView {
    enum Item: Equatable { case undo, redo, tool(ToolKind), background, writing, zoomLock, settings, draw, gallery, prevPage, nextPage, newPage }
    var state = ToolState() { didSet { needsDisplay = true; panel.state = state; panel.needsDisplay = true } }
    var drawMode = false { didSet { needsDisplay = true } }
    var writingMode = false { didSet { needsDisplay = true } }
    /// Page arrows: dimmed and inert when there is no page that way (first / last page).
    var canGoBack = false { didSet { if canGoBack != oldValue { needsDisplay = true } } }
    var canGoForward = false { didSet { if canGoForward != oldValue { needsDisplay = true } } }
    var canUndo = false { didSet { if canUndo != oldValue { needsDisplay = true } } }
    var canRedo = false { didSet { if canRedo != oldValue { needsDisplay = true } } }
    func isEnabled(_ item: Item) -> Bool {
        switch item { case .prevPage: return canGoBack; case .nextPage: return canGoForward; case .undo: return canUndo; case .redo: return canRedo; default: return true }
    }
    var onWriting: (() -> Void)?
    var onPage: ((Int) -> Void)?   // -1 previous, +1 next, 0 new
    var onChange: ((ToolState) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onDrawMode: (() -> Void)?
    var onGallery: (() -> Void)?
    let panel = PanelView()

    private let items: [Item] = [.undo, .redo, .tool(.pen), .tool(.marker), .tool(.highlighter), .tool(.eraser), .background, .writing, .zoomLock, .settings, .draw, .gallery, .prevPage, .nextPage, .newPage]
    private let separatorsAfter = [1, 5, 10]
    /// Button width: 44 pt, smaller in a narrow window so the whole toolbar fits (down to 28 pt).
    private var cell: CGFloat {
        let fixed = 2 * 14 + CGFloat(separatorsAfter.count) * 12 + 16
        return min(44, max(28, (bounds.width - fixed) / CGFloat(items.count)))
    }
    static let height: CGFloat = 56

    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.isHidden = true
        panel.onPick = { [weak self] st in self?.state = st; self?.onChange?(st) }
        panel.onWritingOff = { [weak self] in self?.panel.isHidden = true; self?.onWriting?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    // A click on an unfocused window should still pick the tool, not just focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pillRect: CGRect {
        let w = CGFloat(items.count) * cell + 2 * 14 + CGFloat(separatorsAfter.count) * 12
        return CGRect(x: (bounds.width - w) / 2, y: 6, width: w, height: Self.height - 12)
    }

    private func rect(of i: Int) -> CGRect {
        var x = pillRect.minX + 14
        for k in 0..<i { x += cell; if separatorsAfter.contains(k) { x += 12 } }
        return CGRect(x: x, y: pillRect.minY, width: cell, height: pillRect.height)
    }

    private func symbol(_ item: Item) -> String {
        switch item {
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .tool(.pen): return "pencil.tip"
        case .tool(.marker): return "paintbrush.pointed.fill"
        case .tool(.highlighter): return "highlighter"
        case .tool(.eraser): return "eraser"
        case .background: return "square.grid.3x3"
        case .writing: return "character.cursor.ibeam"
        case .settings: return "slider.horizontal.3"
        case .zoomLock: return state.zoomLocked ? "lock.fill" : "lock.open"
        case .draw: return drawMode ? "hand.draw.fill" : "hand.draw"
        case .prevPage: return "chevron.left"
        case .nextPage: return "chevron.right"
        case .newPage: return "doc.badge.plus"
        case .gallery: return "square.grid.2x2"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -1); sh.shadowColor = NSColor(white: 0, alpha: 0.25)
        sh.set()
        NSColor.white.setFill(); pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, item) in items.enumerated() {
            let r = rect(of: i)
            var tint = NSColor(srgbRed: 0.27, green: 0.28, blue: 0.30, alpha: 1)
            let selected: Bool
            switch item {
            case .tool(let k): selected = state.tool == k; if k != .eraser { tint = ToolState.colors[state.colorIndex[k] ?? 0] }
            case .draw: selected = drawMode
            case .writing: selected = writingMode
            case .settings: selected = !panel.isHidden && panel.mode == .settings
            case .zoomLock: selected = state.zoomLocked
            case .background: selected = !panel.isHidden && panel.mode == .background
            default: selected = false
            }
            if tint.brightnessComponent > 0.92 && tint.saturationComponent < 0.1 { tint = NSColor(white: 0.6, alpha: 1) }  // white pen: keep icon visible
            if selected {
                NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: (r.height - (r.width - 8)) / 2)).fill()
            }
            if !isEnabled(item) { tint = tint.withAlphaComponent(0.25) }
            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(.init(paletteColors: [tint]))
            if let img = NSImage(systemSymbolName: symbol(item), accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = img.size
                img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
        NSColor(white: 0.88, alpha: 1).setFill()
        for k in separatorsAfter { let r = rect(of: k); NSBezierPath(rect: CGRect(x: r.maxX + 5.5, y: r.minY + 10, width: 1, height: r.height - 20)).fill() }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = items.indices.first(where: { rect(of: $0).contains(p) }), isEnabled(items[i]) else { return }
        switch items[i] {
        case .undo: onUndo?()
        case .redo: onRedo?()
        case .draw: onDrawMode?()
        case .writing:
            if writingMode { togglePanel(.writing, under: rect(of: i)) } else { onWriting?() }
        case .settings: togglePanel(.settings, under: rect(of: i))
        case .zoomLock: var s = state; s.zoomLocked.toggle(); state = s; onChange?(s)
        case .prevPage: onPage?(-1)
        case .nextPage: onPage?(1)
        case .newPage: onPage?(0)
        case .gallery: onGallery?()
        case .background: togglePanel(.background, under: rect(of: i))
        case .tool(let k):
            if state.tool == k { togglePanel(.tool, under: rect(of: i)) } else {
                var s = state; s.tool = k; state = s; onChange?(s); panel.isHidden = true
            }
        }
        needsDisplay = true
    }

    private func togglePanel(_ mode: PanelView.Mode, under r: CGRect) {
        if !panel.isHidden && panel.mode == mode { panel.isHidden = true; return }
        panel.mode = mode
        panel.state = state
        let size = panel.preferredSize
        let anchor = convert(CGPoint(x: r.midX, y: bounds.maxY), to: panel.superview)
        var x = anchor.x - size.width / 2
        x = min(max(x, 8), (panel.superview?.bounds.width ?? 800) - size.width - 8)
        panel.frame = CGRect(x: x, y: anchor.y + 4, width: size.width, height: size.height)
        panel.isHidden = false
        panel.needsDisplay = true
    }

    func hidePanel() { panel.isHidden = true; needsDisplay = true }

    /// Window coordinates of an item's centre (test mode).
    func center(of item: Item) -> CGPoint? {
        guard let i = items.firstIndex(of: item) else { return nil }
        let r = rect(of: i)
        return convert(CGPoint(x: r.midX, y: r.midY), to: nil)
    }
}

/// The pop-up above the toolbar: size dots + color swatches for a tool, or background choices.
final class PanelView: NSView {
    enum Mode { case tool, background, writing, settings }
    var mode = Mode.tool
    var state = ToolState()
    var onPick: ((ToolState) -> Void)?
    var onWritingOff: (() -> Void)?
    private let pad: CGFloat = 14, sw: CGFloat = 30

    // Settings mode: real sliders (applied to the next stroke; stored in defaults).
    private lazy var smoothSlider = makeSlider(min: 0, max: 100, key: "smoothing", scale: 100, fallback: Smoothing.defaultValue * 100)
    private lazy var predictSlider = makeSlider(min: 0, max: 24, key: "predictMs", scale: 1, fallback: 12)
    private lazy var edgeSlider = makeSlider(min: 0, max: 10, key: "edgeGuard", scale: 100, fallback: Settings.defaultEdgeGuard * 100)
    private let smoothLabel = NSTextField(labelWithString: ""), predictLabel = NSTextField(labelWithString: ""), edgeLabel = NSTextField(labelWithString: "")
    private var resetRect: CGRect { CGRect(x: bounds.width - pad - 70, y: 8, width: 70, height: 20) }

    private func makeSlider(min: Double, max: Double, key: String, scale: Double, fallback: Double) -> NSSlider {
        let v = (UserDefaults.standard.object(forKey: key) as? Double).map { $0 * scale } ?? fallback
        let sl = NSSlider(value: v, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
        sl.isContinuous = true
        return sl
    }
    @objc private func sliderChanged(_ s: NSSlider) {
        if s === smoothSlider { UserDefaults.standard.set(s.doubleValue / 100, forKey: "smoothing") }
        else if s === edgeSlider { UserDefaults.standard.set(s.doubleValue.rounded() / 100, forKey: "edgeGuard") }
        else { UserDefaults.standard.set(s.doubleValue.rounded(), forKey: "predictMs") }
        updateSettingsLabels()
    }
    private func resetDefaults() {
        for k in ["smoothing", "predictMs", "edgeGuard"] { UserDefaults.standard.removeObject(forKey: k) }
        smoothSlider.doubleValue = Smoothing.defaultValue * 100; predictSlider.doubleValue = 12; edgeSlider.doubleValue = Settings.defaultEdgeGuard * 100
        updateSettingsLabels()
    }
    private func updateSettingsLabels() {
        smoothLabel.stringValue = String(format: "Smoothing %.0f%%   ← exact · steadier →", smoothSlider.doubleValue)
        let p = predictSlider.doubleValue.rounded()
        predictLabel.stringValue = p == 0 ? "Prediction off   ← never overshoots · keeps up →" :
            String(format: "Prediction %.0f ms   ← never overshoots · keeps up →", p)
        let e = edgeSlider.doubleValue.rounded()
        edgeLabel.stringValue = e == 0 ? "Edge guard off   ← off · ignore more of the pad's edges →" :
            String(format: "Edge guard %.0f%%   ← off · ignore more of the pad's edges →", e)
    }
    private func layoutSettings() {
        let show = mode == .settings
        for v in [smoothSlider, predictSlider, edgeSlider, smoothLabel, predictLabel, edgeLabel] as [NSView] {
            if v.superview == nil { addSubview(v) }
            v.isHidden = !show
        }
        guard show else { return }
        for l in [smoothLabel, predictLabel, edgeLabel] { l.font = .systemFont(ofSize: 11); l.textColor = NSColor(white: 0.3, alpha: 1); l.lineBreakMode = .byTruncatingTail }
        let w = bounds.width - 2 * pad
        smoothLabel.frame = CGRect(x: pad, y: bounds.height - pad - 16, width: w, height: 16)
        smoothSlider.frame = CGRect(x: pad, y: bounds.height - pad - 40, width: w, height: 22)
        predictLabel.frame = CGRect(x: pad, y: bounds.height - pad - 66, width: w, height: 16)
        predictSlider.frame = CGRect(x: pad, y: bounds.height - pad - 90, width: w, height: 22)
        edgeLabel.frame = CGRect(x: pad, y: bounds.height - pad - 116, width: w, height: 16)
        edgeSlider.frame = CGRect(x: pad, y: bounds.height - pad - 140, width: w, height: 22)
        edgeSlider.numberOfTickMarks = 11; edgeSlider.allowsTickMarkValuesOnly = true
        updateSettingsLabels()
    }
    override var isHidden: Bool { didSet { if !isHidden { layoutSettings() } } }
    override func layout() { super.layout(); layoutSettings() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layoutSettings() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var preferredSize: CGSize {
        switch mode {
        case .background: return CGSize(width: 4 * 64 + 2 * pad, height: 64 + 2 * pad)
        case .writing: return CGSize(width: 7 * 64 + 2 * 12 + 2 * pad, height: 64 + 2 * pad)
        case .settings: return CGSize(width: 420, height: 196)
        case .tool: return CGSize(width: 6 * sw + 5 * 8 + 2 * pad, height: state.tool == .eraser ? sw + 2 * pad : 3 * sw + 2 * 8 + 12 + 2 * pad)
        }
    }

    private func sizeRect(_ i: Int) -> CGRect {
        let w = (bounds.width - 2 * pad) / 5
        return CGRect(x: pad + CGFloat(i) * w, y: bounds.height - pad - sw, width: w, height: sw)
    }
    private func colorRect(_ i: Int) -> CGRect {
        let row = i / 6, col = i % 6
        return CGRect(x: pad + CGFloat(col) * (sw + 8), y: bounds.height - pad - sw - 12 - CGFloat(row + 1) * sw - CGFloat(row) * 8, width: sw, height: sw)
    }
    private func bgRect(_ i: Int) -> CGRect { CGRect(x: pad + CGFloat(i) * 64, y: pad, width: 64, height: 64) }
    /// Writing panel tiles: 0-2 line width, 3-5 auto-pan (no pan / centre / left), 6 writing off.
    private func writingRect(_ i: Int) -> CGRect {
        CGRect(x: pad + CGFloat(i) * 64 + (i >= 3 ? 12 : 0) + (i >= 6 ? 12 : 0), y: pad, width: 64, height: 64)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor.white.setFill(); box.fill()
        NSColor(white: 0.86, alpha: 1).setStroke(); box.stroke()
        if mode == .settings {
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1)]
            let str = NSAttributedString(string: "Defaults", attributes: attr)
            str.draw(at: CGPoint(x: resetRect.maxX - str.size().width, y: resetRect.minY + 3))
            return
        }
        let selBlue = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1)
        switch mode {
        case .settings: break  // sliders are subviews
        case .tool:
            let sizes = ToolState.sizes[state.tool]!
            let color = state.tool == .eraser ? NSColor(white: 0.35, alpha: 1) : state.color
            for (i, s) in sizes.enumerated() {
                let r = sizeRect(i)
                let d = min(CGFloat(s) * (state.tool == .eraser ? 0.6 : (state.tool == .highlighter ? 0.75 : 1.6)), sw - 4)
                if state.sizeIndex[state.tool] == i { selBlue.withAlphaComponent(0.15).setFill(); NSBezierPath(ovalIn: CGRect(x: r.midX - sw / 2, y: r.minY, width: sw, height: sw)).fill() }
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            }
            guard state.tool != .eraser else { return }
            for (i, c) in ToolState.colors.enumerated() {
                let r = colorRect(i)
                c.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
                if c.brightnessComponent > 0.92 { NSColor(white: 0.8, alpha: 1).setStroke(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).stroke() }
                if state.colorIndex[state.tool] == i {
                    let ring = NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)); ring.lineWidth = 2; selBlue.setStroke(); ring.stroke()
                }
            }
        case .writing:  // line width ½ / ¾ / full · auto-pan none / centre / left · writing off
            let names = ["½ page", "¾ page", "Full", "No pan", "Centre", "Left", "Off"]
            for i in 0..<7 {
                let r = writingRect(i), tile = CGRect(x: r.midX - 18, y: r.maxY - 42, width: 36, height: 36)
                NSColor(white: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
                NSColor(white: 0.55, alpha: 1).set()
                switch i {
                case 0, 1, 2:
                    let w = (tile.width - 8) * CGFloat(ToolState.lineWidths[i])
                    for k in 0..<3 { NSBezierPath.fill(CGRect(x: tile.minX + 4, y: tile.minY + 9 + CGFloat(k) * 8, width: w, height: 2)) }
                case 3, 4, 5:  // a view frame and where the last word ends up after the pan
                    NSBezierPath(rect: tile.insetBy(dx: 6, dy: 9)).stroke()
                    if i != 3 {
                        let x = i == 4 ? tile.midX - 7 : tile.minX + 8
                        NSBezierPath.fill(CGRect(x: x, y: tile.midY - 1.5, width: 7, height: 3))
                    } else {
                        let l = NSBezierPath(); l.lineWidth = 1.5
                        l.move(to: CGPoint(x: tile.minX + 8, y: tile.minY + 11)); l.line(to: CGPoint(x: tile.maxX - 8, y: tile.maxY - 11)); l.stroke()
                    }
                default:
                    let x = NSBezierPath(); x.lineWidth = 2
                    x.move(to: CGPoint(x: tile.minX + 11, y: tile.minY + 11)); x.line(to: CGPoint(x: tile.maxX - 11, y: tile.maxY - 11))
                    x.move(to: CGPoint(x: tile.minX + 11, y: tile.maxY - 11)); x.line(to: CGPoint(x: tile.maxX - 11, y: tile.minY + 11)); x.stroke()
                }
                let selected = (i < 3 && state.lineWidthIndex == i) || (i >= 3 && i <= 5 && state.autoPan.rawValue == i - 3)
                if selected { let ring = NSBezierPath(roundedRect: tile.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7); ring.lineWidth = 2; selBlue.setStroke(); ring.stroke() }
                let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.3, alpha: 1)]
                let str = NSAttributedString(string: names[i], attributes: attr)
                str.draw(at: CGPoint(x: r.midX - str.size().width / 2, y: r.minY + 2))
            }
        case .background:
            let names = ["None", "Square", "Dot", "Ruled"]
            for i in 0..<4 {
                let r = bgRect(i), tile = CGRect(x: r.midX - 18, y: r.maxY - 42, width: 36, height: 36)
                NSColor(white: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
                NSColor(white: 0.7, alpha: 1).set()
                switch i {
                case 1: for k in 1..<4 { let o = CGFloat(k) * 9; NSBezierPath.strokeLine(from: CGPoint(x: tile.minX + o, y: tile.minY + 2), to: CGPoint(x: tile.minX + o, y: tile.maxY - 2)); NSBezierPath.strokeLine(from: CGPoint(x: tile.minX + 2, y: tile.minY + o), to: CGPoint(x: tile.maxX - 2, y: tile.minY + o)) }
                case 2: for a in 1..<4 { for b in 1..<4 { NSBezierPath(ovalIn: CGRect(x: tile.minX + CGFloat(a) * 9 - 1.2, y: tile.minY + CGFloat(b) * 9 - 1.2, width: 2.4, height: 2.4)).fill() } }
                case 3: for k in 1..<4 { let o = CGFloat(k) * 9; NSBezierPath.strokeLine(from: CGPoint(x: tile.minX + 2, y: tile.minY + o), to: CGPoint(x: tile.maxX - 2, y: tile.minY + o)) }
                default: break
                }
                if state.background == i { let ring = NSBezierPath(roundedRect: tile.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7); ring.lineWidth = 2; selBlue.setStroke(); ring.stroke() }
                let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.3, alpha: 1)]
                let str = NSAttributedString(string: names[i], attributes: attr)
                str.draw(at: CGPoint(x: r.midX - str.size().width / 2, y: r.minY + 2))
            }
        }
    }

    /// Window coordinates of a size dot / color swatch / background tile (test mode).
    func centerOfSize(_ i: Int) -> CGPoint { let r = sizeRect(i); return convert(CGPoint(x: r.midX, y: r.midY), to: nil) }
    func centerOfColor(_ i: Int) -> CGPoint { let r = colorRect(i); return convert(CGPoint(x: r.midX, y: r.midY), to: nil) }
    func centerOfBackground(_ i: Int) -> CGPoint { let r = bgRect(i); return convert(CGPoint(x: r.midX, y: r.midY), to: nil) }
    func centerOfWriting(_ i: Int) -> CGPoint { let r = writingRect(i); return convert(CGPoint(x: r.midX, y: r.midY), to: nil) }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        var s = state
        switch mode {
        case .tool:
            if let i = (0..<5).first(where: { sizeRect($0).contains(p) }) { s.sizeIndex[s.tool] = i }
            else if s.tool != .eraser, let i = ToolState.colors.indices.first(where: { colorRect($0).contains(p) }) { s.colorIndex[s.tool] = i }
            else { return }
        case .background:
            guard let i = (0..<4).first(where: { bgRect($0).contains(p) }) else { return }
            s.background = i
        case .settings:
            if resetRect.contains(p) { resetDefaults() }
            return
        case .writing:
            guard let i = (0..<7).first(where: { writingRect($0).contains(p) }) else { return }
            switch i {
            case 0, 1, 2: s.lineWidthIndex = i
            case 3, 4, 5: s.autoPan = AutoPan(rawValue: i - 3)!
            default: onWritingOff?(); return
            }
        }
        state = s
        needsDisplay = true
        onPick?(s)
    }
}
