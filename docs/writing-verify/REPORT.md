# Writing mode: formal verification report (1 Nov)

Branch `writing-verify` (worktree `~/code/trackpad-draw-verify`), from main at 0d15973. Spec:
[docs/writing-spec.md](../writing-spec.md). Raw outputs are in this folder.

## How it was checked

| Layer | What runs | Code it exercises | Bound |
|---|---|---|---|
| Model checker | `checks/writing-verify.sh --explore N` (Swift, bench target) | `WModel`: Canvas's writing logic statement for statement, calling the real `WritingLayout` and `Camera` | every event sequence up to depth 5 over 36 events, and depth 8 over the 14 core events, from 30 starting views (3 widths x zoom 1/2/3/5 x left/middle/right), at waits of 200/400/1000 ms |
| Fuzzer | `--fuzz N --len L` | the real `CanvasView`: synthetic trackpad frames through `handle()`, ticks through `advanceClock()`, real gestures, filter, commit; `WModel` run alongside and compared after every step | random streams, shrunk to a minimal counterexample |
| Session replay | `--replay data` | the real `CanvasView` on Karthik's 34 recorded sessions (2.2M events) | all of them, at 200/400/1000 ms |
| Targeted | `--targeted` | the real canvas: the new-line slide, one arrow press, draw mode left between a commit and the next frame | grids |
| TLA+ | `checks/writing-tla.sh` (TLC) | the timing: touches, frames, ticks, edge contacts, Esc, scroll, arrows | complete state space for each wait (no bound) |
| Mutations | `checks/writing-mutants.py` | 26 targeted changes to the app (and the model), plus 7 TLA+ mutants | each through all of the above |

The oracle (`WSpec`) is written from the spec with its own constants (95%, 93%, 3%, W, 10%), so a change to
`WritingLayout`'s constants or Canvas's rules shows up as a violation, not as a new truth.

## Results by property (this branch)

| Property | Model checker (depth 5 full, depth 8 core, x 3 waits) | Real canvas (15,000 fuzz runs x 60 events, 3 waits; replay; targeted) | TLA+ (complete) |
|---|---|---|---|
| P1 never mid-word (move only >= W after the lift, no counted touch since) | holds | holds | holds (NeverMidWord, TouchCancels) |
| P2 written ink never moves | holds (trivially: the model never moves ink) | holds, every step and every replayed event | not modelled |
| P3 guide line <= 95%, = block start + width | holds | holds | not modelled |
| P4 move exactly when the line's live ink reaches the zone; i-dot can't cancel | holds | holds | abstracted (nondeterministic) |
| P5 where the move goes; clamped target remembered | holds | holds | not modelled |
| P6 blocks change only by the rules; no drift | holds | holds | not modelled |
| P7 edge contacts never cancel or delay | holds | holds | holds (EdgeGuard) |
| P8a nothing waits past W with no finger down | holds | holds | holds (NotOverdue) |
| P8b stale moves dropped (touch, hand move incl. scroll/magnify, undo, Return, page, writing off, width) | holds | holds | holds (NoFireAfterHandMove) |
| P8c never wedged: a writer carrying on always gets a move again | holds (checked from every one of the ~21M / ~35M states) | holds (checked after every fuzz run) | EventuallyDone holds |

Counts: depth 5 over 36 events: 21.09M distinct states / 40.96M transitions per wait; depth 8 over 14 core events:
35.1-35.4M states / 72M transitions per wait. TLC: 312 / 560 / 1,304 distinct states for 200 / 400 / 1000 ms,
complete. Fuzz: 15,000 runs of 60 random events on the real canvas (about 540,000 of the 900,000 were applicable in their
state); per wait about 46-47k strokes committed, 8.2-8.8k moves scheduled, 1.06-1.14k automatic moves, 3.4-3.7k
dropped, 2.8-3.1k scheduled with a palm on the edge, 2.8-3.0k block changes, 190-240 lines continued (held). The
model and the app agreed after every step.

## Counterexamples found, and fixes on this branch

Each has a check that fails on main and passes here (`baseline` row of the mutation table, and the targeted checks).

1. **Width change resets the block (P6).** `write(edge), width(75%)` -> block start 1415 -> nil; the next stroke,
   even mid-line, becomes the block's start and the limit counts from there. Happens to users: 5 width changes in
   the sessions hit it; in all of them his next stroke was elsewhere anyway, so no visible effect was recorded.
   Fix: a width change keeps the block and the line and drops a waiting move (decided again at the next lift).
2. **Erased ink stays in the line (P4).** `write(edge), scratch, write(short)`: the line's live ink ends at 1484.8,
   short of the zone (1488), but the scratched-out word still counted: a move after the shorter rewrite. Same with
   the eraser. Can happen (scratch the word within W, rewrite shorter); not seen in the sessions. Fix:
   `pruneWritingLine` after the eraser and scratch-out, as undo already did.
3. **Scroll/magnify outside draw mode don't drop the move (P8b; TLC too).** `write(edge), Esc, scroll`: the move
   fires mid-scroll and yanks the view (and with a magnify, to a target computed for the old zoom). Needs Esc and a
   scroll within W of the lift: plausible, more so at W = 1000 ms. Not in the sessions. Fix: both cancel, as arrows
   and the page map already did.
4. **Page switch during the 0.18 s slide.** New page / go to page opened at the other page's next-line position.
   Needs a page switch within 0.18 s of a move firing. Fix: `finishSlide()` first.
5. **Exactly 10% didn't count (P6).** One arrow press moves exactly 10% of the view; rounding made it 9.99..% in 39%
   of positions, so it wasn't a deliberate move. Happened once in the replay (a pinch 250% -> 300% against the
   page's left edge also shifts exactly 10%): main kept the block, the spec says a new one. Fix: compare with
   `* (1 - 1e-9)`.
6. **Stale touch count after Esc (TLC: EventuallyDone).** Draw mode left within one 8 ms frame of a lift while a
   second finger rests; that finger lifts outside draw mode; the count stays 1 and the move never fires (only the
   next touch drops it). Not reachable on purpose by a person; a missed move at worst. Fix: reset the count when
   draw mode changes.
7. **A held line swallows the lines below it (P8c, real-canvas fuzzer; on main).** Go back to finish the line a move
   just left (held: no automatic move), then write the next line where the move put you: one pitch down, which is
   inside the 1.2x "well below" test when 0.12 of the view sets the pitch. It joins the held line, which then takes
   every line under it: no move again until undo, Return or a page change. Minimal: `write(next), Return,
   write(prevEnd), write(nextLine), pinch(2.0)` at 75%, 500%. Reachable by the workflow in DECISIONS (29 Oct
   item 4); not in the sessions (no line was continued in them). Fix: under a held line, anything written below
   its ink is a new line (then the usual next-line-of-the-block / new-block rule).
8. **My own regression, caught before it shipped:** with fix 2, scratching out every stroke of a held line left an
   empty held line, wedging writing mode (depth-5 model checking, P8c). Fixed: an emptied line isn't held.

Main itself, model-checked at depth 5: only 1-3 above (P4, P6, P8b). The model checker didn't reach 7 within its
bound; the real-canvas fuzzer did.

## Real sessions

Replay of all 34 sessions in `data/` through this branch's `CanvasView` (as `--test-session` does, plus every
property after every record): 2,210,332 events, 8,188 strokes, 139 / 129 / 105 moves at 200 / 400 / 1000 ms,
0 violations. On main's code: the 5 width-change block resets and the one exactly-10% case. The moves the app
made when the sessions were recorded (older builds): 182, of which 86 logged their reason (right, limit, width);
none of those 86 violates P4 or P3, and none came less than 400 ms after scheduling or after a touch.

Spec refinement from real data: two sessions have a block whose first stroke started 20 units left of the page; the
view can't go there, so P5 now says "in view, or the view against that side of the page".

## What is and isn't covered

- Model only: the exhaustive part (every sequence within the bound) is over `WModel`, which mirrors Canvas's writing
  code; `WritingLayout` and `Camera` are the real ones. The differential check ties `WModel` to the real canvas on
  900k fuzz steps (no disagreement on this branch; it catches 15 of the 19 Canvas-logic mutants, and Writing.swift
  mutants can't differ by construction).
- Real code path: fuzzing, replay and targeted checks run the real `CanvasView` (gesture engine, filter, commit,
  undo, scratch-out, eraser, scroll via a real NSEvent, arrows, pages, writing toggle, width change) on a virtual
  clock with 8 ms frames.
- TLA+ only: interleavings of Esc / draw mode with fingers down, and the liveness property in its general form.
- Not covered: real hardware timing (sensor jitter, display ticks, dropped frames), the slide animation other than
  the page-switch race, the guide line's fade, zoom lock (pinch as pan), `palmRejection` on (a non-edge palm does
  cancel then), the NSTouch fallback, click-to-draw beyond what the replay contains, more than two pages, redo
  (a redone stroke doesn't rejoin the line; noted, not changed), sequences beyond the bounds and positions off the
  placement grid except as the fuzzer samples them. Not run here: the robot suite and the app's own test modes
  (`checks/newline.sh` etc.), to keep off the other agent's timing runs; the bench target compiles.

## Mutation table (do the checks have teeth?)

Each mutant is one change to the app (and the same change to `WModel` where it mirrors Canvas), built from a copy of
the sources (`checks/writing-mutants.py`). Quick settings per mutant: model checker at depth 4 for all three waits,
real-canvas fuzz 300 x 40 at 400 ms, the targeted checks; the differential column mutates only the app.

| mutant | targets | change | model checker (depth 4, waits 200/400/1000) | real canvas (fuzz 300x40, targeted) | differential (app mutated, model not) |
|---|---|---|---|---|---|
| `baseline` | all | main before the fixes | P4, P6, P8b | P4, P6, P8b, arrow, slide, staleCount | caught |
| `wait0` | P1 | no wait: the move comes at the lift | P1, P4, P5 | P1, slide, staleCount | caught |
| `halfWait` | P1 | the move comes after half the wait | P1 | P1 | caught |
| `touchKeeps` | P1 | a touch-down doesn't cancel the waiting move | P1, P5, P8b | P1, P4, P8b | caught |
| `inkMoves` | P2 | a move carries the last stroke down (the old 'move the crossing word' rule) | P2 | P2 | caught |
| `rightCap97` | P3 | rightCap 0.97 | P3 | P3 | - |
| `limitFromEdge` | P3 | the limit counts from the page's edge, not the block's start | P3, P4 | P3 | - |
| `nearMarker0` | P4 | nearMarker 0 (only a crossing brings the next line) | P4, P8c | P4 | - |
| `noNearEdge` | P4 | no 93% rule when the limit is at the page's edge | P4, P8c | P4 | - |
| `idotCancels` | P4 | only the last stroke's end counts (an i-dot cancels the move) | P4 | P4 | - |
| `unclamped` | P5 | the unclamped target is remembered (29 Oct bug 2) | P5, P6 | P5 | caught |
| `toMargin` | P5 | the next line goes to the page's margin, not the block's start | P5 | P5 | caught |
| `noInset` | P5 | the block's start lands at the view's very left (no 5% inset) | P5 | P5 | - |
| `runNotReset` | P6 | the block start isn't reset by a page change or writing mode off | P6 | P6 | caught |
| `drift` | P6 | no '10% of the page from the block's start' guard (29 Oct bug 3: lines drifted) | P6 | P6 | caught |
| `ownMoveIsHand` | P6 | the app's own move counts as a hand move (handRef not updated) | P5, P6 | P5 | caught |
| `undoResets` | P6 | undo ends the block | P6 | P6 | caught |
| `edgeCancels` | P7 | an edge-band contact cancels the waiting move | P7 | P7 | caught |
| `edgeHolds` | P7 | an edge-band contact holds the move back | P8a, P8c | P8a | caught |
| `doubleWait` | P8a | the move comes after twice the wait (ms/s mix-up) | P8a | P8a, slide | caught |
| `staleKept` | P8b | ending the line (undo, page, writing off) keeps the waiting move | P4, P5, P8b | P4, P8b | caught |
| `heldForever` | P8c | a line you went back to finish stays held (no move ever after) | P8c | P8c | caught |
| `slideRace` | slide | goToPage / newPage don't finish the slide (the bug fixed here) | not caught | slide | - |
| `staleCount` | P8 | the touch count isn't reset when draw mode changes (TLC's counterexample) | not caught | staleCount | - |
| `heldAbsorbs` | P8c | a held line takes the line written under it (main) | P6 | not caught | - |
| `heldEmpty` | P8c | an emptied line stays held (this branch's first scratch-out fix) | not caught | not caught | - |

- Every mutant is caught on the real code path except the two held-line ones at these quick settings; at the size
  that found them (`mutants-held-deep.txt`) `heldEmpty` fails P8c at depth 5 and `heldAbsorbs` fails P8c and P6 in
  the 5,000 x 60 fuzz.
- `slideRace` and `staleCount` are outside `WModel` by design (no animation, no draw mode); the targeted checks and
  TLC catch them.
- The differential catches 15 of the 19 Canvas-logic mutants (all but the four just named). `Writing.swift`
  mutants can't make the model and the app differ: both call the same `WritingLayout`.
- TLA+ mutants (`tlc.txt`): halfWait (NeverMidWord), touchKeeps (TouchCancels), frameKeeps and neverFires
  (NotOverdue), edgeCancels (EdgeGuard), staleCount (NotOverdue), scrollKeeps (NoFireAfterHandMove): 7 of 7 caught.



## After merging main (e0c943d)

Main moved on while this ran (the wait setting 38f7bd6, the 2 mm pan/pinch dead zone 0fa5ab7, scratch-out tuning
533ca6e). It merges into this branch without conflicts. In test runs the new setting ignores the stored value, so the
checks now set `Settings.pauseChosenMs`. On the merged code: model checker at depth 4 (3 waits), 3,000 fuzz runs x 60
plus the 5,000-run seed that found the held-line bug, the targeted checks and the replay (146 / 124 / 93 moves at
200 / 400 / 1000 ms, 0 violations) all pass; the `baseline` mutant (main's code) still fails P4, P6, P8b and the
three targeted checks. The large runs above were on the pre-merge branch (6699d14).
