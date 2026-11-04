// The Select tool's actions (a pointer tool: picking it leaves draw mode, Modes.swift): a small floating bar next to the
// selected rectangle (Copy, Export…), Copy as Image (⌘C with a
// selection: PNG at 2x, plus PDF and SVG, on the pasteboard) and Export Selection… (⌥⌘E: the export sheet with Area set to
// Selection). The rectangle itself, and how a drag makes it, is in Canvas.swift. Selecting is never an edit: no undo step.
import AppKit

/// The bar next to the selection: one capsule styled like the toolbar (white, its shadow), holding Copy (the primary
/// action, styled like the toolbar's Draw button) and Export…, with the toolbar's thin divider between them. Clicked with
/// the pointer (Select is never on in draw mode). After Copy, its half says "Copied" for a moment (instead of a toast).
final class SelectionBar: NSView {
    let copy = BarSegment(title: "Copy", symbol: "doc.on.doc", primary: true)
    let export = BarSegment(title: "Export…", symbol: "square.and.arrow.up", primary: false)
    var onCopy: (() -> Void)? { didSet { copy.onPress = onCopy } }
    var onExport: (() -> Void)? { didSet { export.onPress = onExport } }
    static let height: CGFloat = 34   // a comfortable target (the toolbar's pill is 44)
    static let pad: CGFloat = 3, dividerGap: CGFloat = 9
    /// Room round the capsule for its shadow (drawn in draw(_:), as the toolbar draws its pill's).
    static let margin: CGFloat = 8
    /// The capsule, in the superview's coordinates (the view is `margin` larger all round).
    var capsuleFrame: CGRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }
    private var capsule: CGRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(copy); addSubview(export)
        copy.toolTip = "Copy the selection as an image (⌘C)"; export.toolTip = "Export the selection as PNG or SVG (⌥⌘E)"
        copy.setAccessibilityIdentifier("selectionCopy"); export.setAccessibilityIdentifier("selectionExport")
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Selection")
    }
    required init?(coder: NSCoder) { fatalError() }
    var fittingWidth: CGFloat { ceil(Self.pad * 2 + copy.fittingWidth + export.fittingWidth + Self.dividerGap) }
    override func layout() {
        super.layout()
        // Before it's placed (a zero frame at launch) the capsule is a null rect with an infinite origin: laying the buttons
        // out with it logged "NSLayoutConstraint … constant that exceeds internal limits" (autoresizing constraints).
        guard bounds.width > 2 * Self.margin, bounds.height > 2 * Self.margin else { return }
        let c = capsule, h = c.height - 2 * Self.pad
        copy.frame = CGRect(x: c.minX + Self.pad, y: c.minY + Self.pad, width: copy.fittingWidth, height: h)
        export.frame = CGRect(x: copy.frame.maxX + Self.dividerGap, y: c.minY + Self.pad, width: export.fittingWidth, height: h)
    }
    override func draw(_ dirtyRect: NSRect) {
        let c = capsule, pill = NSBezierPath(roundedRect: c, xRadius: c.height / 2, yRadius: c.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -1); sh.shadowColor = NSColor(white: 0, alpha: 0.25)
        sh.set()   // the toolbar's shadow
        NSColor.white.setFill(); pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.88, alpha: 1).setFill()   // the toolbar's separator
        NSBezierPath(rect: CGRect(x: copy.frame.maxX + (Self.dividerGap - 1) / 2, y: c.minY + 9, width: 1, height: c.height - 18)).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {   // the shadow's margin isn't part of the bar
        capsuleFrame.contains(point) ? super.hitTest(point) : nil
    }
    /// After Copy: "Copied" with a check for a moment.
    func flashCopied() {
        copy.override = ("Copied", "checkmark")
        needsLayout = true; needsDisplay = true
        flashTimer?.invalidate()
        let t = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.copy.override = nil; self.needsLayout = true; self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)   // a run-loop timer: it also fires while a menu or sheet is up
        flashTimer = t
    }
    private var flashTimer: Timer?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One half of the bar: a symbol and a short label, with hover and pressed states.
final class BarSegment: NSView {
    let baseTitle: String, symbol: String, primary: Bool
    var onPress: (() -> Void)?
    /// A temporary label and symbol (Copy's "Copied").
    var override: (String, String)? { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var title: String { override?.0 ?? baseTitle }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressing = false { didSet { if pressing != oldValue { needsDisplay = true } } }
    static let blue = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1), blueText = NSColor(srgbRed: 0.10, green: 0.40, blue: 0.85, alpha: 1)
    static let grey = NSColor(srgbRed: 0.27, green: 0.28, blue: 0.30, alpha: 1)
    init(title: String, symbol: String, primary: Bool) {
        baseTitle = title; self.symbol = symbol; self.primary = primary
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var font: NSFont { .systemFont(ofSize: 13, weight: primary ? .semibold : .medium) }
    private var color: NSColor { primary ? Self.blueText : Self.grey }
    private func image() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: primary ? .semibold : .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: override?.1 ?? symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }
    /// Wide enough for the longer of its labels, so the bar doesn't change width when Copy says "Copied".
    var fittingWidth: CGFloat {
        let labels = [baseTitle] + (primary ? ["Copied"] : [])
        let w = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(14 + 15 + 5 + w + 14)
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds, pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if primary { Self.blue.withAlphaComponent(pressing ? 0.24 : hovering ? 0.17 : 0.11).setFill(); pill.fill() }
        else if pressing || hovering { NSColor(white: 0, alpha: pressing ? 0.10 : 0.05).setFill(); pill.fill() }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let label = title as NSString, ls = label.size(withAttributes: attrs)
        let img = image(), iw = img?.size.width ?? 0
        let total = iw + 5 + ls.width, x0 = r.midX - total / 2
        if let img { img.draw(in: CGRect(x: x0, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height)) }
        let baseline = (r.height - font.capHeight) / 2   // cap height centred, as PillLabel does
        label.draw(at: CGPoint(x: x0 + iw + 5, y: baseline + font.descender), withAttributes: attrs)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false; pressing = false }
    override func mouseDown(with e: NSEvent) { pressing = true }
    override func mouseDragged(with e: NSEvent) { pressing = bounds.contains(convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        pressing = false
        if inside { onPress?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    /// What a click does (tests and VoiceOver).
    func performClick(_ sender: Any?) { onPress?() }
}

extension NSPasteboard.PasteboardType {
    static let svgImage = NSPasteboard.PasteboardType("public.svg-image")
}

extension AppDelegate {
    /// Where the bar goes for a selection (view points): under its bottom-right corner, or over its top if there's no room
    /// below (the toolbar), kept inside the window. Nil when the selection is off screen or still being dragged.
    func selectionBarFrame() -> CGRect? {
        guard let s = canvas.selection, !canvas.selectionDragging, !galleryShown else { return nil }
        let lo = canvas.viewPoint(fromCanvas: CGPoint(x: s.minX, y: s.minY)), hi = canvas.viewPoint(fromCanvas: CGPoint(x: s.maxX, y: s.maxY))
        return Self.barFrame(box: CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y), in: container.bounds, width: container.selectionBar.fittingWidth)
    }
    /// Where the bar goes for a box (view points, y up), `gap` (8 pt) from it and aligned to its edge: under its right
    /// edge; over it if there's no room below (the toolbar); else beside it (right, then left), aligned to its bottom.
    /// Always inside the window, above the toolbar and under the page label, and never over the box while any of those
    /// places is free (only a box covering the whole view leaves none: then it sits at the bottom right).
    static func barFrame(box r: CGRect, in b: CGRect, width w: CGFloat) -> CGRect? {
        guard r.intersects(b) else { return nil }
        let h = SelectionBar.height, gap: CGFloat = 8, edge: CGFloat = 8
        let floor = ToolbarView.height + 10, ceiling = b.height - 34   // above the toolbar, under the page label
        let x = min(max(r.maxX - w, edge), b.width - w - edge)
        let y = min(max(r.minY, floor), ceiling - h)
        let candidates = [CGRect(x: x, y: r.minY - gap - h, width: w, height: h),     // under
                          CGRect(x: x, y: r.maxY + gap, width: w, height: h),         // over
                          CGRect(x: r.maxX + gap, y: y, width: w, height: h),         // right
                          CGRect(x: r.minX - gap - w, y: y, width: w, height: h)]     // left
        let usable = CGRect(x: edge, y: floor, width: b.width - 2 * edge, height: ceiling - floor)
        return candidates.first { usable.contains($0) && !$0.intersects(r) } ?? CGRect(x: b.width - w - edge, y: floor, width: w, height: h)
    }

    func selectionChanged() {
        updateSelectionBar()
        updateBanner()
    }
    func updateSelectionBar() {
        let bar = container.selectionBar
        if let f = selectionBarFrame() { bar.frame = f.insetBy(dx: -SelectionBar.margin, dy: -SelectionBar.margin); bar.isHidden = false } else { bar.isHidden = true }
    }

    @objc func selectAction() { apply(.tool(.select), from: "menu") }

    /// The selection as an image on the pasteboard: PNG at 2x (72 x 2 dpi, so it pastes at the page's size), with the
    /// export sheet's last background (never Transparent: pasted transparent ink can't be read on a dark background), and
    /// the same region as PDF (vector) and SVG. A selection with no ink copies the paper: it's the region you chose.
    @objc func copySelectionAction() {
        guard let clip = canvas.selectionClip(ExportOptions.load()) else { return }
        let pb = Self.pasteboard
        pb.clearContents()
        pb.declareTypes([.png, .pdf, .svgImage], owner: nil)
        pb.setData(clip.png, forType: .png)
        pb.setData(clip.pdf, forType: .pdf)
        pb.setData(clip.svg, forType: .svgImage)
        usage.record("copy_selection")
        // The bar says so itself; the toast only when the bar isn't showing (never both).
        if container.selectionBar.isHidden { showToast("Copied") } else { container.selectionBar.flashCopied() }
    }

    /// File › Export Selection… (⌥⌘E, or the bar's Export…): the export sheet with Area set to Selection.
    @objc func exportSelectionAction() {
        guard canvas.selection != nil else { return }
        openExportSheet(area: .selection)
    }
}
