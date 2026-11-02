/// One rule set for draw mode, writing mode, the zoom lock and the tools. Keys, toolbar buttons and menu
/// items all go through `after(_:lastOther:)`, so the same input does the same thing wherever it comes from:
///   draw, writing, zoom lock: toggle.
///   a tool: if it's the active tool it turns off (marker, highlighter, eraser -> pen; pen -> the last other
///   tool), and draw mode stays as it is; otherwise it becomes active, and turns draw mode on so it's ready to use.
///   Select is a pointer tool: picking it leaves draw mode (the pointer comes back); S again goes back to the pen and to
///   draw mode if it was on when Select was picked. Draw mode and Select are never on together: D with Select active
///   draws with the pen.
enum ModeInput: Equatable { case draw, writing, zoomLock, tool(ToolKind) }

struct ModeState: Equatable {
    var draw: Bool, writing: Bool, locked: Bool, tool: ToolKind

    /// `drawBeforeSelect`: whether draw mode was on when Select was picked (S again goes back to it).
    func after(_ input: ModeInput, lastOther: ToolKind?, drawBeforeSelect: Bool = false) -> ModeState {
        var s = self
        switch input {
        case .draw: s.draw.toggle(); if s.draw && tool == .select { s.tool = .pen }
        case .writing: s.writing.toggle()
        case .zoomLock: s.locked.toggle()
        case .tool(.select) where tool == .select: s.tool = .pen; s.draw = drawBeforeSelect
        case .tool(.select): s.tool = .select; s.draw = false
        case .tool(let k) where k == tool: s.tool = k == .pen ? (lastOther ?? .pen) : .pen
        case .tool(let k): s.tool = k; s.draw = true
        }
        return s
    }

    /// What changed, for the short note shown in draw mode (where the toolbar is hidden). Nil if only draw mode changed.
    func change(from old: ModeState) -> String? {
        var parts: [String] = []
        if tool != old.tool { parts.append(old.tool == .pen || tool != .pen ? tool.title : "\(old.tool.title) off · Pen") }
        if writing != old.writing { parts.append(writing ? "Writing on" : "Writing off") }
        if locked != old.locked { parts.append(locked ? "Zoom locked" : "Zoom unlocked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension ToolKind {
    var title: String {
        switch self { case .pen: return "Pen"; case .marker: return "Marker"; case .highlighter: return "Highlighter"; case .eraser: return "Eraser"; case .select: return "Select" }
    }
}
