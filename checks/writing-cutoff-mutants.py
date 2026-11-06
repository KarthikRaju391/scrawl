#!/usr/bin/env python3
"""Seeded bugs in the real app code (app/Writing.swift, app/Canvas.swift), each built into writing-verify and run through the
cutoff oracle (fuzz of the real CanvasView, C2 metamorphic runs, the reach check). Each mutant must fail the property that
targets it. checks/writing-cutoff-mutants.py [names...]   (TRACKPAD_DRAW_DATA is set to a throwaway dir)"""
import os, re, shutil, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
M = {  # name: (targets, what, [(file, old, new)])
 "lineLeft": ("C1 C4", "the limit from the line's left ink, not the block start", [
   ("app/Writing.swift", "let end = (segmentStart ?? lineLeft) + bw", "let end = lineLeft + bw"),
   ("app/Canvas.swift", "let start = legacyWriting ? legacyLineLeft ?? s.minX : (runStart ?? layout.lineStart(pageWidth: camera.page.width))", "let start = legacyWriting ? legacyLineLeft ?? s.minX : line.minX")]),
 "zoomRemeasure": ("C1", "the block re-measured at every zoom (the view's width now)", [
   ("app/Canvas.swift", "blockViewWidth.map { $0 * ToolState.lineWidths[tools.lineWidthIndex] }", "blockViewWidth.map { _ in camera.visible.width * ToolState.lineWidths[tools.lineWidthIndex] }")]),
 "followRemeasure": ("C1", "a follow re-measures the block to the new view's right edge", [
   ("app/Canvas.swift", "var target = camera; target.center = c; target.clamp(); handRef = target.center\n            slideCamera(to: c, src: \"follow\")",
    "var target = camera; target.center = c; target.clamp(); handRef = target.center\n            if let rs = runStart { blockViewWidth = target.visible.maxX - rs }\n            slideCamera(to: c, src: \"follow\")")]),
 "appMoveReset": ("C3", "the next-line move resets the block start", [
   ("app/Canvas.swift", "lineHeld = false; lineInk = nil; lineStrokes = []; segmentStart = runStart; handPanX = 0   // the run goes on",
    "lineHeld = false; lineInk = nil; lineStrokes = []; runStart = nil; segmentStart = nil; handPanX = 0")]),
 "panMeasure": ("C1", "the visible width taken after each hand pan or pinch", [
   ("app/Canvas.swift", "if self.writingMode && abs(self.camera.zoom - z0) < 1e-9 { self.handPanX += abs(self.camera.center.x - cx0) }",
    "if self.writingMode && abs(self.camera.zoom - z0) < 1e-9 { self.handPanX += abs(self.camera.center.x - cx0) }\n            if self.runStart != nil { self.blockViewWidth = self.camera.visible.width }")]),
 "palmCancels": ("C7", "an edge-band contact (palm) cancels the waiting move", [
   ("app/Canvas.swift", "if countedContacts > 0 { finishSlide(); cancelPendingMove() }", "if !contacts.isEmpty { finishSlide(); cancelPendingMove() }")]),
 "nearMarker0": ("C4", "no near-marker zone (nearMarker 0)", [
   ("app/Writing.swift", "static let nearMarker = 0.03", "static let nearMarker = 0.0")]),
 "wait0": ("C4", "the move at the lift (wait 0)", [
   ("app/Canvas.swift", "let wait = settings.pauseBeforeMoveMs\n", "let wait = 0.0\n")]),
 "visibleWidth": ("C1 C2", "the view's width when the block starts (rule A, the build of 6 Nov)", [
   ("app/Writing.swift", "nonisolated(unsafe) static var measureFromView = false", "nonisolated(unsafe) static var measureFromView = true")]),
 "viewport": ("C2 C1", "Karthik's complaint: the share of the view right of the start", [
   ("app/Canvas.swift", "blockViewWidth = runStart == nil ? nil : WritingLayout.blockMeasure(visibleWidth: camera.visible.width, pageWidth: camera.page.width)",
    "blockViewWidth = runStart.map { camera.visible.maxX - $0 }")]),
 "guideAlways": ("C6", "the guide shown however far the ink is", [
   ("app/Canvas.swift", "static let limitShowWithin = 0.15", "static let limitShowWithin = 10.0")]),
 "noReachCap": ("reach", "the reach fix taken out", [
   ("app/Writing.swift", "guard let r = reachRight else { return end }", "guard let r = reachRight, r < -1e300 else { return end }")]),
}
names = sys.argv[1:] or list(M)
env = dict(os.environ, TRACKPAD_DRAW_DATA=tempfile.mkdtemp(prefix="cv-mut-data."))
for n in names:
    targets, what, edits = M[n]
    d = tempfile.mkdtemp(prefix=f"cv-mut-{n}.")
    for sub in ("app", "bench", "tools"): shutil.copytree(os.path.join(ROOT, sub), os.path.join(d, sub))
    ok = True
    for f, old, new in edits:
        p = os.path.join(d, f); s = open(p).read()
        if old not in s: print(f"{n}: PATTERN NOT FOUND in {f}: {old[:60]}"); ok = False; break
        open(p, "w").write(s.replace(old, new, 1))
    if not ok: continue
    out = os.path.join(d, "wv")
    b = subprocess.run([os.path.join(ROOT, "checks/writing-verify.sh")], env=dict(env, SRC=d, OUT=out, BUILD_ONLY="1"), capture_output=True, text=True, cwd=ROOT)
    if b.returncode: print(f"{n}: BUILD FAILED\n{b.stdout[-800:]}{b.stderr[-800:]}"); continue
    failed = set(); lines = []
    runs = [["--fuzz", "300", "--len", "40", "--waits", "400"], ["--p2", "60", "--len", "30", "--waits", "400"], ["--cutoff-targeted", "--waits", "400"]]
    for r in runs:
        o = subprocess.run([out, "--test-writing-verify", "--cutoff", "--no-diff", *r], env=env, capture_output=True, text=True).stdout
        for m in re.finditer(r"^  (C\d[:\w]*|P8c|model): FAIL.*\n\s+-> (.*)$", o, re.M): failed.add(m.group(1)); lines.append(f"{m.group(1)}: {m.group(2)[:200]}")
        if re.search(r"^C2 .*: FAIL", o, re.M): failed.add("C2"); lines += ["C2: " + l.strip()[:200] for l in o.splitlines() if l.startswith("  ") and "cutoff" in l][:1]
        if "CUTOFF TARGETED" in o and "FAIL" in o: failed.add("reach"); lines += [l.strip()[:200] for l in o.splitlines() if "no next line" in l][:1]
    base = {"C5:held", "C5:hand", "C5:touch", "C5:undo", "C5:width", "C5:other"}   # the unmutated app fails these too (decided / known)
    new = sorted(failed - base)
    hit = [t for t in targets.split() if t in failed]
    print(f"{n:16s} targets {targets:6s} {'CAUGHT' if hit else 'MISSED'} by {','.join(hit) or '-'}; new failures {','.join(new) or 'none'}  ({what})")
    for l in lines:
        if l.split(":")[0] in hit[:1]: print("      " + l); break
    shutil.rmtree(d, ignore_errors=True)
