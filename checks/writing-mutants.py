#!/usr/bin/env python3
"""Mutation testing of the writing-mode checks (properties P1-P9, bench/writingVerify.swift): each mutant is one targeted change to the app
(and, for Canvas logic, the same change to the model that mirrors it), built from a copy of the sources and run through
the model checker, the real-canvas fuzzer (with and without the model alongside) and the targeted slide check.

  checks/writing-mutants.py [names...]    -> prints a table; build/writing-mutants.md
  checks/writing-mutants.py baseline      -> the code before the fixes (main), same checks
"""
import os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C, WL, M = "app/Canvas.swift", "app/Writing.swift", "bench/writingModel.swift"

# name: (property it targets, description, [(file, old, new, count)])
MUTANTS = {
    "wait0": ("P1", "no wait: the move comes at the lift", [
        (C, "else if settings.pauseBeforeMoveMs <= 0 { applyMove(move) }", "else if true { applyMove(move) }", 1),
        (M, "else if waitMs <= 0 { switch move {", "else if true { switch move {", 1)]),
    "halfWait": ("P1", "the move comes after half the wait", [
        (C, "now() - p.liftAt >= p.waitMs / 1000 else { return }", "now() - p.liftAt >= p.waitMs / 2000 else { return }", 1),
        (M, "clock - p.liftAt >= p.waitMs / 1000 else { return }", "clock - p.liftAt >= p.waitMs / 2000 else { return }", 1)]),
    "touchKeeps": ("P1", "a touch-down doesn't cancel the waiting move", [
        (C, "if countedContacts > 0 { finishSlide(); cancelPendingMove() }", "if countedContacts > 0 { finishSlide() }", 1),
        (M, "counted = 1; cancelPendingMove(); advanceClock()", "counted = 1; advanceClock()", 1),
        (M, "counted = 1; cancelPendingMove(); held = s", "counted = 1; held = s", 1),
        (M, "if touch { cancelPendingMove() }", "if touch { }", 1)]),
    "inkMoves": ("P2", "a move carries the last stroke down (the old 'move the crossing word' rule)", [
        (C, """            act("newLine", ["toX": c.x, "toY": c.y]); newLineCount += 1""",
            """            act("newLine", ["toX": c.x, "toY": c.y]); newLineCount += 1
            if let s = doc.strokes.last { doc.replaceLast(Stroke(tool: s.tool, color: s.color, size: s.size, points: s.points.map { StrokePoint(p: CGPoint(x: $0.p.x, y: $0.p.y - 10), pressure: $0.pressure) }, maxStep: 1e9)) }""", 1),
        (M, "        newLines += 1\n", "        newLines += 1\n        if let i = pages[pageIdx].strokes.indices.last { pages[pageIdx].strokes[i] = pages[pageIdx].strokes[i].offsetBy(dx: 0, dy: -10) }\n", 1)]),
    # 0.1.6, the infinite canvas: a block's line is the width setting of the view's width when it started, from its start.
    "blockFromPage": ("P3", "the block's line is the width of the page, not of the view when the block started", [
        (C, "blockViewWidth.map { $0 * ToolState.lineWidths[tools.lineWidthIndex] }", "blockViewWidth.map { _ in camera.page.width * ToolState.lineWidths[tools.lineWidthIndex] }", 1),
        (M, "blockView.map { $0 * width }", "blockView.map { _ in cam.page.width * width }", 1)]),
    "blockWidthLive": ("P3", "the block's line follows the zoom now (the view's width at each stroke), not the zoom at its start", [
        (C, "blockViewWidth.map { $0 * ToolState.lineWidths[tools.lineWidthIndex] }", "blockViewWidth.map { _ in camera.visible.width * ToolState.lineWidths[tools.lineWidthIndex] }", 1),
        (M, "blockView.map { $0 * width }", "blockView.map { _ in cam.visible.width * width }", 1)]),
    "limitFromEdge": ("P3", "the limit counts from the page's margin, not the block's start", [
        (WL, "if let bw = blockWidth { return (segmentStart ?? lineLeft) + bw }", "if let bw = blockWidth { return lineStart(pageWidth: pageWidth) + bw }", 1)]),
    "rightCapBack": ("P3", "the block's line still capped at 95% of the page", [
        (WL, "if let bw = blockWidth { return (segmentStart ?? lineLeft) + bw }", "if let bw = blockWidth { return min((segmentStart ?? lineLeft) + bw, pageWidth * Self.rightCap) }", 1)]),
    "nearEdgeBack": ("P4", "the 93% near-edge rule kept with a block width", [
        (WL, "if let bw = blockWidth { return lineEnd - Self.nearMarker * bw }", "if let bw = blockWidth { return min(lineEnd - Self.nearMarker * bw, pageWidth * Self.nearEdge) }", 1)]),
    "noFollow": ("P9", "the view never follows a line longer than itself", [
        (WL, "if blockWidth != nil, right > v.maxX - Self.followWithin * v.width {", "if false, right > v.maxX - Self.followWithin * v.width {", 1)]),
    "followPastEnd": ("P9", "the view follows past the line's end", [
        (WL, "let cx = min(right - Self.followTo * v.width + v.width / 2, lineEnd + v.width * 0.05 - v.width / 2)", "let cx = right - Self.followTo * v.width + v.width / 2", 1)]),
    "nearMarker0": ("P4", "nearMarker 0 (only a crossing brings the next line)", [(WL, "static let nearMarker = 0.03", "static let nearMarker = 0.0", 1)]),
    "idotCancels": ("P4", "only the last stroke's end counts (an i-dot cancels the move)", [
        (WL, "let right = legacyStrokeEdge ? s.maxX : max(s.maxX, line.maxX)", "let right = s.maxX", 1)]),
    # 0.1.6: the view isn't clamped at the page's edge any more, only at the canvas's reach (2 page widths), which the
    # explored and fuzzed states don't reach: this one is expected to survive now (the bug it guarded can't happen).
    "unclamped": ("P5", "the unclamped target is remembered (29 Oct bug 2; only at the canvas's reach since 0.1.6)", [
        (C, "var target = camera; target.center = c; target.clamp(); handRef = target.center", "var target = camera; target.center = c; handRef = c; target.clamp()", 2),
        (M, "var target = cam; target.center = c; target.clamp(); handRef = target.center", "var target = cam; target.center = c; handRef = c; target.clamp()", 2)]),
    "toMargin": ("P5", "the next line goes to the page's margin, not the block's start", [
        (C, "let start = legacyWriting ? legacyLineLeft! : (runStart ?? layout.lineStart(pageWidth: camera.page.width))",
            "let start = legacyWriting ? legacyLineLeft! : layout.lineStart(pageWidth: camera.page.width)", 1),
        (M, "let start = runStart ?? layout.lineStart(pageWidth: cam.page.width)", "let start = layout.lineStart(pageWidth: cam.page.width)", 1)]),
    "noInset": ("P5", "the block's start lands at the view's very left (no 5% inset)", [
        (WL, "let left = lineLeft - v.width * 0.05", "let left = lineLeft", 1)]),
    "runNotReset": ("P6", "the block start isn't reset by a page change or writing mode off", [
        (C, "        if !keepRun { runStart = nil }\n", "", 1), (M, "        if !keepRun { runStart = nil }\n", "", 1)]),
    "drift": ("P6", "no '10% of the page from the block's start' guard (29 Oct bug 3: lines drifted)", [
        (C, "} else if runStart.map({ abs(s.bounds.minX - $0) > camera.page.width * WritingLayout.newRunAway }) ?? true {", "} else {", 1),
        (M, "} else if runStart.map({ abs(s.minX - $0) > cam.page.width * WritingLayout.newRunAway }) ?? true {", "} else {", 1)]),
    "ownMoveIsHand": ("P6", "the app's own move counts as a hand move (handRef not updated)", [
        (C, "var target = camera; target.center = c; target.clamp(); handRef = target.center", "var target = camera; target.center = c; target.clamp()", 2),
        (M, "var target = cam; target.center = c; target.clamp(); handRef = target.center", "var target = cam; target.center = c; target.clamp()", 2)]),
    "undoResets": ("P6", "undo ends the block", [
        (C, "doc.undo(); endWritingLine(keepRun: true)", "doc.undo(); endWritingLine()", 1),
        (M, "        endWritingLine(keepRun: true)\n        let left", "        endWritingLine()\n        let left", 1)]),
    "edgeCancels": ("P7", "an edge-band contact cancels the waiting move", [
        (C, "if countedContacts > 0 { finishSlide(); cancelPendingMove() }", "if !contacts.isEmpty { finishSlide(); cancelPendingMove() }", 1),
        (M, "            edge = 1; advanceClock()", "            edge = 1; cancelPendingMove(); advanceClock()", 1)]),
    "edgeHolds": ("P7", "an edge-band contact holds the move back", [
        (C, "guard let p = pendingMove, countedContacts == 0,", "guard let p = pendingMove, contacts.isEmpty,", 1),
        (M, "guard let p = pending, counted == 0,", "guard let p = pending, counted == 0, edge == 0,", 1)]),
    "doubleWait": ("P8a", "the move comes after twice the wait (ms/s mix-up)", [
        (C, "now() - p.liftAt >= p.waitMs / 1000 else { return }", "now() - p.liftAt >= p.waitMs / 500 else { return }", 1),
        (M, "clock - p.liftAt >= p.waitMs / 1000 else { return }", "clock - p.liftAt >= p.waitMs / 500 else { return }", 1)]),
    "staleKept": ("P8b", "ending the line (undo, page, writing off) keeps the waiting move", [
        (C, "lineInk = nil; lineStrokes = []; pendingMove = nil; legacyLineLeft = nil; handPanX = 0", "lineInk = nil; lineStrokes = []; legacyLineLeft = nil; handPanX = 0", 1),
        (M, "lineInk = nil; lineStrokes = []; pending = nil; handPanX = 0", "lineInk = nil; lineStrokes = []; handPanX = 0", 1)]),
    "heldForever": ("P8c", "a line you went back to finish stays held (no move ever after)", [
        (C, "lineInk = nil; lineStrokes = []; legacyLineLeft = s.bounds.minX; lineHeld = false; prevLine = nil", "lineInk = nil; lineStrokes = []; legacyLineLeft = s.bounds.minX; prevLine = nil", 1),
        (C, "lineHeld = false; lineInk = nil; lineStrokes = []; segmentStart = runStart; handPanX = 0   // the run goes on", "lineInk = nil; lineStrokes = []; segmentStart = runStart; handPanX = 0   // the run goes on", 1),
        (M, "lineInk = nil; lineStrokes = []; lineHeld = false; prevLine = nil", "lineInk = nil; lineStrokes = []; prevLine = nil", 1),
        (M, "lineHeld = false; lineInk = nil; lineStrokes = []; segmentStart = runStart; handPanX = 0", "lineInk = nil; lineStrokes = []; segmentStart = runStart; handPanX = 0", 1)]),
    "slideRace": ("slide", "goToPage / newPage don't finish the slide (the bug fixed here)", [
        (C, "endWritingLine(); finishSlide()   // a new-line slide still running belongs to this page, not the next", "endWritingLine()", 2)]),
    "staleCount": ("P8", "the touch count isn't reset when draw mode changes (TLC's counterexample)", [
        (C, "            if countedContacts > 0 { countedContacts = 0; onTouching?(false) }\n", "", 1)]),
    # The code before this branch's fixes (main), with the model reverted the same way.
    "baseline": ("all", "main before the fixes", [
        (C, "            if countedContacts > 0 { countedContacts = 0; onTouching?(false) }\n", "", 1),
        (C, "            if tools.lineWidthIndex != oldValue.lineWidthIndex { cancelPendingMove() }", "            if tools.lineWidthIndex != oldValue.lineWidthIndex { endWritingLine() }", 1),
        (C, "endWritingLine(); finishSlide()   // a new-line slide still running belongs to this page, not the next", "endWritingLine()", 2),
        (C, "        cancelPendingMove(); finishSlide()   // moved by hand: a waiting next-line move is dropped (as for arrows and the map)\n", "", 1),
        (C, "        guard !drawMode, !tools.zoomLocked else { return }\n        cancelPendingMove(); finishSlide()\n", "        guard !drawMode, !tools.zoomLocked else { return }\n", 1),
        (C, "if commit { doc.dropEmptyUndo(); pruneWritingLine() }", "if commit { doc.dropEmptyUndo() }", 1),
        (C, "                doc.scratchOut(erasing: gone)\n                pruneWritingLine()\n", "                doc.scratchOut(erasing: gone)\n", 1),
        (C, "if movedByHand >= vw * WritingLayout.deliberatePan * (1 - 1e-9) {", "if movedByHand >= vw * WritingLayout.deliberatePan {", 1),
        (M, "widthIdx = i; cancelPendingMove()", "widthIdx = i; endWritingLine()", 1),
        (M, "            cancelPendingMove()\n            handMove(to: camAfter ?? c, touch: false)", "            handMove(to: camAfter ?? c, touch: false)", 1),
        (M, "    mutating func scratchedLine(_ gone: CGRect) -> Bool {\n", "    mutating func scratchedLine(_ gone: CGRect) -> Bool {\n        if true { return false }\n", 1),
        (M, "        if movedByHand >= vw * WritingLayout.deliberatePan * (1 - 1e-9) {", "        if movedByHand >= vw * WritingLayout.deliberatePan {", 1),
        (C, " || (lineHeld && s.bounds.midY < line.minY) {", " {", 1),
        (M, " || (lineHeld && s.midY < line.minY) {", " {", 1),
        (C, "        if lineInk == nil { lineHeld = false }   // nothing left to finish (a held empty line never moved again)\n", "", 1),
        (M, "        if lineInk == nil { lineHeld = false }\n", "", 1)]),
    "heldAbsorbs": ("P8c", "a held line takes the line written under it (main)", [
        (C, " || (lineHeld && s.bounds.midY < line.minY) {", " {", 1), (M, " || (lineHeld && s.midY < line.minY) {", " {", 1)]),
    "heldEmpty": ("P8c", "an emptied line stays held (this branch's first scratch-out fix)", [
        (C, "        if lineInk == nil { lineHeld = false }   // nothing left to finish (a held empty line never moved again)\n", "", 1),
        (M, "        if lineInk == nil { lineHeld = false }\n", "", 1)]),
}

def build(name, edits, real_only=False):
    tmp = tempfile.mkdtemp(prefix=f"wv-{name}-")
    for d in ["app", "bench", "tools", "checks"]:
        shutil.copytree(os.path.join(ROOT, d), os.path.join(tmp, d))
    for f, old, new, n in edits:
        if real_only and f == M: continue
        p = os.path.join(tmp, f); s = open(p).read()
        if s.count(old) != n: sys.exit(f"{name}: '{old[:60]}...' found {s.count(old)} times in {f}, want {n}")
        open(p, "w").write(s.replace(old, new))
    out = os.path.join(tmp, "writing-verify")
    r = subprocess.run(["checks/writing-verify.sh", "--help-build-only"], cwd=ROOT, env={**os.environ, "SRC": tmp, "OUT": out, "BUILD_ONLY": "1"}, capture_output=True, text=True)
    if not os.path.exists(out): sys.exit(f"{name}: build failed\n{r.stdout[-3000:]}{r.stderr[-3000:]}")
    return tmp, out

def run(binary, *a):
    r = subprocess.run([binary, "--test-writing-verify", *a], capture_output=True, text=True, timeout=3600)
    return r.stdout

def caught(text, kind):
    """Properties reported failing by one section of the output."""
    props = []
    for line in text.splitlines():
        m = re.match(r"\s+(P\d\w?|model): (COUNTEREXAMPLE|FAIL)", line)
        if m: props.append(m.group(1))
        if kind == "targeted" and line.startswith("TARGETED") and "FAIL" in line: props.append("arrow" if "arrow" in line else "staleCount" if "between a commit" in line else "slide")
    return sorted(set(props))

def main():
    names = sys.argv[1:] or [n for n in MUTANTS if n != "baseline"]
    rows = []
    for n in names:
        prop, desc, edits = MUTANTS[n]
        tmp, both = build(n, edits)
        ex = run(both, "--explore", "4", "--waits", "200,400,1000", "--workers", "4")
        fz = run(both, "--fuzz", "300", "--waits", "400", "--no-diff", "--seed", "3")
        tg = run(both, "--targeted", "--waits", "400")
        tmp2, real = build(n + "-realonly", edits, real_only=True)
        df = run(real, "--fuzz", "300", "--waits", "400", "--seed", "3", "--diff-only")
        row = (n, prop, desc, caught(ex, "explore"), caught(fz, "fuzz") + caught(tg, "targeted"), "model" in caught(df, "fuzz"))
        rows.append(row)
        def short(t, tag):
            return [l.strip() for l in t.splitlines() if l.startswith("  ") and ("COUNTEREXAMPLE" in l or "FAIL" in l or l.strip().startswith("->"))][:6]
        print(f"{n}: model checker {row[3] or '-'}; real-canvas fuzz/targeted {row[4] or '-'}; model-vs-app differential {'caught' if row[5] else '-'}", flush=True)
        for l in short(ex, "ex") + short(fz, "fz"): print("    " + l, flush=True)
        shutil.rmtree(tmp, ignore_errors=True); shutil.rmtree(tmp2, ignore_errors=True)
    md = ["| mutant | targets | change | model checker (depth 4, waits 200/400/1000) | real canvas (fuzz 300x40, targeted) | differential (app mutated, model not) |", "|---|---|---|---|---|---|"]
    for n, prop, desc, ex, fz, df in rows:
        md.append(f"| `{n}` | {prop} | {desc} | {', '.join(ex) or 'not caught'} | {', '.join(fz) or 'not caught'} | {'caught' if df else '-'} |")
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    open(os.path.join(ROOT, "build", "writing-mutants.md"), "w").write("\n".join(md) + "\n")
    print("\n".join(md))

main()
