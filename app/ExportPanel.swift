// File › Export Page… (⇧⌘E): the save sheet's options, under the file browser. Format (PNG, SVG), scale (1-4x or a
// custom 50-800%, the resulting size shown as you change it), area (the page, or exactly what's on screen) and background
// (paper as the canvas shows it, white, transparent). The last choices are kept.
import AppKit
import UniformTypeIdentifiers

final class ExportAccessory: NSView, NSTextFieldDelegate {
    let format = NSPopUpButton(), scale = NSPopUpButton(), percent = NSTextField(), area = NSPopUpButton(), background = NSPopUpButton()
    let sizeLabel = NSTextField(labelWithString: "")
    /// The area's rect in page units (the current page; what's on screen depends on the view).
    private let areaRect: (ExportOptions.Area) -> CGRect
    /// Called on every change (the panel's file type follows the format).
    var onChange: ((ExportOptions) -> Void)?
    private var customScale: Double

    init(options: ExportOptions, areaRect: @escaping (ExportOptions.Area) -> CGRect) {
        self.areaRect = areaRect
        customScale = options.scale
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
        format.addItems(withTitles: ["PNG", "SVG"])
        scale.addItems(withTitles: ExportOptions.presets.map { "\(Int($0))×" } + ["Custom"])
        area.addItems(withTitles: ["Page", "What's on screen"])
        background.addItems(withTitles: ["Paper", "White", "Transparent"])
        area.item(at: 0)?.toolTip = "The page's full width, from its top to just below the lowest ink"
        area.item(at: 1)?.toolTip = "Exactly what the window shows, at its current zoom"
        background.item(at: 0)?.toolTip = "The page as the canvas shows it: white with its grid, dots or lines"
        for p in [format, scale, area, background] { p.target = self; p.action = #selector(changed(_:)) }
        let f = NumberFormatter(); f.numberStyle = .none; f.allowsFloats = false   // no min/max: out of range is clamped (takePercent), not refused
        percent.formatter = f
        percent.delegate = self
        percent.alignment = .right
        percent.setAccessibilityLabel("Custom scale, percent")
        percent.widthAnchor.constraint(equalToConstant: 56).isActive = true
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        sizeLabel.lineBreakMode = .byWordWrapping
        sizeLabel.preferredMaxLayoutWidth = 300
        sizeLabel.setAccessibilityIdentifier("exportSize")

        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let scaleRow = NSStackView(views: [scale, percent, NSTextField(labelWithString: "%")])
        scaleRow.spacing = 6
        let grid = NSGridView(views: [
            [label("Format:"), format],
            [label("Scale:"), scaleRow],
            [NSGridCell.emptyContentView, sizeLabel],
            [label("Area:"), area],
            [label("Background:"), background],
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).topPadding = -4
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])
        for p in [format, area, background] { p.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true }
        self.options = options
    }
    required init?(coder: NSCoder) { fatalError() }

    var options: ExportOptions {
        get {
            ExportOptions(format: ExportOptions.Format.allCases[max(format.indexOfSelectedItem, 0)], scale: currentScale,
                          area: ExportOptions.Area.allCases[max(area.indexOfSelectedItem, 0)],
                          background: ExportOptions.Background.allCases[max(background.indexOfSelectedItem, 0)])
        }
        set {
            format.selectItem(at: ExportOptions.Format.allCases.firstIndex(of: newValue.format) ?? 0)
            area.selectItem(at: ExportOptions.Area.allCases.firstIndex(of: newValue.area) ?? 0)
            background.selectItem(at: ExportOptions.Background.allCases.firstIndex(of: newValue.background) ?? 0)
            customScale = newValue.scale
            scale.selectItem(at: ExportOptions.presets.firstIndex(of: newValue.scale) ?? ExportOptions.presets.count)
            percent.stringValue = String(Int((newValue.scale * 100).rounded()))
            update()
        }
    }

    private var isCustom: Bool { scale.indexOfSelectedItem >= ExportOptions.presets.count }
    private var currentScale: Double { isCustom ? customScale : ExportOptions.presets[max(scale.indexOfSelectedItem, 0)] }

    @objc private func changed(_ sender: Any?) {
        if sender as? NSPopUpButton === scale {
            if isCustom { window?.makeFirstResponder(percent); percent.currentEditor()?.selectAll(nil) }
            else { percent.stringValue = String(Int((currentScale * 100).rounded())) }
        }
        update()
    }

    /// Typing a percentage picks Custom (or the preset it equals), live.
    func controlTextDidChange(_ n: Notification) { takePercent(percent.currentEditor()?.string ?? percent.stringValue) }
    func controlTextDidEndEditing(_ n: Notification) {
        takePercent(percent.stringValue)
        percent.stringValue = String(Int((currentScale * 100).rounded()))
    }
    /// Sets the scale from typed text (tests call it as typing does).
    func takePercent(_ text: String) {
        guard let v = Double(text.filter { $0.isNumber || $0 == "." }), v > 0 else { return }
        let s = min(max(v / 100, ExportOptions.customRange.lowerBound), ExportOptions.customRange.upperBound)
        customScale = s
        scale.selectItem(at: ExportOptions.presets.firstIndex(of: s) ?? ExportOptions.presets.count)
        update()
    }

    private func update() {
        let o = options
        let sz = ExportOptions.size(of: areaRect(o.area), scale: o.scale)
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        let dims = "\(nf.string(from: sz.width as NSNumber)!) × \(nf.string(from: sz.height as NSNumber)!) px"
        if sz.capped {
            sizeLabel.stringValue = "\(dims): too large at \(Int((o.scale * 100).rounded()))%, saved at \(Int((sz.scale * 100).rounded(.down)))%"
            sizeLabel.textColor = .systemOrange
        } else {
            sizeLabel.stringValue = o.format == .svg ? "\(dims) (vector)" : dims
            sizeLabel.textColor = .secondaryLabelColor
        }
        onChange?(o)
    }
}

extension NSSavePanel {
    /// Keeps the file name's extension in step with the chosen format.
    func useFormat(_ f: ExportOptions.Format) {
        allowedContentTypes = [f == .png ? .png : .svg]
        let name = (nameFieldStringValue as NSString).deletingPathExtension
        nameFieldStringValue = name + "." + f.rawValue
    }
}
