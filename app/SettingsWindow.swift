// Settings (⌘,): the feel sliders that used to sit in the toolbar (smoothing, prediction, edge guard), and
// switches for scratch-out, the page map and tips. Each is saved at once (tests never save).
import AppKit

final class SettingsWindow: NSWindowController {
    struct Switch { let title: String; let key: String; let get: () -> Bool; let set: (Bool) -> Void }
    private var switches: [Switch] = []
    private var boxes: [NSButton] = []
    var onChange: (() -> Void)?

    init(switches: [Switch]) {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(AppInfo.name) Settings"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)   // light, like the page and the panels
        super.init(window: w)
        self.switches = switches
        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))
        content.appearance = NSAppearance(named: .aqua)
        w.contentView = content
        let feel = NSTextField(labelWithString: "How the ink feels")
        feel.font = .systemFont(ofSize: 13, weight: .semibold)
        feel.frame = CGRect(x: 20, y: 322, width: 300, height: 18)
        content.addSubview(feel)
        let panel = PanelView()
        panel.mode = .settings
        panel.frame = CGRect(x: 20, y: 120, width: 420, height: 196)
        content.addSubview(panel)
        var y: CGFloat = 92
        for (i, sw) in switches.enumerated() {
            let b = NSButton(checkboxWithTitle: sw.title, target: self, action: #selector(toggled(_:)))
            b.tag = i
            b.state = sw.get() ? .on : .off
            b.frame = CGRect(x: 20, y: y, width: 420, height: 20)
            content.addSubview(b); boxes.append(b)
            y -= 24
        }
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled(_ b: NSButton) {
        let sw = switches[b.tag], on = b.state == .on
        sw.set(on)
        if !Launch.testing { UserDefaults.standard.set(on, forKey: sw.key) }
        onChange?()
    }
    func refresh() { for (i, b) in boxes.enumerated() { b.state = switches[i].get() ? .on : .off } }
    /// Test hook: the switches and whether each is on.
    var switchesForTest: [(String, Bool)] { switches.map { ($0.title, $0.get()) } }
    func setSwitchForTest(_ i: Int, _ on: Bool) { boxes[i].state = on ? .on : .off; toggled(boxes[i]) }
}
