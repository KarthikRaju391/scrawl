# Mode and tool friction: what Karthik's sessions show

Source: the 8 recorded sessions in `data/session-*.jsonl` (24–25 Oct 2026, one writer, 3,558 strokes
begun, 2,626 committed). The sessions log what changed (`tools`, `drawMode`, `writingMode`, `undo`,
`erase`, strokes) but not which key or button caused it, so input source can't be told apart.
Analysis script: kept local (`.local/mode_audit.py`), not in the repo.

**Proposals only. Nothing below is built.** Karthik picks.

## What was checked and found clean

- **Dead mode inputs:** 0 `tools` events that changed nothing.
- **Tool flips:** 0 tool changes undone within 3 s with no stroke between. Tools change rarely (5 changes
  in 8 sessions), so the toggle bug fixed in this round hurt trust more than it cost time.
- **The 906 strokes that never committed** (non-eraser) are all the first finger of a two-finger pan or
  pinch: a second finger landed within 0.15 s every time. That's by design, not lost ink.

## Ranked proposals

| # | Friction | Evidence | Proposal | Cost |
|---|---|---|---|---|
| 1 | **A stray stroke right after draw mode turns on** | 10 of the 16 first strokes after entering draw mode were undone before the next stroke (63%), against 8% (204 / 2,596) for all other strokes. They start 0.0–1.7 s after entry and last 0.4–0.6 s: short marks, not writing. | Don't draw with a finger that was already touching when draw mode started, and ignore the first ~150 ms after entry. Alternative: a brief "ready" pulse of the page outline so the first touch is deliberate. | Small; needs a replay check that no real first strokes are dropped |
| 2 | **Zoom lock pressed again within seconds** | 61 lock toggles; 11 re-toggled within 3 s; 33 of the 61 happened in draw mode, where until this round nothing on screen changed. | This round adds a note in draw mode ("Zoom locked"). Also proposed: a small lock glyph in a corner of the page for as long as the lock is on in draw mode. | Small |
| 3 | **The eraser misses** | 26 eraser strokes; 15 were the start of a pan. Of the 11 real ones, only 2 erased anything (13 strokes removed between them). | Show the eraser's size as a ring under the finger while erasing, and raise the default eraser size one step. Scratch-out (already approved, big win 1) may make this matter less. | Small |
| 4 | **Long undo runs** | 13 runs of 5 or more undos in a row (the longest is 12). 393 undos against 13 eraser hits. | Already approved as the undo scrub (big win 1): hold after the two-finger double tap and slide. | Approved |
| 5 | **Draw mode flapping** | One burst: draw mode on → off → on → off in 1.4 s (session 25 Oct 15:42, about 18 min in), plus 3 entries with no stroke. Too little to act on alone. | Make the draw-mode state harder to miss (a thin coloured frame around the window while in draw mode), rather than debouncing D. | Small |

## Not answerable from the logs

- Whether presses went to the toolbar, the keyboard or the menu, and so whether the toolbar's old
  click-opens-a-panel behaviour caused repeat presses. A cheap fix: log `src` on `tools`, `drawMode`
  and `writingMode` acts. `apply(_:from:)` already has the source.
