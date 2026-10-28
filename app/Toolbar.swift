// Keep-style drawing toolbar: a floating pill with undo/redo, the four tools, background, and
// draw mode. Tapping the selected tool opens a panel with size dots and color swatches (each tool
// keeps its own). Layout and palette are approximated from memory of Keep's drawing screen.
import AppKit

final class ToolbarView: NSView {
    enum Item: Equatable { case undo, redo, tool(ToolKind), background, writing, zoomLock, zoom, draw, gallery, prevPage, nextPage, newPage }
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
    var onPage: ((Int) -> Void)?   // -1 previous, +1 next, 0 new
    var onChange: ((ToolState) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    /// Draw mode, writing mode, the zoom lock and the tools: a click toggles them (the rules are in Modes.swift).
    var onMode: ((ModeInput) -> Void)?
    var onGallery: (() -> Void)?
    let panel = PanelView()

    // Grouped by what you do: Draw first (the main action, labelled), then the tools and paper, writing and
    // the zoom lock, undo/redo, and pages. The tuning sliders live in Settings (⌘,).
    private let items: [Item] = [.draw, .tool(.pen), .tool(.marker), .tool(.highlighter), .tool(.eraser), .background, .writing, .zoomLock, .zoom, .undo, .redo, .gallery, .prevPage, .nextPage, .newPage]
    private let separatorsAfter = [0, 5, 8, 10]
    /// The zoom as text ("300%"); a click opens presets and a field to type one.
    var zoomText = "100%" { didSet { if zoomText != oldValue { needsDisplay = true } } }
    var onZoomMenu: ((NSView, CGRect) -> Void)?
    /// Button width: 44 pt, smaller in a narrow window so the whole toolbar fits (down to 28 pt). Draw is
    /// two buttons wide (icon and label).
    private var cell: CGFloat {
        let fixed = 2 * 14 + CGFloat(separatorsAfter.count) * 12 + 16
        return min(44, max(28, (bounds.width - fixed) / CGFloat(items.count + 2)))
    }
    private func width(_ item: Item) -> CGFloat { item == .draw || item == .zoom ? cell * (item == .draw ? 2 : 1.6) : cell }
    static let height: CGFloat = 56

    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.isHidden = true
        // The panel may show another tool's sizes and colours (a secondary click on it): keep the active tool.
        panel.onPick = { [weak self] st in guard let self else { return }; var s = st; s.tool = self.state.tool; self.state = s; self.onChange?(s) }
        panel.onWritingOff = { [weak self] in self?.panel.isHidden = true; self?.onMode?(.writing) }
    }
    required init?(coder: NSCoder) { fatalError() }
    // A click on an unfocused window should still pick the tool, not just focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pillRect: CGRect {
        let w = items.reduce(0) { $0 + width($1) } + 2 * 14 + CGFloat(separatorsAfter.count) * 12
        return CGRect(x: (bounds.width - w) / 2, y: 6, width: w, height: Self.height - 12)
    }

    private func rect(of i: Int) -> CGRect {
        var x = pillRect.minX + 14
        for k in 0..<i { x += width(items[k]); if separatorsAfter.contains(k) { x += 12 } }
        return CGRect(x: x, y: pillRect.minY, width: width(items[i]), height: pillRect.height)
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
        case .zoomLock: return state.zoomLocked ? "lock.fill" : "lock.open"
        case .zoom: return "plus.magnifyingglass"
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
            case .zoomLock: selected = state.zoomLocked
            case .background: selected = !panel.isHidden && panel.mode == .background
            default: selected = false
            }
            if tint.brightnessComponent > 0.92 && tint.saturationComponent < 0.1 { tint = NSColor(white: 0.6, alpha: 1) }  // white pen: keep icon visible
            if item == .zoom {   // text, not an icon
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: tint]
                let t = zoomText as NSString, sz = t.size(withAttributes: attrs)
                t.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
                continue
            }
            if item == .draw {
                // A labelled button: blue when off (the thing to press), filled when on.
                let pill = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 7), xRadius: (r.height - 14) / 2, yRadius: (r.height - 14) / 2)
                NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: selected ? 1 : 0.12).setFill(); pill.fill()
                let fg = selected ? NSColor.white : NSColor(srgbRed: 0.10, green: 0.40, blue: 0.85, alpha: 1)
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold).applying(.init(paletteColors: [fg]))
                let label = "Draw" as NSString, attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: fg]
                let ls = label.size(withAttributes: attrs)
                if let img = NSImage(systemSymbolName: symbol(item), accessibilityDescription: "Draw")?.withSymbolConfiguration(cfg) {
                    let total = img.size.width + 4 + ls.width, x0 = r.midX - total / 2
                    img.draw(in: CGRect(x: x0, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
                    label.draw(at: CGPoint(x: x0 + img.size.width + 4, y: r.midY - ls.height / 2), withAttributes: attrs)
                }
                continue
            }
            if selected {
                NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: (r.height - (r.width - 8)) / 2)).fill()
            }
            if !isEnabled(item) { tint = tint.withAlphaComponent(0.25) }
            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(.init(paletteColors: [tint]))
            if let img = NSImage(systemSymbolName: symbol(item), accessibilityDescription: tooltip(item))?.withSymbolConfiguration(cfg) {
                let s = img.size
                img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
        // A small chevron on the buttons with a panel (a click toggles; the chevron opens the panel).
        let chev = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold).applying(.init(paletteColors: [NSColor(white: 0.55, alpha: 1)]))
        for (i, item) in items.enumerated() where hasPanel(item) {
            if let img = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)?.withSymbolConfiguration(chev) {
                let c = chevronRect(of: i), s = img.size
                img.draw(in: CGRect(x: c.midX - s.width / 2, y: c.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
        NSColor(white: 0.88, alpha: 1).setFill()
        for k in separatorsAfter { let r = rect(of: k); NSBezierPath(rect: CGRect(x: r.maxX + 5.5, y: r.minY + 10, width: 1, height: r.height - 20)).fill() }
    }

    /// The tools and writing mode have a panel (sizes and colours; line width and panning). A click toggles
    /// them; the small chevron, a right-click or a Control-click opens the panel.
    private func hasPanel(_ item: Item) -> Bool { if case .tool = item { return true }; return item == .writing }
    private func chevronRect(of i: Int) -> CGRect { let r = rect(of: i); return CGRect(x: r.maxX - 13, y: r.maxY - 15, width: 13, height: 13) }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = items.indices.first(where: { rect(of: $0).contains(p) }), isEnabled(items[i]) else { return }
        if hasPanel(items[i]) && (e.modifierFlags.contains(.control) || chevronRect(of: i).insetBy(dx: -3, dy: -3).contains(p)) {
            openPanel(of: i); needsDisplay = true; return
        }
        switch items[i] {
        case .undo: onUndo?()
        case .redo: onRedo?()
        case .draw: onMode?(.draw)
        case .writing: onMode?(.writing)
        case .zoomLock: onMode?(.zoomLock)
        case .zoom: onZoomMenu?(self, rect(of: i))
        case .prevPage: onPage?(-1)
        case .nextPage: onPage?(1)
        case .newPage: onPage?(0)
        case .gallery: onGallery?()
        case .background: togglePanel(.background, under: rect(of: i))
        case .tool(let k): onMode?(.tool(k))
        }
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = items.indices.first(where: { rect(of: $0).contains(p) }), hasPanel(items[i]) else { return super.rightMouseDown(with: e) }
        openPanel(of: i); needsDisplay = true
    }

    private func openPanel(of i: Int) {
        if case .tool(let k) = items[i] {
            let showing = !panel.isHidden && panel.mode == .tool && panel.state.tool == k
            if showing { panel.isHidden = true; return }
            panel.isHidden = true
            togglePanel(.tool, under: rect(of: i), tool: k)
        } else { togglePanel(.writing, under: rect(of: i)) }
    }

    private func togglePanel(_ mode: PanelView.Mode, under r: CGRect, tool: ToolKind? = nil) {
        if !panel.isHidden && panel.mode == mode { panel.isHidden = true; return }
        panel.mode = mode
        panel.state = state
        if let tool { panel.state.tool = tool }
        let size = panel.preferredSize
        let anchor = convert(CGPoint(x: r.midX, y: bounds.maxY), to: panel.superview)
        var x = anchor.x - size.width / 2
        x = min(max(x, 8), (panel.superview?.bounds.width ?? 800) - size.width - 8)
        panel.frame = CGRect(x: x, y: anchor.y + 4, width: size.width, height: size.height)
        panel.isHidden = false
        panel.needsDisplay = true
    }

    func hidePanel() { panel.isHidden = true; needsDisplay = true }

    // MARK: tooltips (with the shortcut), on every button

    func tooltip(_ item: Item) -> String {
        switch item {
        case .draw: return "Draw mode (⌃⌥D or D): the trackpad becomes the page. Esc stops."
        case .tool(.pen): return "Pen (P) · ⌃ or right-click: size and colour"
        case .tool(.marker): return "Marker (M) · ⌃ or right-click: size and colour"
        case .tool(.highlighter): return "Highlighter (H) · ⌃ or right-click: size and colour"
        case .tool(.eraser): return "Eraser (E) · or scratch out with a quick zig-zag · ⌃: size"
        case .background: return "Paper: plain, grid, dots or lines"
        case .writing: return "Writing mode (W): the next line when a line reaches its width · ⌃: line width"
        case .zoomLock: return state.zoomLocked ? "Zoom locked (L): two fingers only pan" : "Lock the zoom (L)"
        case .zoom: return "Zoom \(zoomText) (100% = the page's width): click for presets or type one"
        case .undo: return "Undo (⌘Z, or a two-finger double tap)"
        case .redo: return "Redo (⇧⌘Z, or a three-finger double tap)"
        case .gallery: return "Pages overview (G)"
        case .prevPage: return "Previous page (⌘[)"
        case .nextPage: return "Next page (⌘])"
        case .newPage: return "New page (N)"
        }
    }
    private func installToolTips() {
        removeAllToolTips()
        for i in items.indices { addToolTip(rect(of: i), owner: self, userData: nil) }
    }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); installToolTips() }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        items.indices.first { rect(of: $0).contains(point) }.map { tooltip(items[$0]) } ?? ""
    }
    /// Test hook: every button and its tooltip.
    var tooltipsForTest: [String] { items.map { tooltip($0) } }

    /// Window coordinates of an item's panel chevron (test mode).
    func chevron(of item: Item) -> CGPoint? {
        guard let i = items.firstIndex(of: item) else { return nil }
        let r = chevronRect(of: i)
        return convert(CGPoint(x: r.midX, y: r.midY), to: nil)
    }

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
        case .writing: return CGSize(width: 4 * 64 + 12 + 2 * pad, height: 64 + 2 * pad)
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
    /// Writing panel tiles: 0-2 line width, 3 writing off.
    private func writingRect(_ i: Int) -> CGRect {
        CGRect(x: pad + CGFloat(i) * 64 + (i >= 3 ? 12 : 0), y: pad, width: 64, height: 64)
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
        case .writing:  // line width ½ / ¾ / full · writing off
            let names = ["50%", "75%", "100%", "Off"]   // of the page, from where the block's first line began
            for i in 0..<4 {
                let r = writingRect(i), tile = CGRect(x: r.midX - 18, y: r.maxY - 42, width: 36, height: 36)
                NSColor(white: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
                NSColor(white: 0.55, alpha: 1).set()
                switch i {
                case 0, 1, 2:
                    let w = (tile.width - 8) * CGFloat(ToolState.lineWidths[i])
                    for k in 0..<3 { NSBezierPath.fill(CGRect(x: tile.minX + 4, y: tile.minY + 9 + CGFloat(k) * 8, width: w, height: 2)) }
                default:
                    let x = NSBezierPath(); x.lineWidth = 2
                    x.move(to: CGPoint(x: tile.minX + 11, y: tile.minY + 11)); x.line(to: CGPoint(x: tile.maxX - 11, y: tile.maxY - 11))
                    x.move(to: CGPoint(x: tile.minX + 11, y: tile.maxY - 11)); x.line(to: CGPoint(x: tile.maxX - 11, y: tile.minY + 11)); x.stroke()
                }
                let selected = i < 3 && state.lineWidthIndex == i
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
            guard let i = (0..<4).first(where: { writingRect($0).contains(p) }) else { return }
            switch i {
            case 0, 1, 2: s.lineWidthIndex = i
            default: onWritingOff?(); return
            }
        }
        state = s
        needsDisplay = true
        onPick?(s)
    }
}
