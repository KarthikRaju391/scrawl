# Writing mode: the cutoff state machine (spec)

What the next-line cutoff must do, as checkable properties. Checked three ways: TLC on `docs/writing-cutoff.tla`
(`checks/writing-cutoff-tla.sh`), the model explorer and the fuzzer of the real `CanvasView`, and replays of recorded
sessions (`checks/writing-verify.sh --cutoff`, the oracle in `bench/cutoffSpec.swift`, properties C1–C8 = P1–P8 here).
Seeded bugs: `checks/writing-cutoff-mutants.py` (real code) and the TLA script's mutant list.

## The rule (Karthik, 6 Nov)

> "If the writing mode setting is at 50%, that means it should cut off at 50% of the screen width from the point where I
> am writing from. It should not consider the viewport in consideration and cut it to 50% of that. It should look at the
> starting point of the line and then calculate the full screen width and then take the percentage off of it."

Decided the same evening (rule **B**, release-017 edc3fba): **cutoff = blockStart.x + w × W**, where W is the screen's
width at 100% zoom, the page width (1,600 canvas units). It doesn't depend on the zoom or on where the start sits on
screen, it's fixed for the block, and there's no 95% cap or 93% edge zone. The view follows long lines. (Rule **A**, in
the 0.1.7 build 13 he tried: w × the view's width when the block started. `--rule a` checks that one.)

**Amendment (proposed by this verification, a4cc64f):** the cutoff never lies past where the view can reach. The
camera's centre stops 2 page widths past the page's right side, so a line ends at most 5% inside the right edge of the
view at its reach, at the current zoom, and never before the block's start. Without it, a block started
near the reach never gets a next line (see P8). Off the reach, which is any block whose line fits, rule B is unchanged.

## State

| Variable | In the app | Meaning |
|---|---|---|
| `writing` | `writingMode` | writing mode on |
| `w` | `tools.lineWidthIndex` → 0.5 / 0.75 / 1 | the setting |
| camera | `camera` (centre, zoom; view width `W / zoom`) | what's on screen |
| `blockStart` | `runStart` (= `segmentStart`) | where the block's first stroke started |
| `Vw₀` | `blockViewWidth` | the block's measure, fixed when it starts (B: W; A: the view's width then) |
| line | `lineInk`, `lineStrokes` | the open line's ink |
| `held` | `lineHeld` | a line you wrote on after its move (`lineContinued`) |
| previous line | `prevLine` | the line a move just left |
| pending | `pendingMove` (`newLine` / `follow`, lift time, wait) | the one waiting move |
| contacts | `countedContacts`; edge-band contacts aren't counted | fingers down |
| hand move | `handPanX`, `handRef` | how far you moved the view since the last stroke or app move |
| clock | `now()` | the wait is `pauseBeforeMoveMs` (400 ms by default; 200–1000) |
| guide | `lineLimitX`, `limitTargetAlpha` | the faint line at the cutoff and its strength |

Derived: **cutoff** = blockStart + w × Vw₀ (with the amendment's cap); **marker** = cutoff − 3% × (w × Vw₀)
(`WritingLayout.nearMarker`); the line is **due** when its rightmost ink ≥ marker.

## Events

Stroke commit with bounds (`endStroke` → `decideMove`); counted touch down / up (cancels the waiting move); edge-band and
palm contacts (not counted); the clock (`advanceClock`, every display tick); two-finger pan and pinch (in draw mode, counted
touches); scroll and magnify outside draw mode; arrow keys; the app's own moves (next line, follow); Return; undo, redo and
the two-finger scrub; page switch, new page, Clear; writing mode on/off; the width setting; window resize.

Window resize changes nothing here: the view is always `W / zoom` canvas units wide (`Camera.visible`), whatever the
window's size, so the measure and the cutoff don't move.

## Properties

Each traces to Karthik's words or to a decision in the code's history.

**P1 Fixed cutoff.** While writing mode is on and a block exists, the cutoff (the guide's x and the one `decideMove`
uses) = blockStart + w × Vw₀, Vw₀ = W. Within a block, with the setting unchanged, no event moves it: camera position,
hand pans, the app's next-line and follow moves, zoom, undo, redo, scrub, the guide showing or hiding. A new setting
gives start + w′ × Vw₀. *Karthik: "look at the starting point of the line and then calculate the full screen width
and then take the percentage"; rule B (edc3fba).*

**P2 Viewport independence.** Two runs that differ only in where the start sits on screen or in the camera's offset give
the same cutoff relative to the start. *Karthik: "It should not consider the viewport".*

**P3 Block start changes only by the rules.** A block starts or moves only with: the first stroke after writing mode turns
on or a page change; a stroke well above or below the line (more than 1.2 × max(line height, 12% of the view)), unless it's
the block's next line (just below, within 10% of the page from the start); a stroke after a deliberate hand move (10% of
the view or more) that lands away (10% of the page from the start with no line open, or past the line's end by 10% of
the page, or left of the line); a redo with no block (3cfa1a5). Never by the app's next-line or follow moves, Return,
undo, pans alone or the setting. *runStart's doc comment (28 Oct); 682b63a, 65c5123.*

**P4 Next line.** After a commit or a redo, a next line is pending iff the line is due and not held. There is at most one
pending move. A counted touch cancels it. It fires only from the clock, at least the wait after the lift, with no counted
touch since. It goes to the view with blockStart at 5% from the left, one line pitch (max(1.35 × line height, 12% of the
view)) down. *494c47d (the wait, a touch cancels), 3f94375 (the 3% zone: "when I am just inside the guide line, the next
line pan isn't triggering"), 8ae637d / 5da4d48 (back to the block's start).*

**P5 Progress.** Once the line is due, the first pause of at least the wait with no counted contact produces the move.
Nothing may block it. Measured alongside: how far ink runs past the cutoff (in line widths), and what besides continuous
writing allowed it. *Karthik's complaint, 6 Nov: writing mode "kinda broken".*
 Decided exceptions, kept as separate sub-properties so they stay visible:
 - **held:** a line you write on after its move gets no automatic move (74c61cf: "a new block started there and every
   next line went off the page's edge").
 - **hand:** moving the view by hand (pan, pinch, scroll, arrows, the map) drops the waiting move (4be932f).

**P6 The guide.** It shows (target strength > 0) iff the line's ink, including the stroke being drawn, is within 15% of
the line's length of the cutoff, or past it. It is drawn at exactly the cutoff (`render` draws at `lineLimitX`) and is hidden
after the move. *67ed20a (Karthik, 28 Oct: "only as you approach the width point"); f5046c7 (6 Nov: "keep it simple").*

**P7 Edge contacts.** Edge-band and palm contacts never cancel, reschedule or hold back a waiting move. *handle(): "a palm
resting on the edge must neither cancel nor hold back a pending page move".*

**P8 No stuck states.** No move stays pending past its time with no counted touch. Leaving writing mode clears the block,
the line, the held flag, the previous line, the waiting move and the guide. A writer who carries on always gets a next line
(the marker is somewhere ink can reach). *494c47d, 0.1.6.1.*

## What the checks found (6 Nov, release-017 3cfa1a5 + a4cc64f)

See the report in the thread. In short: P1, P2, P3, P4, P6 and P7 hold everywhere they were checked. P5 fails strictly in
the two decided classes (held, hand) and in three undocumented ones: undo, the setting, and a touch that didn't ink
(scratch-out, eraser, a tap). In each of those, the move waits for the next stroke instead of the next pause. P8's reach
wedge was a real bug, fixed in a4cc64f.
