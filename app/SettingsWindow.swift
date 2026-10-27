// Settings (⌘,): the feel sliders that used to sit in the toolbar (smoothing, prediction, edge guard), and
// switches for scratch-out, the page map, tips, where draw mode starts, click to draw (with its time) and usage counts. Each is saved at once (tests never save).
import AppKit

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    struct Switch { let title: String; let key: String; let get: () -> Bool; let set: (Bool) -> Void }
    private var switches: [Switch] = []
    private var boxes: [NSButton] = []
    var onChange: (() -> Void)?
    var onSwitch: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onClickDrawTimeout: ((Double) -> Void)?
    private let armSlider = NSSlider(value: CanvasView.clickDrawTimeout, minValue: 0, maxValue: 5, target: nil, action: nil)

    private let armValue = NSTextField(labelWithString: "")

    init(switches: [Switch]) {
        // Laid out top-down; the window is as tall as its rows. The click-to-draw time sits right under its switch.
        let width: CGFloat = 480, rowH: CGFloat = 24, sliderRowH: CGFloat = 30, panelH: CGFloat = 196
        let height = 20 + 18 + 8 + panelH + 16 + CGFloat(switches.count) * rowH + sliderRowH + 16
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(AppInfo.name) Settings"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)   // light, like the page and the panels
        super.init(window: w)
        self.switches = switches
        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))
        content.appearance = NSAppearance(named: .aqua)
        w.contentView = content
        var y = height - 20 - 18
        let feel = NSTextField(labelWithString: "How the ink feels")
        feel.font = .systemFont(ofSize: 13, weight: .semibold)
        feel.frame = CGRect(x: 20, y: y, width: width - 40, height: 18)
        content.addSubview(feel)
        y -= 8 + panelH
        let panel = PanelView()
        panel.mode = .settings
        panel.frame = CGRect(x: 20, y: y, width: width - 40, height: panelH)
        content.addSubview(panel)
        y -= 16
        for (i, sw) in switches.enumerated() {
            y -= rowH
            let b = NSButton(checkboxWithTitle: sw.title, target: self, action: #selector(toggled(_:)))
            b.tag = i
            b.state = sw.get() ? .on : .off
            b.frame = CGRect(x: 20, y: y, width: width - 40, height: 20)
            b.lineBreakMode = .byTruncatingTail
            content.addSubview(b); boxes.append(b)
            if sw.key == "clickToDraw" {   // how long drawing stays on after the last lift (0: a click per stroke)
                y -= sliderRowH
                let label = NSTextField(labelWithString: "Stays on after you lift")
                label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
                label.frame = CGRect(x: 42, y: y + 6, width: 150, height: 16)
                armSlider.frame = CGRect(x: 196, y: y + 2, width: 190, height: 22)
                armSlider.numberOfTickMarks = 6; armSlider.allowsTickMarkValuesOnly = true
                armSlider.target = self; armSlider.action = #selector(armChanged)
                armValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                armValue.frame = CGRect(x: 394, y: y + 6, width: width - 20 - 394, height: 16)
                for v in [label, armSlider, armValue] as [NSView] { content.addSubview(v) }
            }
        }
        updateArmLabel()
        w.center()
        w.delegate = self
    }
    func windowWillClose(_ n: Notification) { onClose?() }
    @objc private func armChanged() { onClickDrawTimeout?(armSlider.doubleValue); updateArmLabel() }
    private func updateArmLabel() {
        armValue.stringValue = armSlider.doubleValue < 0.5 ? "0 s (each)" : String(format: "%.0f s", armSlider.doubleValue)
        armSlider.toolTip = "0 s: every stroke needs its own click"
        let on = switches.first { $0.key == "clickToDraw" }?.get() ?? false
        armSlider.isEnabled = on; armValue.textColor = on ? .labelColor : .tertiaryLabelColor
    }
    var clickDrawRangeForTest: [Int] { [Int(armSlider.minValue), Int(armSlider.maxValue)] }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled(_ b: NSButton) {
        let sw = switches[b.tag], on = b.state == .on
        sw.set(on)
        updateArmLabel()
        if !Launch.testing && !sw.key.hasSuffix("Switch") { UserDefaults.standard.set(on, forKey: sw.key) }   // "…Switch": stores itself
        onSwitch?(sw.key); onChange?()
    }
    func refresh() { for (i, b) in boxes.enumerated() { b.state = switches[i].get() ? .on : .off }; updateArmLabel() }
    /// Test hook: the switches and whether each is on.
    var switchesForTest: [(String, Bool)] { switches.map { ($0.title, $0.get()) } }
    func setSwitchForTest(_ i: Int, _ on: Bool) { boxes[i].state = on ? .on : .off; toggled(boxes[i]) }
}
