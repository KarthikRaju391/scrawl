# Writing mode: specification (next line, blocks, guide line)

What writing mode must do, written so a checker can test it. Each property says where it comes from:
a `DECISIONS.md` section (newer sections override older ones) or Karthik's words quoted there. The checks
are in `bench/writingModel.swift` (model + oracle), `bench/writingVerify.swift` (bounded model checker,
fuzzing of the real `CanvasView`, session replay, mutations) and `docs/writing-mode.tla` (TLA+ model of
the clock, cancel and pending logic). Run with `checks/writing-verify.sh`.

Page units: the page is W = 1600 wide (`CanvasView.pageUnits`), y goes up, lines go down the page.

## State

| Variable | Meaning | Code |
|---|---|---|
| `writing` | writing mode on | `CanvasView.writingMode` |
| `w` | line width, 0.5 / 0.75 / 1.0 of W | `ToolState.lineWidths[tools.lineWidthIndex]` |
| `camera` | zoom and centre; `vis` = the visible rect (`vw` x `vh`) | `CanvasView.camera` |
| `runStart` | x where the current block's first line began (nil: no block yet) | `runStart` (`segmentStart` always equals it after a stroke) |
| `line`, `lineStrokes` | the current line's strokes and their union (nil: no open line) | `lineInk`, `lineStrokes` |
| `prevLine` | the line a next-line move just left (to finish it) | `prevLine` |
| `held` | the current line is one you went back to finish: no automatic move for it | `lineHeld` |
| `handPanX`, `handRef` | sideways hand movement since the last stroke; view centre after the last stroke or move | `handPanX`, `handRef` |
| `pending` | the next-line move waiting for the pause: (target, lift time) | `pendingMove` |
| `counted` | fingers down that the edge guard counts | `countedContacts` |
| `edge` | contacts down that started in the edge band (5% of the pad per side) | `GestureEngine.edgeIgnored` |
| `clock` | the canvas clock (virtual in replays and checks) | `CanvasView.now` |
| `W` | the wait before a move: a setting, default 400 ms, about 200-1000 ms (Karthik, 1 Nov) | `Settings.pauseBeforeMoveMs` |

Derived: `limit = min((runStart ?? 0) + w·W, 0.95·W)` (the guide line, `lineLimitX`), and
`zoneStart = limit > 0.93·W ? 0.93·W : limit − 0.03·w·W` (`nearMarkerStart`).

## Events

| Event | Code path |
|---|---|
| counted touch-down / lift; a lift that ends a stroke commits it with its bounds | `handle` → `GestureEngine.frame` → `endStroke` → the block after "Writing mode, now that the finger is up" |
| edge-band touch-down / lift | `handle` (the `counted` filter), `GestureEngine.edgeIgnored` |
| clock tick | `tick` → `advanceClock` (every display frame; the replay driver calls it per record) |
| two-finger pan (hand pan), pinch | `GestureEngine.navigate` → `onNavigate` (both are counted contacts) |
| scroll / magnify outside draw mode | `scrollWheel`, `magnify` |
| arrow pan | `panByArrow` |
| page map click | `centerView` |
| undo, redo, scratch-out, eraser, clear | `undo`, `redo`, `endStroke` scratch/eraser branches, `clearPage` |
| page switch, new page, delete/restore page | `goToPage`, `newPage`, `deletePage`, `restorePage` |
| writing mode on/off, width change | `writingMode` didSet, `tools` didSet |
| Return | `newLineByHand` |

## Properties

**P1 Never mid-word.** An automatic next-line move happens only on a clock tick at least W after the
lift that scheduled it, with no counted contact down, and no counted touch-down since that lift. Any
counted touch-down cancels a pending move; it is decided again at the next lift. Return is the only move
that skips the pause.
*From:* Writing.swift header (77% of in-word gaps < 300 ms); "Feedback (item 7)": "Any touch cancels the
move"; "The next line at the next word gap once past the limit (29 Oct, option A)"; b03bac2 feedback
"don't wait for 1.5s, users won't know that. Keep it 400"; Karthik, 1 Nov: the wait becomes a setting
(checked at 200, 400 and 1000 ms). Exactly W counts ("at least").

**P2 Written ink never moves.** No writing-mode event changes a committed stroke; moves change only the
camera. (Undo, redo, scratch-out, the eraser and Clear Page change which strokes exist, never where.)
*From:* "Line breaks are decided before a word, and ink never moves (19:33 recording)".

**P3 The guide line.** In writing mode the limit is never past 95% of the page, and equals
`min(runStart + w·W, 0.95·W)` (from the page's left edge when no block has started).
*From:* "The next line goes back to the block's start (28 Oct)" (widths count from the run's start);
"A block from the middle of the page to its right side" item 1 and `rightCap` (97% → 95%, 29 Oct).

**P4 When the line is full.** After a stroke is committed in writing mode, a move is pending exactly when
the line is not held and the line's rightmost ink is at or past `zoneStart`: crossing the limit, within 3%
of the line width before it, or at 93%+ of the page when the limit is past 93%. "The line's ink" is the
strokes of the current line that still exist. A stroke back inside the line (an i-dot, a t-cross) cannot
cancel a move the line already called for.
*From:* "Just inside the marker brings the next line (0.1.1, 30 Oct)"; "Carrying a line on after a hand
pan keeps the block; ink at 93-95%..." (93% rule, 400 ms); the i-dot comment in `WritingLayout.after`.

**P5 Where it goes.** A move (automatic or Return) puts the view one pitch below the line
(`pitch = max(1.35·line height, 0.12·vh)`), the line 57.5% down the view, with the block's start 5% in from
the view's left, clamped to the page (`Camera.clamp`). The block's start is in view afterwards (or, if it
lies off the page, the view is against that side: two of Karthik's sessions have a block whose first stroke
started 20 units left of the page). The view centre the app remembers (`handRef`) is the clamped one.
*From:* W2 (57.5%); "The next line goes back to the block's start"; "A block from the middle..." item 2.

**P6 Blocks change only by the rules.**
- (a) The first stroke after writing mode turns on or a page change / new page starts a block at that
  stroke. A width change does not: widths count from the block's start, so the block and the line stay
  (main reset the block, so the next stroke, even mid-line, became the block's start; fixed on this branch).
- (b) After a hand move of the view of 10% or more of its width since the last stroke (pan in or out of draw
  mode, pinch, scroll, arrows, page map; exactly 10%, one arrow press, counts), a stroke starts a new block if: with a line open, it lands more than
  `max(gap, 10% of W)` right of the line's end or more than a gap left of its start; with no line open, it
  lands more than 10% of W from the block's start.
- (c) A stroke well above or below the open line starts a new block, unless it is just below (within 3.5
  pitches) and within 10% of W of the block's start: then it's the block's next line. Under a held line (one you
  went back to finish), any stroke whose middle is below its ink counts as below (main: the next line, written
  where the move put you, joined the held line, which then absorbed every line below it, never moving again).
- (d) Nothing else changes the block: not undo, not Return, not a move, not a pause, and not the app's own
  moves (they never count as hand moves). So in a block written line after line with no hand moves, the
  block's start never drifts.
*From:* "The next line goes back to the block's start (28 Oct)"; "Karthik's feedback on e2753a7" (any hand
move of 10%); "A block from the middle..." items 2-4; "Carrying a line on after a hand pan..." (10%-of-page
continuation rule, undo keeps the line).

**P7 The edge guard.** A contact that touched down in the edge band (a resting palm or thumb) never
cancels or delays a pending move.
*From:* comment in `handle` ("a palm resting on the edge must neither cancel nor hold back a pending page
move"); `checks/newline.sh` palm case.

**P8 No stuck states.** (a) A pending move never outlives its pause: on any tick with no counted contact
down and 400 ms or more since its lift, it fires. (b) A pending move is dropped by any event that makes it
stale: a touch, a hand move of the view (including a scroll or magnify outside draw mode), undo, Return, a
page change, writing mode off, a width change (it is decided again at the next lift).
(c) From every reachable state, writing a line that reaches the limit gives a move again (writing mode is
never wedged).
*From:* "Feedback (item 7)"; `panByArrow` ("a pending writing-mode move is dropped"); `centerView`.

## Assumptions about the platform

- While fingers are down in draw mode the sensor sends a frame every 8 ms, and each display tick handles the
  queued frames before `advanceClock` (`tick`: `drainInput` then `advanceClock`). So a tick never passes a
  touch it hasn't seen. The TLA+ model builds this in; the fuzzer drives frames and ticks in that order.
- Frames are only handled in draw mode. The touch count is reset when draw mode changes, because a finger
  that lifts outside draw mode is never seen to lift (TLC's counterexample on main).

## Bounds and what is not covered

- The model checker explores every event sequence up to the stated depth from a grid of starting views;
  positions come from a fixed set of placements relative to the state (next word, inside the 3% zone,
  crossing, 93-95% of the page, i-dot, next line at the block's start, indented, back to the previous line,
  far right, far below/above). Sequences longer than the bound, and positions off that set, are not covered
  exhaustively (the fuzzer samples them).
- Real hardware timing (sensor rate, display ticks, frame drops, the 0.18 s slide) is not modelled: the
  checks use a virtual clock with 8 ms frames.
- Palm classification by size or macOS's resting flag (`palmRejection`, off by default) is not modelled;
  "palm" here means a contact that touched down in the edge band.
