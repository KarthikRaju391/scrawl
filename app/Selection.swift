// The Select tool's actions (a pointer tool: picking it leaves draw mode, Modes.swift): a small floating bar next to the
// selected rectangle (Copy, Export…), Copy as Image (⌘C with a
// selection: PNG at 2x, plus PDF and SVG, on the pasteboard) and Export Selection… (⌥⌘E: the export sheet with Area set to
// Selection). The rectangle itself, and how a drag makes it, is in Canvas.swift. Selecting is never an edit: no undo step.
import AppKit

/// The bar under (or over) the selection, clicked with the pointer (Select is never on in draw mode).
final class SelectionBar: NSView {
    let copy = NSButton(title: "Copy", target: nil, action: nil)
    let export = NSButton(title: "Export…", target: nil, action: nil)
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 8
        layer?.shadowOpacity = 0.25; layer?.shadowRadius = 5; layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.borderColor = NSColor(white: 0, alpha: 0.12).cgColor; layer?.borderWidth = 0.5
        for (b, tip, sel) in [(copy, "Copy the selection as an image (⌘C)", #selector(copyPressed)), (export, "Export the selection as PNG or SVG (⌥⌘E)", #selector(exportPressed))] {
            b.bezelStyle = .accessoryBarAction; b.toolTip = tip; b.target = self; b.action = sel
            b.font = .systemFont(ofSize: 12, weight: .medium)
            addSubview(b)
        }
        copy.setAccessibilityIdentifier("selectionCopy"); export.setAccessibilityIdentifier("selectionExport")
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func copyPressed() { onCopy?() }
    @objc private func exportPressed() { onExport?() }
    var fittingWidth: CGFloat { copy.fittingSize.width + export.fittingSize.width + 4 * 6 }
    static let height: CGFloat = 30
    override func layout() {
        super.layout()
        let cw = copy.fittingSize.width, ew = export.fittingSize.width
        copy.frame = CGRect(x: 6, y: (bounds.height - 22) / 2, width: cw, height: 22)
        export.frame = CGRect(x: copy.frame.maxX + 6, y: (bounds.height - 22) / 2, width: ew, height: 22)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSPasteboard.PasteboardType {
    static let svgImage = NSPasteboard.PasteboardType("public.svg-image")
}

extension AppDelegate {
    /// Where the bar goes for a selection (view points): under its bottom-right corner, or over its top if there's no room
    /// below (the toolbar), kept inside the window. Nil when the selection is off screen or still being dragged.
    func selectionBarFrame() -> CGRect? {
        guard let s = canvas.selection, !canvas.selectionDragging, !galleryShown else { return nil }
        let b = container.bounds, bar = container.selectionBar
        let lo = canvas.viewPoint(fromCanvas: CGPoint(x: s.minX, y: s.minY)), hi = canvas.viewPoint(fromCanvas: CGPoint(x: s.maxX, y: s.maxY))
        let r = CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        guard r.intersects(b) else { return nil }
        let w = bar.fittingWidth, h = SelectionBar.height, gap: CGFloat = 8
        let floor = ToolbarView.height + 10   // above the toolbar
        var y = r.minY - gap - h
        if y < floor { y = r.maxY + gap }
        if y + h > b.height - 8 { y = min(max(r.minY + gap, floor), b.height - 8 - h) }   // tall selection: inside its bottom
        let x = min(max(r.maxX - w, 8), b.width - w - 8)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func selectionChanged() {
        updateSelectionBar()
        updateBanner()
    }
    func updateSelectionBar() {
        let bar = container.selectionBar
        if let f = selectionBarFrame() { bar.frame = f; bar.isHidden = false } else { bar.isHidden = true }
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
        showToast("Copied")
    }

    /// File › Export Selection… (⌥⌘E, or the bar's Export…): the export sheet with Area set to Selection.
    @objc func exportSelectionAction() {
        guard canvas.selection != nil else { return }
        openExportSheet(area: .selection)
    }
}
